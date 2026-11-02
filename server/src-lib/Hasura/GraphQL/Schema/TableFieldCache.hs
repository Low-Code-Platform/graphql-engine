-- | Per-table field-parser cache (Phase 9).
--
-- Phase 8 cached memoized parser /nodes/, which measured 1.30x because
-- 'Control.Monad.Memoize.memoizeOn' caches only the tail: every call site computes
-- its key before probing the memo table, so the O(total) walk over every table
-- happens regardless of hits. This module caches one level up — a whole table's
-- field parsers — so an unchanged table's builder is never called at all. No key
-- to compute, no DMap to probe.
--
-- Ablation puts that walk at ~0.675s of a ~1.65s mutation (41%), versus the ~0.36s
-- of parser construction Phase 8 recovers. See
-- @rfcs/phase9-per-table-field-cache.md@ §2.
module Hasura.GraphQL.Schema.TableFieldCache
  ( TableFieldStore,
    PairKey,
    TableFieldStats (..),
    newTableFieldStore,
    prepareForBuild,
    withTableFields,

    -- * Passing the cache down to the builders
    TableFieldsCacher (..),
    mkTableFieldsCacher,
    noTableFieldsCache,
  )
where

import Data.Aeson (Value)
import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text.Extended (toTxt)
import Data.Typeable (Typeable)
import Hasura.Authentication.Role (RoleName)
import Hasura.Backends.Postgres.SQL.Types (SchemaName)
import Hasura.GraphQL.Schema.TableDeps (invalidatedTables)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend, TableName)
import Hasura.RQL.Types.Common (SourceName)

-- | Identifies one pair's cache.
--
-- 'RoleName' is defensive: this deployment is admin-only so it is inert, but
-- reusing one role's parsers for another would serve parsers built under different
-- permissions — a bug invisible at @roles = 1@ and latent the day a role is added.
type PairKey = (SourceName, SchemaName, RoleName)

-- | Per-table cached builder output, keyed by @(slot, table)@.
--
-- Values are 'Dynamic' because the store spans backends and slots, so entries are
-- heterogeneous. 'Typeable' on @[FieldParser P.Parse (QueryDB b ..)]@ was verified
-- to hold. A 'fromDynamic' failure is treated as a miss, so a type mismatch
-- degrades to a rebuild — slow, never wrong.
--
-- Tables are keyed by 'toTxt' rather than @TableName b@ for the same reason. A
-- 'toTxt' collision between two distinct tables would conflate them, which causes
-- over-invalidation (safe), never under-invalidation.
data PairState = PairState
  { -- | Previous build's per-table content fingerprints, keyed by @toTxt@.
    psFingerprints :: !(HashMap Text Value),
    -- | @(slot, toTxt table) -> builder output@.
    psFields :: !(HashMap (Text, Text) Dynamic)
  }

-- | Field-parser caches surviving across schema-cache builds.
--
-- A plain 'IORef' suffices: schema-cache builds are serialised by the
-- 'AppStateRef' lock (@withSchemaCacheReadUpdate@ runs the whole build under
-- @withMVarMasked@), so there is no concurrent access. Reads and writes still use
-- 'atomicModifyIORef'' rather than relying on that invariant holding forever.
type TableFieldStore = IORef (HashMap PairKey PairState)

newTableFieldStore :: (MonadIO m) => m TableFieldStore
newTableFieldStore = liftIO $ newIORef mempty

data TableFieldStats = TableFieldStats
  { tfsTables :: !Int,
    -- | Tables whose content fingerprint moved.
    tfsChanged :: !Int,
    -- | Changed plus everything transitively embedding them.
    tfsInvalidated :: !Int,
    -- | Cached slot entries kept for reuse.
    tfsRetained :: !Int
  }
  deriving stock (Eq, Show)

-- | Ready this pair's cache for a build: diff fingerprints, expand the changed set
-- through the dependency graph, drop the invalidated entries, and record the new
-- fingerprints.
--
-- Must run before any 'withTableFields' call for the same pair, or an invalidated
-- table's stale parsers would be served.
--
-- A table with no stored fingerprint counts as changed. That is what makes
-- untrack-then-retrack safe: the removed table's fingerprint disappears, so
-- re-tracking looks "new" and its stale entries are dropped before reuse. Between
-- untrack and retrack those entries linger unreferenced — bounded memory, not a
-- correctness problem.
prepareForBuild ::
  forall b m.
  (Backend b, MonadIO m) =>
  TableFieldStore ->
  PairKey ->
  -- | @A -> {B}@, A's parsers embed B's (see "Hasura.GraphQL.Schema.TableDeps")
  HashMap (TableName b) (HashSet (TableName b)) ->
  -- | This build's per-table content fingerprints
  HashMap (TableName b) Value ->
  m TableFieldStats
prepareForBuild store pairKey dependencyGraph currentFingerprints =
  liftIO $ atomicModifyIORef' store \storeMap ->
    let previous = HashMap.lookup pairKey storeMap
        stored = maybe mempty psFingerprints previous
        cachedFields = maybe mempty psFields previous

        changed :: HashSet (TableName b)
        changed =
          HS.fromList
            [ tableName
              | (tableName, fingerprint) <- HashMap.toList currentFingerprints,
                HashMap.lookup (toTxt tableName) stored /= Just fingerprint
            ]

        invalidated = invalidatedTables @b dependencyGraph changed
        invalidatedTxt = HS.map toTxt invalidated

        retained =
          HashMap.filterWithKey
            (\(_slot, tableTxt) _ -> not (tableTxt `HS.member` invalidatedTxt))
            cachedFields

        freshFingerprints =
          HashMap.fromList
            [(toTxt tableName, fp) | (tableName, fp) <- HashMap.toList currentFingerprints]

        stats =
          TableFieldStats
            { tfsTables = HashMap.size currentFingerprints,
              tfsChanged = HS.size changed,
              tfsInvalidated = HS.size invalidated,
              tfsRetained = HashMap.size retained
            }
     in ( HashMap.insert pairKey (PairState freshFingerprints retained) storeMap,
          stats
        )

-- | Return this table's cached output for @slot@, or run the builder and cache it.
--
-- Only sound after 'prepareForBuild' has dropped the invalidated entries for this
-- pair; this function does no invalidation of its own.
withTableFields ::
  forall a b m.
  (Typeable a, Backend b, MonadIO m) =>
  TableFieldStore ->
  PairKey ->
  -- | Slot: distinguishes the builders sharing a table key (query vs mutation)
  Text ->
  TableName b ->
  m a ->
  m a
withTableFields store pairKey slot tableName build = do
  storeMap <- liftIO $ readIORef store
  let entryKey = (slot, toTxt tableName)
      cached = do
        pairState <- HashMap.lookup pairKey storeMap
        dyn <- HashMap.lookup entryKey (psFields pairState)
        -- a wrong type here means a miss, never a wrong parser
        fromDynamic dyn
  case cached of
    Just fields -> pure fields
    Nothing -> do
      fields <- build
      liftIO $ atomicModifyIORef' store \m ->
        ( HashMap.alter (Just . insertField entryKey fields . fromMaybe emptyPairState) pairKey m,
          ()
        )
      pure fields
  where
    emptyPairState = PairState mempty mempty
    insertField k v pairState =
      pairState {psFields = HashMap.insert k (toDyn v) (psFields pairState)}

--------------------------------------------------------------------------------
-- Passing the cache down

-- | A per-table caching wrapper, handed to the field builders.
--
-- Rank-2 over both the cached type and the monad: one cacher serves every slot
-- (query fields and mutation fields have different types), and the builders run in
-- @SchemaT r m@ while the cacher is constructed in @m@.
--
-- Threading this as a value avoids putting the store in @SchemaT@'s reader
-- environment, which would touch every 'MonadBuildSchema' user.
newtype TableFieldsCacher b = TableFieldsCacher
  { -- | @runTableFieldsCacher slot table build@
    runTableFieldsCacher ::
      forall a n.
      (Typeable a, MonadIO n) =>
      Text ->
      TableName b ->
      n a ->
      n a
  }

-- | Cache per-table builder output in the store.
--
-- Only sound once 'prepareForBuild' has run for this pair — it does no
-- invalidation of its own.
mkTableFieldsCacher :: forall b. (Backend b) => TableFieldStore -> PairKey -> TableFieldsCacher b
mkTableFieldsCacher store pairKey =
  -- @b@ must be applied explicitly: TableName is a non-injective type family, so
  -- it cannot be recovered from the argument.
  TableFieldsCacher \slot tableName build -> withTableFields @_ @b store pairKey slot tableName build

-- | Always rebuild. This is the pre-Phase-9 behaviour and the default.
noTableFieldsCache :: TableFieldsCacher b
noTableFieldsCache = TableFieldsCacher \_slot _tableName build -> build

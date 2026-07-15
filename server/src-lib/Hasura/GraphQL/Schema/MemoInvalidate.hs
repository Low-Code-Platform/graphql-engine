-- | Backend-aware classification of memoized parser nodes for Phase 8 eviction.
--
-- 'Control.Monad.Memoize.evictWith' takes a predicate deciding which memo nodes a
-- change invalidated; this module supplies that predicate for "these tables
-- changed". It needs the concrete backend @b@ in scope in order to 'memoKeyArg'-cast
-- to @'TableName' b@, which is why it cannot live in @Control.Monad.Memoize@.
--
-- See @rfcs/phase8-persistent-memo-cache.md@ §6.3.
module Hasura.GraphQL.Schema.MemoInvalidate
  ( invalidatedByTables,
    evictTables,

    -- * Persisted per-(source, schema, role) caches
    MemoStore,
    MemoStoreKey,
    SchemaMemoState (..),
    newMemoStore,
    withSchemaMemoCache,
  )
where

import Control.Monad.Memoize
import Data.Aeson (Value)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text.Casing (GQLNameIdentifier)
import Data.Text.Extended (toTxt)
import Hasura.Authentication.Role (RoleName)
import Hasura.Backends.Postgres.SQL.Types (SchemaName)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend, ScalarType, TableName)
import Hasura.RQL.Types.Column (ColumnInfo, ColumnType, StructuredColumnInfo)
import Hasura.RQL.Types.Common (SourceName)
import Language.GraphQL.Draft.Syntax qualified as G

{- Note [Memo key classification]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Every 'memoizeOn' argument in the schema build falls into one of three classes, and
eviction must treat them differently. The classification below was derived by
auditing all ~39 call sites; the audit table is in the RFC (§6.3).

1. NAMES A TABLE but carries no content — @(SourceName, TableName b)@ and
   @(SourceName, TableName b, G.Name)@. Because the key says nothing about the
   table's *definition*, a changed table would hit its own stale entry. These MUST
   be evicted explicitly. Covers 'defaultTableSelectionSet', 'defaultSelectTable',
   'tableFieldsInput', 'mutationSelectionSet', 'conflictConstraint',
   'tableAggregationFields', 'orderByAggregation', 'tableStreamCursorExp', and —
   via their polymorphic @name@ parameter, instantiated to @tableInfoName@ —
   'boolExpInternal' and 'orderByExpInternal'.

2. EMBEDS ITS CONTENT — @(ScalarType b, G.Nullability)@, @(ColumnType b,
   G.Nullability)@, @ColumnType b@, @(Text, ColumnInfo b)@. These are
   self-invalidating: changed content yields a different key, hence a miss, hence a
   rebuild. Retaining them is not merely safe, it is *essential*: 'columnParser' and
   'comparisonExps' are shared by every table, so evicting them would transitively
   evict the entire schema (reverse reachability from a shared child reaches every
   parent) and the Phase 8 win would vanish.

3. EVERYTHING ELSE — logical models and native queries (which instantiate
   'boolExpInternal'/'orderByExpInternal' at @G.Name@ rather than @TableName b@),
   'streamColumnValueParser' @(SourceName, GQLNameIdentifier)@, actions, remote
   schemas, and Relay's @nodeInterface ()@. Conservatively evicted.

The bias is deliberate and asymmetric: over-eviction costs a rebuild, whereas
under-eviction silently serves a stale schema and can mint two Uniques for one
GraphQL type. A shape that is added later and not listed here therefore lands in
class 3 and stays correct — it just stops being fast.
-}

-- | Is this memo node invalidated by a change to any of @changed@?
--
-- Returning 'False' asserts the node is *provably* unaffected and may be reused
-- verbatim. Anything unrecognised returns 'True'. See
-- Note [Memo key classification].
invalidatedByTables ::
  forall b t.
  (Backend b) =>
  SourceName ->
  HashSet (TableName b) ->
  -- | GQL identifiers of the changed tables. Some memo keys name a table by its
  -- GraphQL identifier rather than its 'TableName', and cannot be mapped back.
  HashSet GQLNameIdentifier ->
  MemoizationKey t ->
  Bool
invalidatedByTables sourceName changed changedIdents key
  -- (1) Keyed on a table: evict iff that table changed.
  | Just (s, tbl) <- memoKeyArg @(SourceName, TableName b) key =
      s == sourceName && tbl `HS.member` changed
  | Just (s, tbl, _ :: G.Name) <- memoKeyArg @(SourceName, TableName b, G.Name) key =
      s == sourceName && tbl `HS.member` changed
  -- 'streamColumnValueParser' (SubscriptionStream.hs:139) names its table by GQL
  -- identifier and carries no content, so it must be evicted when that table
  -- changes -- but it cannot be matched by TableName.
  | Just (s, ident) <- memoKeyArg @(SourceName, GQLNameIdentifier) key =
      s == sourceName && ident `HS.member` changedIdents
  -- (2) Keyed on content: self-invalidating, always reusable.
  | isJust (memoKeyArg @(ScalarType b, G.Nullability) key) = False
  | isJust (memoKeyArg @(ColumnType b, G.Nullability) key) = False
  | isJust (memoKeyArg @(ColumnType b) key) = False
  | isJust (memoKeyArg @(Text, ColumnInfo b) key) = False
  -- 'tableSelectColumnsEnum' (Schema/Table.hs:125) keys on
  -- @(enumName, description, columns)@ — the columns are IN the key, so it is
  -- self-invalidating like the rest of class 2.
  | isJust (memoKeyArg @(G.Name, Maybe G.Description, [StructuredColumnInfo b]) key) = False
  -- (3) Unclassifiable: evict. See Note [Memo key classification].
  | otherwise = True

-- | Evict every node invalidated by a change to @changed@, plus everything
-- transitively embedding one.
evictTables ::
  forall b.
  (Backend b) =>
  SourceName ->
  HashSet (TableName b) ->
  HashSet GQLNameIdentifier ->
  MemoCache ->
  (MemoCache, EvictionStats)
evictTables sourceName changed changedIdents =
  evictWith (invalidatedByTables @b sourceName changed changedIdents)

--------------------------------------------------------------------------------
-- Persisted caches

-- | Identifies one persisted memo cache.
--
-- The 'RoleName' dimension is defensive. This deployment is admin-only, so there
-- is exactly one role and the dimension is inert (locked decision 1). But seeding
-- one role's build from another role's cache would reuse parsers built under
-- different permissions — a stale-schema bug that is invisible at @roles = 1@ and
-- would surface the day a role is added. Keying it out costs a tuple field.
type MemoStoreKey = (SourceName, SchemaName, RoleName)

-- | Memo caches surviving across schema-cache builds.
--
-- A plain 'IORef' is sufficient: schema-cache builds are serialised by the
-- 'AppStateRef' lock (@withSchemaCacheReadUpdate@ runs the whole build under
-- @withMVarMasked@), so there is never concurrent access. This is deliberately a
-- side-channel that 'Inc.cache' does not manage — see the RFC §6.4.
type MemoStore = IORef (HashMap MemoStoreKey SchemaMemoState)

data SchemaMemoState = SchemaMemoState
  { -- | Per-table content fingerprints from the previous build, keyed by the
    -- table's 'toTxt'. 'Text' rather than @TableName b@ because one store spans
    -- backends; a 'toTxt' collision between two distinct tables would conflate
    -- them and evict both, which is over-eviction (safe), never under-eviction.
    smsFingerprints :: !(HashMap Text Value),
    smsCache :: !MemoCache
  }

newMemoStore :: (MonadIO m) => m MemoStore
newMemoStore = liftIO $ newIORef mempty

-- | Run a memoization pass seeded from the store: evict whatever the fingerprints
-- say changed, build, then write the resulting cache back.
--
-- @currentFingerprints@ is this build's per-table content fingerprint for the
-- @(source, schema)@ being built. A table is considered changed when its
-- fingerprint differs from the stored one /or/ it has no stored fingerprint at
-- all — which is what makes untrack-then-retrack safe: the removed table's
-- fingerprint disappears, so re-tracking it looks "new" and its stale nodes are
-- evicted before reuse. (Between untrack and retrack those nodes linger
-- unreferenced; that is a bounded memory cost, not a correctness one.)
withSchemaMemoCache ::
  forall b m a.
  (Backend b, MonadIO m) =>
  MemoStore ->
  SourceName ->
  SchemaName ->
  RoleName ->
  -- | Per-table content fingerprint and GQL identifier for this (source, schema).
  HashMap (TableName b) (Value, GQLNameIdentifier) ->
  MemoizeT m a ->
  m a
withSchemaMemoCache store sourceName schemaName roleName currentTables action = do
  previous <- liftIO $ HashMap.lookup storeKey <$> readIORef store
  let storedFingerprints = maybe mempty smsFingerprints previous
      seeded = maybe emptyMemoCache smsCache previous
      changed =
        HS.fromList
          [ tableName
            | (tableName, (fingerprint, _)) <- HashMap.toList currentTables,
              HashMap.lookup (toTxt tableName) storedFingerprints /= Just fingerprint
          ]
      changedIdents =
        HS.fromList
          [ ident
            | (tableName, (_, ident)) <- HashMap.toList currentTables,
              tableName `HS.member` changed
          ]
      (evicted, _stats) = evictTables @b sourceName changed changedIdents seeded
  (result, cache') <- runMemoizeTWith evicted action
  liftIO
    $ modifyIORef' store
    $ HashMap.insert storeKey (SchemaMemoState freshFingerprints cache')
  pure result
  where
    storeKey = (sourceName, schemaName, roleName)
    freshFingerprints =
      HashMap.fromList
        [(toTxt tableName, fingerprint) | (tableName, (fingerprint, _)) <- HashMap.toList currentTables]

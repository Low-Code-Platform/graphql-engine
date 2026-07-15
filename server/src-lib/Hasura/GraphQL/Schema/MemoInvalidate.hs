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
  )
where

import Control.Monad.Memoize
import Data.HashSet qualified as HS
import Data.Typeable (Typeable)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend, ScalarType, TableName)
import Hasura.RQL.Types.Column (ColumnInfo, ColumnType)
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
--
-- The extra @Typeable (ScalarType b)@ is not redundant: 'ScalarType' is a type
-- family, so its 'Typeable' instance does not follow from @Typeable b@. @TableName
-- b@, @ColumnType b@ and @ColumnInfo b@ are already covered by 'Backend'.
invalidatedByTables ::
  forall b t.
  (Backend b, Typeable (ScalarType b)) =>
  SourceName ->
  HashSet (TableName b) ->
  MemoizationKey t ->
  Bool
invalidatedByTables sourceName changed key
  -- (1) Keyed on a table: evict iff that table changed.
  | Just (s, tbl) <- memoKeyArg @(SourceName, TableName b) key =
      s == sourceName && tbl `HS.member` changed
  | Just (s, tbl, _ :: G.Name) <- memoKeyArg @(SourceName, TableName b, G.Name) key =
      s == sourceName && tbl `HS.member` changed
  -- (2) Keyed on content: self-invalidating, always reusable.
  | isJust (memoKeyArg @(ScalarType b, G.Nullability) key) = False
  | isJust (memoKeyArg @(ColumnType b, G.Nullability) key) = False
  | isJust (memoKeyArg @(ColumnType b) key) = False
  | isJust (memoKeyArg @(Text, ColumnInfo b) key) = False
  -- (3) Unclassifiable: evict. See Note [Memo key classification].
  | otherwise = True

-- | Evict every node invalidated by a change to @changed@, plus everything
-- transitively embedding one.
evictTables ::
  forall b.
  (Backend b, Typeable (ScalarType b)) =>
  SourceName ->
  HashSet (TableName b) ->
  MemoCache ->
  (MemoCache, EvictionStats)
evictTables sourceName changed = evictWith (invalidatedByTables @b sourceName changed)

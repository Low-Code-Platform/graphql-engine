-- | Table-level dependency tracking for the Phase 9 per-table field cache.
--
-- A table's cached field parsers embed the parsers of every table it has a
-- relationship to (@album@'s selection set contains @track@'s). So reusing
-- @album@'s parsers after @track@ changed would serve @track@'s /old/ definition.
-- This module computes which tables a change invalidates.
--
-- This replaces Phase 8's node-level @DepGraph@: the graph is over tables and is
-- derived from metadata, rather than over an existentially-keyed DMap and recorded
-- during the build. See @rfcs/phase9-per-table-field-cache.md@ §5.2.
module Hasura.GraphQL.Schema.TableDeps
  ( tableDependencyGraph,
    invalidatedTables,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HS
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend, TableName)
import Hasura.RQL.Types.Relationships.Local (RelInfo (..), RelTarget (..))
import Hasura.Table.Cache (TableCache, TableCoreInfoG (..), TableInfo (..), getRels)

-- | @A -> {B}@ : A's parsers embed B's, i.e. A depends on B.
--
-- Only local table relationships create this embedding. Relationships to native
-- queries ('RelTargetNativeQuery') target a different namespace and are ignored;
-- remote relationships are cross-source and likewise cannot be reached here.
-- Shared leaf parsers (@columnParser@, @comparisonExps@) are /not/ edges: they are
-- keyed by content, so a change to a table cannot silently alter them.
tableDependencyGraph ::
  forall b.
  (Backend b) =>
  TableCache b ->
  HashMap (TableName b) (HashSet (TableName b))
tableDependencyGraph tables =
  HashMap.fromList
    [ (tableName, HS.fromList (localRelationTargets tableInfo))
      | (tableName, tableInfo) <- HashMap.toList tables
    ]
  where
    localRelationTargets :: TableInfo b -> [TableName b]
    localRelationTargets tableInfo =
      [ target
        | relInfo <- getRels (_tciFieldInfoMap (_tiCoreInfo tableInfo)),
          RelTargetTable target <- [riTarget relInfo]
      ]

-- | Every table whose cached field parsers a change to @changed@ invalidates:
-- @changed@ itself, plus everything that transitively embeds one of them.
--
-- Reachability runs over /reversed/ edges, because the question is "who must be
-- rebuilt because this changed?". Relationship cycles (@album <-> track@) are
-- expected and terminate via the visited set.
--
-- Conservative by construction: a table absent from the graph (e.g. newly tracked)
-- contributes no edges, and callers treat "not in the cache" as a rebuild anyway.
invalidatedTables ::
  forall b.
  (Backend b) =>
  HashMap (TableName b) (HashSet (TableName b)) ->
  HashSet (TableName b) ->
  HashSet (TableName b)
invalidatedTables dependencyGraph changed = go HS.empty (HS.toList changed)
  where
    -- reversed: child -> tables that embed it
    dependents :: HashMap (TableName b) (HashSet (TableName b))
    dependents =
      HashMap.fromListWith
        HS.union
        [ (target, HS.singleton dependent)
          | (dependent, targets) <- HashMap.toList dependencyGraph,
            target <- HS.toList targets
        ]

    go :: HashSet (TableName b) -> [TableName b] -> HashSet (TableName b)
    go seen [] = seen
    go seen (t : rest)
      | t `HS.member` seen = go seen rest
      | otherwise =
          go
            (HS.insert t seen)
            (HS.toList (HashMap.lookupDefault HS.empty t dependents) <> rest)

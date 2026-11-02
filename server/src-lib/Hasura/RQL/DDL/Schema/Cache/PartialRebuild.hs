-- | Partial schema cache rebuild scoped to a single DB schema.
--
-- See: rfcs/partial-schema-cache-rebuild.md
--
-- Implementation order:
--   Phase 1 — CacheInvalidations / InvalidationKeys extensions  (Build.hs, Common.hs)
--   Phase 2 — Schema-filtered catalog introspection              (Postgres/DDL/Source.hs)
--   Phase 3 — Per-schema Inc.cache in the arrow pipeline         (Cache.hs)
--   Phase 4 — Merge logic                                        (this file)
--   Phase 5 — DDL entry point                                    (Build.hs + this file)
module Hasura.RQL.DDL.Schema.Cache.PartialRebuild
  ( -- * Phase 4: merge helpers
    mergeSchemaIntoSourceInfo,
    mergeSchemaIntoSchemaCache,
    partitionIntrospectionBySchema,

    -- * Phase 5: DDL entry point
    buildSchemaCacheForDbSchema,

    -- * Helpers
    tableSchemaName,
    freshIntrospectionOverride,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.IORef (IORef, newIORef)
import Hasura.Backends.Postgres.SQL.Types (SchemaName (..))
import Hasura.Prelude
import Hasura.RQL.Types.Backend (TableName)
import Hasura.RQL.Types.Common (SourceName)
import Hasura.RQL.Types.Metadata (MetadataModifier)
import Hasura.RQL.Types.Metadata.Backend (BackendMetadata, functionNameSchema, tableNameSchema)
import Hasura.RQL.Types.Metadata.Instances ()
import Hasura.RQL.Types.SchemaCache (SchemaCache (..))
import Hasura.RQL.Types.SchemaCache.Build
  ( CacheInvalidations (..),
    CacheRWM,
    MetadataM,
    buildSchemaCacheWithInvalidations,
  )
import Hasura.RQL.Types.Source (BackendSourceInfo, DBObjectsIntrospection (..), SourceInfo (..))
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.Table.Cache (TableInfo, tableInfoName)
import System.IO.Unsafe (unsafePerformIO)

-- | An authoritative, freshly-fetched per-source introspection override for a
-- per-schema rebuild.
--
-- A per-schema rebuild ('buildSchemaCacheForDbSchema') reuses the memoised source
-- introspection and does not re-query the database, so on its own it would not
-- observe schema-altering DDL (new/dropped columns, functions). The @run_sql@
-- per-schema path (see @withMetadataCheck@) already fetches fresh introspection
-- post-DDL to compute the metadata diff; it deposits that here so the rebuild
-- reuses it rather than either serving stale data or paying for a third database
-- introspection.
--
-- Stored as an 'AB.AnyBackend' of the backend-indexed 'DBObjectsIntrospection'
-- (not JSON) so writing and reading avoid an encode/decode round-trip of the full
-- source introspection on every ALTER.
--
-- Concurrency: a process-global is safe here only because schema-cache builds for
-- a source are serialised (the metadata write lock). It is populated immediately
-- before a single synchronous per-schema build and cleared immediately after
-- (even on error), so no other build ever observes a stray value. If schema-cache
-- builds ever become concurrent, thread this through the build inputs instead.
{-# NOINLINE freshIntrospectionOverride #-}
freshIntrospectionOverride :: IORef (HashMap.HashMap SourceName (AB.AnyBackend DBObjectsIntrospection))
freshIntrospectionOverride = unsafePerformIO (newIORef mempty)

-------------------------------------------------------------------------------
-- Phase 4 — Merge Logic
-------------------------------------------------------------------------------

-- | Extract the schema name from a table's qualified name.
--
-- For Postgres, @TableName ('Postgres pgKind) = QualifiedObject TableName@
-- and @qSchema@ gives the schema directly.  For single-schema backends this
-- can return a constant.
--
-- TODO (Phase 4): implement per backend via a new BackendMetadata method or a
-- standalone typeclass.  Blocked on Phase 1 landing so we know the SchemaName
-- type is re-exported from a shared module.
tableSchemaName ::
  forall b.
  (BackendMetadata b) =>
  TableInfo b ->
  SchemaName
tableSchemaName = tableNameSchema @b . tableInfoName

-- | Replace only the tables belonging to @schemaName@ inside @SourceInfo@,
-- leaving every other schema's tables untouched.
--
-- Precondition: no cross-schema foreign keys (documented assumption; see RFC).
--
-- @
--   _siTables result
--     = newTables                                   -- rebuilt schema
--    <> filter (\t -> schema(t) /= schemaName)      -- all other schemas
--              (_siTables existing)
-- @
mergeSchemaIntoSourceInfo ::
  forall b.
  (BackendMetadata b) =>
  -- | DB schema that was partially rebuilt.
  SchemaName ->
  -- | Fresh table cache covering only @schemaName@.
  HashMap (TableName b) (TableInfo b) ->
  -- | Current full source info (will not be mutated).
  SourceInfo b ->
  SourceInfo b
mergeSchemaIntoSourceInfo schemaName newTables existing =
  existing
    { _siTables =
        HashMap.union
          newTables
          (HashMap.filter ((/= schemaName) . tableSchemaName @b) (_siTables existing))
    }

-- | Apply 'mergeSchemaIntoSourceInfo' at the 'SchemaCache' level.
--
-- Looks up @sourceName@ in 'scSources', dispatches over the backend type to
-- extract schema X's fresh tables from @freshBSI@, calls
-- 'mergeSchemaIntoSourceInfo' to splice them in, and reinserts the updated
-- 'SourceInfo' back into the cache.  If @sourceName@ is absent (e.g. it was
-- dropped between the rebuild and the merge) the cache is returned unchanged.
-- If the two 'BackendSourceInfo' values do not agree on the backend type, the
-- old entry is preserved.
mergeSchemaIntoSchemaCache ::
  -- | Existing full schema cache.
  SchemaCache ->
  SourceName ->
  SchemaName ->
  -- | Fresh 'SourceInfo' produced by the partial rebuild (backend type resolved
  -- at runtime via 'AB.dispatchAnyBackend').
  BackendSourceInfo ->
  SchemaCache
mergeSchemaIntoSchemaCache schemaCache sourceName schemaName freshBSI =
  case HashMap.lookup sourceName (scSources schemaCache) of
    Nothing -> schemaCache
    Just oldBSI ->
      let updatedBSI =
            AB.dispatchAnyBackend @BackendMetadata oldBSI $ \(oldSI :: SourceInfo b) ->
              case AB.unpackAnyBackend @b freshBSI of
                Nothing ->
                  -- Backend type mismatch — keep the old entry unchanged.
                  AB.mkAnyBackend oldSI
                Just freshSI ->
                  let freshSchemaXTables =
                        HashMap.filter
                          ((== schemaName) . tableSchemaName @b)
                          (_siTables freshSI)
                   in AB.mkAnyBackend
                        $ mergeSchemaIntoSourceInfo @b schemaName freshSchemaXTables oldSI
          updatedSources = HashMap.insert sourceName updatedBSI (scSources schemaCache)
       in schemaCache {scSources = updatedSources}

-- | Partition a 'DBObjectsIntrospection' (which covers a full source) into
-- per-schema slices.
--
-- Used in Phase 3 to feed each schema's slice into its own @Inc.cache@ block
-- so that only the schema whose 'Inc.InvalidationKey' changed is re-processed.
--
-- TODO (Phase 2 / Phase 3): this requires 'TableName b' to carry a schema
-- component, which is always true for Postgres ('QualifiedObject') but is
-- backend-specific.  Gate this on a capability flag if needed.
partitionIntrospectionBySchema ::
  forall b.
  (BackendMetadata b) =>
  DBObjectsIntrospection b ->
  -- | Key: schema name. Value: introspection covering only that schema's objects.
  HashMap SchemaName (DBObjectsIntrospection b)
partitionIntrospectionBySchema (DBObjectsIntrospection tables functions scalars logicalModels) =
  let tablesBySchema =
        HashMap.foldlWithKey'
          (\acc k v -> HashMap.insertWith HashMap.union (tableNameSchema @b k) (HashMap.singleton k v) acc)
          mempty
          tables
      functionsBySchema =
        HashMap.foldlWithKey'
          (\acc k v -> HashMap.insertWith HashMap.union (functionNameSchema @b k) (HashMap.singleton k v) acc)
          mempty
          functions
      allSchemas =
        HashMap.keysSet tablesBySchema `HashSet.union` HashMap.keysSet functionsBySchema
   in HashMap.fromList
        [ ( schema,
            DBObjectsIntrospection
              (fromMaybe mempty $ HashMap.lookup schema tablesBySchema)
              (fromMaybe mempty $ HashMap.lookup schema functionsBySchema)
              scalars
              logicalModels
          )
        | schema <- HashSet.toList allSchemas
        ]

-------------------------------------------------------------------------------
-- Phase 5 — DDL Entry Point
-------------------------------------------------------------------------------

-- | Trigger a cache rebuild that only invalidates the given @(sourceName,
-- schemaName)@ pair.
--
-- All other sources and schemas are served from the existing memoised
-- 'Inc.cache' entries, which means:
--   - No Postgres catalog re-query for untouched schemas (Phase 2).
--   - No 'buildTableCache' re-run for untouched schemas (Phase 3).
--   - 'buildGQLContext' still runs in full (deferred to Phase 6).
--
-- Call this instead of 'buildSchemaCache' for DDL operations where the schema
-- is statically known (e.g. 'run_sql' when the target schema is parsed from
-- the SQL statement, or 'untrack_table' when 'qSchema' is available).
buildSchemaCacheForDbSchema ::
  (CacheRWM m, MetadataM m) =>
  SourceName ->
  SchemaName ->
  MetadataModifier ->
  m ()
buildSchemaCacheForDbSchema sourceName schemaName modifier =
  buildSchemaCacheWithInvalidations
    ( mempty
        { ciSourceSchemas = HashSet.singleton (sourceName, schemaName)
          -- ciSourceSchemas is the field added in Phase 1.
          -- Until Phase 1 lands, this won't compile; add the field first.
        }
    )
    modifier

{-# LANGUAGE QuasiQuotes #-}

-- | Functions for fetching and updating @'Metadata' in the catalog.
module Hasura.RQL.DDL.Schema.Catalog
  ( fetchMetadataFromCatalog,
    fetchMetadataAndResourceVersionFromCatalog,
    fetchMetadataResourceVersionFromCatalog,
    fetchMetadataNotificationsFromCatalog,
    fetchMetadataPartitionsFromCatalog,
    upsertMetadataPartitionInCatalog,
    insertMetadataInCatalog,
    setMetadataInCatalog,
    bumpMetadataVersionInCatalog,
  )
where

import Data.Aeson (Value)
import Data.Bifunctor (bimap)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.Text.NonEmpty (mkNonEmptyText)
import Database.PG.Query qualified as PG
import Hasura.Backends.Postgres.Connection
import Hasura.Backends.Postgres.SQL.Types (SchemaName (..), getSchemaTxt)
import Hasura.Base.Error
import Hasura.Prelude
import Hasura.RQL.Types.Common (SourceName (..), defaultSource, sourceNameToText)
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Metadata.Partition (reassembleMetadata, splitMetadataBySchema)
import Hasura.RQL.Types.SchemaCache
  ( MetadataResourceVersion (..),
    MetadataWithResourceVersion (..),
    initialResourceVersion,
  )
import Hasura.RQL.Types.SchemaCache.Build (CacheInvalidations)
import Hasura.Server.Types (InstanceId (..))

-- | Decode a @source_name@ text column back into a 'SourceName', mirroring the
-- 'FromJSON' instance ("default" is the reserved default source).
textToSourceName :: Text -> SourceName
textToSourceName t
  | t == sourceNameToText defaultSource = defaultSource
  | otherwise = maybe defaultSource SNName (mkNonEmptyText t)

-- | Read every @(source, schema)@ metadata partition row.
fetchMetadataPartitionsFromCatalog :: PG.TxE QErr [(SourceName, SchemaName, Value)]
fetchMetadataPartitionsFromCatalog = do
  rows <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
       SELECT source_name, schema_name, partition FROM hdb_catalog.hdb_metadata_partition
    |]
      ()
      True
  pure
    [ (textToSourceName sourceName, SchemaName schemaName, partition)
      | (sourceName, schemaName, PG.ViaJSON partition) <- rows
    ]

-- | UPSERT one partition row, bumping its per-partition @resource_version@.
upsertMetadataPartitionInCatalog :: SourceName -> SchemaName -> Value -> PG.TxE QErr ()
upsertMetadataPartitionInCatalog sourceName schemaName partition =
  PG.unitQE
    defaultTxErrorHandler
    [PG.sql|
    INSERT INTO hdb_catalog.hdb_metadata_partition (source_name, schema_name, partition)
    VALUES ($1, $2, $3::jsonb)
    ON CONFLICT (source_name, schema_name) DO UPDATE SET
      partition = $3::jsonb,
      resource_version = hdb_catalog.hdb_metadata_partition.resource_version + 1
    |]
    (sourceNameToText sourceName, getSchemaTxt schemaName, PG.ViaJSON partition)
    True

-- | Delete one partition row (a @(source, schema)@ that no longer exists).
deleteMetadataPartitionInCatalog :: SourceName -> SchemaName -> PG.TxE QErr ()
deleteMetadataPartitionInCatalog sourceName schemaName =
  PG.unitQE
    defaultTxErrorHandler
    [PG.sql|
    DELETE FROM hdb_catalog.hdb_metadata_partition
    WHERE source_name = $1 AND schema_name = $2
    |]
    (sourceNameToText sourceName, getSchemaTxt schemaName)
    True

-- | Read the skeleton 'Metadata' (stored in @hdb_metadata@) and merge every
-- per-@(source, schema)@ partition row back into it (Phase 2, §11). The
-- skeleton holds everything except the schema-scoped table groups, which live
-- in @hdb_metadata_partition@.
fetchMetadataFromCatalog :: PG.TxE QErr Metadata
fetchMetadataFromCatalog = do
  rows <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
       SELECT metadata from hdb_catalog.hdb_metadata
    |]
      ()
      True
  skeleton <- case rows of
    [] -> pure emptyMetadata
    [Identity (PG.ViaJSON metadata)] -> pure metadata
    _ -> throw500 "multiple rows in hdb_metadata table"
  partitions <- fetchMetadataPartitionsFromCatalog
  liftEither $ reassembleMetadata skeleton partitions

fetchMetadataAndResourceVersionFromCatalog :: PG.TxE QErr MetadataWithResourceVersion
fetchMetadataAndResourceVersionFromCatalog = do
  rows <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
       SELECT metadata, resource_version from hdb_catalog.hdb_metadata
    |]
      ()
      True
  (skeleton, resourceVersion) <- case rows of
    [] -> pure (emptyMetadata, initialResourceVersion)
    [(PG.ViaJSON metadata, resourceVersion)] -> pure (metadata, MetadataResourceVersion resourceVersion)
    _ -> throw500 "multiple rows in hdb_metadata table"
  partitions <- fetchMetadataPartitionsFromCatalog
  metadata <- liftEither $ reassembleMetadata skeleton partitions
  pure $ MetadataWithResourceVersion metadata resourceVersion

fetchMetadataResourceVersionFromCatalog :: PG.TxE QErr MetadataResourceVersion
fetchMetadataResourceVersionFromCatalog = do
  rows <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
       SELECT resource_version from hdb_catalog.hdb_metadata
    |]
      ()
      True
  case rows of
    [] -> pure initialResourceVersion
    [Identity resourceVersion] -> pure (MetadataResourceVersion resourceVersion)
    _ -> throw500 "multiple rows in hdb_metadata table"

fetchMetadataNotificationsFromCatalog :: MetadataResourceVersion -> InstanceId -> PG.TxE QErr [(MetadataResourceVersion, CacheInvalidations)]
fetchMetadataNotificationsFromCatalog (MetadataResourceVersion resourceVersion) instanceId = do
  fmap (bimap MetadataResourceVersion PG.getViaJSON)
    <$> PG.withQE
      defaultTxErrorHandler
      [PG.sql|
         SELECT resource_version, notification
         FROM hdb_catalog.hdb_schema_notifications
         WHERE resource_version > $1 AND instance_id != ($2::uuid)
      |]
      (resourceVersion, instanceId)
      True

-- Used to increment metadata version when no other changes are required
bumpMetadataVersionInCatalog :: PG.TxE QErr ()
bumpMetadataVersionInCatalog = do
  PG.unitQE
    defaultTxErrorHandler
    [PG.sql|
      UPDATE hdb_catalog.hdb_metadata
      SET resource_version = hdb_catalog.hdb_metadata.resource_version + 1
      |]
    ()
    True

-- | Seed an empty catalog: store the skeleton in @hdb_metadata@ and one row per
-- @(source, schema)@ partition (Phase 2, §11).
insertMetadataInCatalog :: Metadata -> PG.TxE QErr ()
insertMetadataInCatalog metadata = do
  let (skeleton, partitions) = splitMetadataBySchema metadata
  PG.unitQE
    defaultTxErrorHandler
    [PG.sql|
    INSERT INTO hdb_catalog.hdb_metadata(id, metadata)
    VALUES (1, $1::json)
    |]
    (Identity $ PG.ViaJSON skeleton)
    True
  for_ partitions $ \(sourceName, schemaName, partition) ->
    upsertMetadataPartitionInCatalog sourceName schemaName partition

-- | Write metadata, partitioned by @(source, schema)@ (Phase 2, §11). The
-- incoming 'Metadata' is split into a skeleton and per-schema partitions; only
-- the partitions whose content actually changed are rewritten (removed ones are
-- deleted). The skeleton write does the optimistic concurrency check against the
-- global @resource_version@ and bumps it.
--
-- Returns the new global resource version and the set of @(source, schema)@
-- pairs that changed, so the caller can scope schema-cache invalidation
-- notifications to just those partitions.
--
-- - If the referenced version matches the current one: update and bump.
-- - If not: throw a 409 error.
setMetadataInCatalog ::
  MetadataResourceVersion ->
  Metadata ->
  PG.TxE QErr (MetadataResourceVersion, HashSet (SourceName, SchemaName))
setMetadataInCatalog resourceVersion metadata = do
  let (skeleton, newPartitions) = splitMetadataBySchema metadata
      newMap = HashMap.fromList [((sn, sch), v) | (sn, sch, v) <- newPartitions]
  currentPartitions <- fetchMetadataPartitionsFromCatalog
  let currentMap = HashMap.fromList [((sn, sch), v) | (sn, sch, v) <- currentPartitions]
      -- new/changed partitions (content compared structurally; 'Value' Eq
      -- ignores object key order)
      changed = [(sn, sch, v) | ((sn, sch), v) <- HashMap.toList newMap, HashMap.lookup (sn, sch) currentMap /= Just v]
      removed = [(sn, sch) | (sn, sch) <- HashMap.keys currentMap, not (HashMap.member (sn, sch) newMap)]

  -- Skeleton write + optimistic concurrency check on the global version.
  rows <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
    INSERT INTO hdb_catalog.hdb_metadata(id, metadata)
    VALUES (1, $1::json)
    ON CONFLICT (id) DO UPDATE SET
      metadata = $1::json,
      resource_version = hdb_catalog.hdb_metadata.resource_version + 1
      WHERE hdb_catalog.hdb_metadata.resource_version = $2
    RETURNING resource_version
    |]
      (PG.ViaJSON skeleton, getMetadataResourceVersion resourceVersion)
      True
  newResourceVersion <- case rows of
    [] -> throw409 $ "metadata resource version referenced (" <> tshow (getMetadataResourceVersion resourceVersion) <> ") did not match current version"
    [Identity newResourceVersion] -> pure $ MetadataResourceVersion newResourceVersion
    _ -> throw500 "multiple rows in hdb_metadata table"

  for_ changed $ \(sn, sch, v) -> upsertMetadataPartitionInCatalog sn sch v
  for_ removed $ \(sn, sch) -> deleteMetadataPartitionInCatalog sn sch

  let changedPairs = HashSet.fromList (map (\(sn, sch, _) -> (sn, sch)) changed <> removed)
  pure (newResourceVersion, changedPairs)

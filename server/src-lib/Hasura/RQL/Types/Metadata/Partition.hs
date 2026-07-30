{-# LANGUAGE ScopedTypeVariables #-}

-- | Splitting 'Metadata' into per-@(source, DB schema)@ partitions and
-- reassembling it (Phase 2, see @rfcs/per-schema-gql-context.md@ §11).
--
-- The metadata catalog is partitioned so that a mutation touching one
-- @(source, schema)@ rewrites only that partition's row instead of the whole
-- @hdb_metadata@ blob. A source's tables / functions / stored procedures carry
-- a schema component in their (qualified) names, so they can be grouped by
-- schema using the same 'BackendMetadata' primitives ('tableNameSchema',
-- 'functionNameSchema') that 'Hasura.GraphQL.Schema.partitionSourceBySchema'
-- uses for 'SourceInfo'. Native queries and logical models have no schema
-- component, so they remain in the skeleton.
module Hasura.RQL.Types.Metadata.Partition
  ( splitSourceMetadataBySchema,
    splitMetadataBySchema,
    reassembleMetadata,
  )
where

import Autodocodec.Aeson qualified as AC
import Data.Aeson (Value, (.!=), (.:?), (.=))
import Data.Aeson qualified as J
import Data.Aeson.Types qualified as JT
import Data.HashMap.Strict qualified as HashMap
import Data.HashMap.Strict.InsOrd qualified as InsOrdHashMap
import Hasura.Backends.Postgres.SQL.Types (SchemaName)
import Hasura.Base.Error (QErr, throw500)
import Hasura.Function.Metadata (FunctionMetadata (..))
import Hasura.Prelude
import Hasura.RQL.Types.Common (SourceName)
import Hasura.RQL.Types.Metadata (Metadata (..))
import Hasura.RQL.Types.Metadata.Backend (BackendMetadata, functionNameSchema, tableNameSchema)
import Hasura.RQL.Types.Metadata.Common
  ( BackendSourceMetadata (..),
    Functions,
    SourceMetadata (..),
    StoredProcedures,
    Tables,
  )
-- Brings every backend's 'BackendMetadata' instance into scope so the
-- 'AB.dispatchAnyBackend @BackendMetadata' calls below resolve.
import Hasura.RQL.Types.Metadata.Instances ()
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.StoredProcedure.Metadata (StoredProcedureMetadata (..))
import Hasura.Table.Metadata (TableMetadata (..))

-- | Split one source's metadata into a skeleton (its schema-scoped groups
-- emptied; native queries / logical models retained) and one JSON payload per
-- DB schema. Each payload is a @{tables, functions, stored_procedures}@ object
-- holding only that schema's objects, serialized with the existing per-object
-- 'ToJSON' instances so 'reassembleMetadata' can parse them straight back.
splitSourceMetadataBySchema ::
  forall b.
  (BackendMetadata b) =>
  SourceMetadata b ->
  (SourceMetadata b, HashMap SchemaName Value)
splitSourceMetadataBySchema sm =
  (skeleton, HashMap.mapWithKey buildPayload allSchemas)
  where
    schemasOf :: (k -> SchemaName) -> InsOrdHashMap.InsOrdHashMap k v -> [SchemaName]
    schemasOf f = map f . InsOrdHashMap.keys

    allSchemas :: HashMap SchemaName ()
    allSchemas =
      HashMap.fromList
        $ map (,())
        $ schemasOf (tableNameSchema @b) (_smTables sm)
        <> schemasOf (functionNameSchema @b) (_smFunctions sm)
        <> schemasOf (functionNameSchema @b) (_smStoredProcedures sm)

    -- The schema-scoped groups live in the partitions; everything else
    -- (config, kind, customization, native queries, logical models) stays.
    skeleton =
      sm
        { _smTables = mempty,
          _smFunctions = mempty,
          _smStoredProcedures = mempty
        }

    -- Serialize each object via its 'HasCodec' instance (NOT 'ToJSON', which is
    -- not the inverse of 'FromJSON' for these types — e.g. relationships) so
    -- 'parsePartitionPayload' round-trips exactly.
    buildPayload :: SchemaName -> () -> Value
    buildPayload schemaName _ =
      J.object
        [ "tables"
            .= map AC.toJSONViaCodec (InsOrdHashMap.elems (InsOrdHashMap.filterWithKey (\tn _ -> tableNameSchema @b tn == schemaName) (_smTables sm))),
          "functions"
            .= map AC.toJSONViaCodec (InsOrdHashMap.elems (InsOrdHashMap.filterWithKey (\fn _ -> functionNameSchema @b fn == schemaName) (_smFunctions sm))),
          "stored_procedures"
            .= map AC.toJSONViaCodec (InsOrdHashMap.elems (InsOrdHashMap.filterWithKey (\fn _ -> functionNameSchema @b fn == schemaName) (_smStoredProcedures sm)))
        ]

-- | Split a whole 'Metadata' into a skeleton (per-source schema-scoped groups
-- emptied) and a flat list of @(source, schema)@ partition payloads.
splitMetadataBySchema :: Metadata -> (Metadata, [(SourceName, SchemaName, Value)])
splitMetadataBySchema md =
  (md {_metaSources = skeletonSources}, partitions)
  where
    results =
      [ splitOne sourceName backendSourceMeta
        | (sourceName, backendSourceMeta) <- InsOrdHashMap.toList (_metaSources md)
      ]

    skeletonSources = InsOrdHashMap.fromList [(sn, skel) | (sn, skel, _) <- results]
    partitions =
      [ (sn, schemaName, payload)
        | (sn, _, parts) <- results,
          (schemaName, payload) <- HashMap.toList parts
      ]

    splitOne sn (BackendSourceMetadata anyMeta) =
      AB.dispatchAnyBackend @BackendMetadata anyMeta $ \(sm :: SourceMetadata b) ->
        let (skel, parts) = splitSourceMetadataBySchema sm
         in (sn, BackendSourceMetadata (AB.mkAnyBackend skel), parts)

-- | Merge per-@(source, schema)@ partition payloads back into a skeleton
-- 'Metadata'. The skeleton determines each source's backend, so the payloads
-- are parsed with that backend's instances. Object ordering is irrelevant: the
-- metadata codec sorts collections on export.
reassembleMetadata :: Metadata -> [(SourceName, SchemaName, Value)] -> Either QErr Metadata
reassembleMetadata skeleton partitions = do
  sources' <- InsOrdHashMap.traverseWithKey mergeSource (_metaSources skeleton)
  pure skeleton {_metaSources = sources'}
  where
    partitionsBySource :: HashMap SourceName [Value]
    partitionsBySource =
      HashMap.fromListWith (<>) [(sn, [payload]) | (sn, _schemaName, payload) <- partitions]

    mergeSource :: SourceName -> BackendSourceMetadata -> Either QErr BackendSourceMetadata
    mergeSource sn (BackendSourceMetadata anyMeta) =
      AB.dispatchAnyBackend @BackendMetadata anyMeta $ \(sm :: SourceMetadata b) -> do
        let payloads = HashMap.findWithDefault [] sn partitionsBySource
        merged <- foldM (mergePartition @b) sm payloads
        pure $ BackendSourceMetadata (AB.mkAnyBackend merged)

    mergePartition ::
      forall b.
      (BackendMetadata b) =>
      SourceMetadata b ->
      Value ->
      Either QErr (SourceMetadata b)
    mergePartition sm payload = do
      (tbls, fns, sps) <- parsePartitionPayload @b payload
      pure
        sm
          { _smTables = _smTables sm <> tbls,
            _smFunctions = _smFunctions sm <> fns,
            _smStoredProcedures = _smStoredProcedures sm <> sps
          }

parsePartitionPayload ::
  forall b.
  (BackendMetadata b) =>
  Value ->
  Either QErr (Tables b, Functions b, StoredProcedures b)
parsePartitionPayload payload =
  either (\e -> throw500 $ "could not parse metadata partition: " <> tshow e) pure
    $ flip JT.parseEither payload
    $ J.withObject "metadata partition" \o -> do
      tableVals <- o .:? "tables" .!= []
      functionVals <- o .:? "functions" .!= []
      storedProcVals <- o .:? "stored_procedures" .!= []
      tbls <- oMapFromL _tmTable <$> traverse (AC.parseJSONViaCodec @(TableMetadata b)) tableVals
      fns <- oMapFromL _fmFunction <$> traverse (AC.parseJSONViaCodec @(FunctionMetadata b)) functionVals
      sps <- oMapFromL _spmStoredProcedure <$> traverse (AC.parseJSONViaCodec @(StoredProcedureMetadata b)) storedProcVals
      pure (tbls, fns, sps)
module Hasura.RQL.DDL.Schema.Cache.PartialRebuildSpec (spec) where

import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.List.NonEmpty qualified as NE
import Data.Text.NonEmpty (mkNonEmptyTextUnsafe)
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types
  ( FunctionName (..),
    PGExtraTableMetadata (..),
    PGRawFunctionInfo (..),
    PGScalarType (..),
    PGTypeKind (..),
    QualifiedObject (..),
    SchemaName (..),
    TableName (..),
  )
import Hasura.Function.Cache (FunctionOverloads (..), FunctionVolatility (..))
import Hasura.GraphQL.Context (GQLContext (..))
import Hasura.Incremental qualified as Inc
import Hasura.Prelude
import Hasura.RQL.DDL.Schema.Cache.Common
  ( InvalidationKeys (..),
    initialInvalidationKeys,
    invalidateKeys,
  )
import Hasura.RQL.DDL.Schema.Cache.PartialRebuild
  ( mergeSchemaIntoSchemaCache,
    mergeSchemaIntoSourceInfo,
    partitionIntrospectionBySchema,
  )
import Hasura.RQL.Types.Allowlist (InlinedAllowlist (..))
import Hasura.RQL.Types.ApiLimit (emptyApiLimit)
import Hasura.RQL.Types.BackendType
  ( BackendSourceKind (..),
    BackendType (..),
    PostgresKind (..),
  )
import Hasura.RQL.Types.Common (OID (..), SourceName (..), emptyMetricsConfig)
import Hasura.RQL.Types.NamingCase (NamingCase (..))
import Hasura.RQL.Types.OpenTelemetry
  ( OpenTelemetryInfo (..),
    defaultOtelBatchSpanProcessorInfo,
    emptyOtelExporterInfo,
  )
import Hasura.RQL.Types.SchemaCache (SchemaCache (..), initialResourceVersion)
import Hasura.RQL.Types.SchemaCache.Build (CacheInvalidations (..))
import Hasura.RQL.Types.Source
  ( BackendSourceInfo,
    DBObjectsIntrospection (..),
    ScalarMap (..),
    SourceInfo (..),
  )
import Hasura.RQL.Types.Source.Table (SourceTableType (..))
import Hasura.RQL.Types.SourceCustomization (ResolvedSourceCustomization (..))
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.Table.Cache
  ( DBTableMetadata (..),
    TableCache,
    TableInfo (..),
    tableInfoName,
  )
import Hasura.RQL.Types.Backend (ScalarType)
import Language.GraphQL.Draft.Syntax (Name, SchemaIntrospection (..), unsafeMkName)
import Test.Hspec
import Test.Parser.Internal (buildTableInfo, tableInfoBuilder)

-------------------------------------------------------------------------------
-- Type aliases

type PGVanilla = 'Postgres 'Vanilla

type PGCitus = 'Postgres 'Citus

-------------------------------------------------------------------------------
-- Helpers

-- | Create a qualified table in a given schema.
mkTableInSchema :: SchemaName -> Text -> QualifiedObject TableName
mkTableInSchema schema name =
  QualifiedObject {qSchema = schema, qName = TableName name}

-- | Build a minimal TableInfo for Postgres Vanilla using a qualified table.
minimalTableInfo :: QualifiedObject TableName -> TableInfo PGVanilla
minimalTableInfo qt = buildTableInfo (tableInfoBuilder qt)

-- | Build a table cache from a list of TableInfo values (key = table name).
makeTableCache :: [TableInfo PGVanilla] -> TableCache PGVanilla
makeTableCache ts =
  HashMap.fromList [(tableInfoName t, t) | t <- ts]

-- | Build a minimal SourceInfo for Postgres Vanilla with the given table cache.
minimalSourceInfo :: TableCache PGVanilla -> SourceInfo PGVanilla
minimalSourceInfo tables =
  SourceInfo
    { _siName = SNDefault,
      _siSourceKind = PostgresVanillaKind,
      _siTables = tables,
      _siFunctions = mempty,
      _siNativeQueries = mempty,
      _siStoredProcedures = mempty,
      _siLogicalModels = mempty,
      _siConfiguration = error "SourceConfig not needed in these tests",
      _siQueryTagsConfig = Nothing,
      _siCustomization = ResolvedSourceCustomization mempty mempty HasuraCase Nothing,
      _siDbObjectsIntrospection = DBObjectsIntrospection mempty mempty (ScalarMap mempty) mempty
    }

-- | Build a minimal SourceInfo for Postgres Citus (used only for backend-type
-- mismatch tests — tables will be empty).
minimalCitusSourceInfo :: SourceInfo PGCitus
minimalCitusSourceInfo =
  SourceInfo
    { _siName = SNDefault,
      _siSourceKind = PostgresCitusKind,
      _siTables = mempty,
      _siFunctions = mempty,
      _siNativeQueries = mempty,
      _siStoredProcedures = mempty,
      _siLogicalModels = mempty,
      _siConfiguration = error "SourceConfig not needed in these tests",
      _siQueryTagsConfig = Nothing,
      _siCustomization = ResolvedSourceCustomization mempty mempty HasuraCase Nothing,
      _siDbObjectsIntrospection = DBObjectsIntrospection mempty mempty (ScalarMap mempty) mempty
    }

-- | A minimal GQLContext whose parsers are never called in these tests.
dummyGQLContext :: GQLContext
dummyGQLContext =
  GQLContext
    { gqlQueryParser = \_ -> error "GQL parser not needed in these tests",
      gqlMutationParser = Nothing,
      gqlSubscriptionParser = Nothing
    }

-- | Build a minimal SchemaCache with just the given source cache; all other
-- fields are set to inert defaults since the functions under test only touch
-- 'scSources'.
minimalSchemaCache :: HashMap SourceName BackendSourceInfo -> SchemaCache
minimalSchemaCache sources =
  SchemaCache
    { scSources = sources,
      scActions = mempty,
      scRemoteSchemas = mempty,
      scAllowlist = InlinedAllowlist mempty mempty,
      scAdminIntrospection = SchemaIntrospection mempty,
      scGQLContext = mempty,
      scUnauthenticatedGQLContext = dummyGQLContext,
      scRelayContext = mempty,
      scUnauthenticatedRelayContext = dummyGQLContext,
      scDepMap = mempty,
      scInconsistentObjs = [],
      scCronTriggers = mempty,
      scEndpoints = mempty,
      scApiLimits = emptyApiLimit,
      scMetricsConfig = emptyMetricsConfig,
      scMetadataResourceVersion = initialResourceVersion,
      scSetGraphqlIntrospectionOptions = mempty,
      scTlsAllowlist = [],
      scQueryCollections = mempty,
      scBackendCache = mempty,
      scSourceHealthChecks = mempty,
      scSourcePingConfig = mempty,
      scOpenTelemetryConfig = OpenTelemetryInfo emptyOtelExporterInfo defaultOtelBatchSpanProcessorInfo
    }

-- | Minimal DBTableMetadata for Postgres (used in introspection tests).
minimalDBTableMeta :: DBTableMetadata PGVanilla
minimalDBTableMeta =
  DBTableMetadata
    { _ptmiOid = OID 0,
      _ptmiColumns = [],
      _ptmiPrimaryKey = Nothing,
      _ptmiUniqueConstraints = mempty,
      _ptmiForeignKeys = mempty,
      _ptmiViewInfo = Nothing,
      _ptmiDescription = Nothing,
      _ptmiExtraTableMetadata = PGExtraTableMetadata Table
    }

-- | Minimal PGRawFunctionInfo (used in introspection tests).
minimalRawFunctionInfo :: PGRawFunctionInfo
minimalRawFunctionInfo =
  PGRawFunctionInfo
    { rfiOid = OID 0,
      rfiHasVariadic = False,
      rfiFunctionType = FTVOLATILE,
      rfiReturnTypeSchema = SchemaName "pg_catalog",
      rfiReturnTypeName = PGInteger,
      rfiReturnTypeType = PGKindBase,
      rfiReturnsSet = False,
      rfiInputArgTypes = [],
      rfiInputArgNames = [],
      rfiDefaultArgs = 0,
      rfiReturnsTable = False,
      rfiDescription = Nothing
    }

-- | Build a FunctionOverloads with a single minimal entry.
singleFnOverload :: FunctionOverloads PGVanilla
singleFnOverload = FunctionOverloads (NE.singleton minimalRawFunctionInfo)

-- | Create a (SourceName, SchemaName) key.
srcSchema :: SourceName -> SchemaName -> (SourceName, SchemaName)
srcSchema = (,)

-------------------------------------------------------------------------------
-- Spec

spec :: Spec
spec = do
  spec_mergeSchemaIntoSourceInfo
  spec_mergeSchemaIntoSchemaCache
  spec_partitionIntrospectionBySchema
  spec_invalidateKeys

-------------------------------------------------------------------------------
-- mergeSchemaIntoSourceInfo

spec_mergeSchemaIntoSourceInfo :: Spec
spec_mergeSchemaIntoSourceInfo = describe "mergeSchemaIntoSourceInfo" do
  it "replaces only the target schema, leaving others intact" do
    let publicT = mkTableInSchema "public" "users"
        analyticsT1 = mkTableInSchema "analytics" "events"
        analyticsT2 = mkTableInSchema "analytics" "clicks"
        newAnalyticsT = mkTableInSchema "analytics" "sessions"

        existing =
          minimalSourceInfo
            $ makeTableCache
              [ minimalTableInfo publicT,
                minimalTableInfo analyticsT1,
                minimalTableInfo analyticsT2
              ]

        newTables =
          HashMap.singleton newAnalyticsT (minimalTableInfo newAnalyticsT)

        result = mergeSchemaIntoSourceInfo @PGVanilla "analytics" newTables existing
        resultKeys = HashMap.keysSet (_siTables result)

    -- New analytics table present
    resultKeys `setContains` [newAnalyticsT]
    -- Old public table preserved
    resultKeys `setContains` [publicT]
    -- Old analytics tables replaced
    resultKeys `setNotContains` [analyticsT1, analyticsT2]

  it "drops tables removed from the rebuilt schema" do
    let t1 = mkTableInSchema "analytics" "t1"
        t2 = mkTableInSchema "analytics" "t2"
        existing =
          minimalSourceInfo
            $ makeTableCache [minimalTableInfo t1, minimalTableInfo t2]
        newTables = HashMap.singleton t1 (minimalTableInfo t1)

        result = mergeSchemaIntoSourceInfo @PGVanilla "analytics" newTables existing
        resultKeys = HashMap.keysSet (_siTables result)

    resultKeys `setContains` [t1]
    resultKeys `setNotContains` [t2]

  it "is a no-op on other schemas when the rebuilt schema is absent in existing" do
    let publicT = mkTableInSchema "public" "users"
        stagingT = mkTableInSchema "staging" "orders"
        existing =
          minimalSourceInfo
            $ makeTableCache [minimalTableInfo publicT]
        newTables = HashMap.singleton stagingT (minimalTableInfo stagingT)

        result = mergeSchemaIntoSourceInfo @PGVanilla "staging" newTables existing
        resultKeys = HashMap.keysSet (_siTables result)

    -- The new staging table is present (union semantics)
    resultKeys `setContains` [stagingT]
    -- The existing public table is untouched
    resultKeys `setContains` [publicT]

  it "does not touch tables in schemas other than the one being rebuilt" do
    let publicT = mkTableInSchema "public" "users"
        analyticsT = mkTableInSchema "analytics" "events"
        reportingT = mkTableInSchema "reporting" "summary"
        newAnalyticsT = mkTableInSchema "analytics" "new_events"

        existing =
          minimalSourceInfo
            $ makeTableCache
              [ minimalTableInfo publicT,
                minimalTableInfo analyticsT,
                minimalTableInfo reportingT
              ]
        newTables = HashMap.singleton newAnalyticsT (minimalTableInfo newAnalyticsT)

        result = mergeSchemaIntoSourceInfo @PGVanilla "analytics" newTables existing
        resultKeys = HashMap.keysSet (_siTables result)

    -- Other schemas' tables are present
    resultKeys `setContains` [publicT, reportingT]
    -- The old analytics table is gone; the new one is present
    resultKeys `setContains` [newAnalyticsT]
    resultKeys `setNotContains` [analyticsT]

-------------------------------------------------------------------------------
-- mergeSchemaIntoSchemaCache

spec_mergeSchemaIntoSchemaCache :: Spec
spec_mergeSchemaIntoSchemaCache = describe "mergeSchemaIntoSchemaCache" do
  it "returns the cache unchanged when the source is absent" do
    let cache = minimalSchemaCache mempty
        freshBSI = AB.mkAnyBackend @PGVanilla (minimalSourceInfo mempty)
        result = mergeSchemaIntoSchemaCache cache SNDefault "public" freshBSI

    HashMap.size (scSources result) `shouldBe` 0

  it "preserves the old entry when backend types do not match" do
    let oldTables = makeTableCache [minimalTableInfo (mkTableInSchema "public" "t1")]
        oldBSI = AB.mkAnyBackend @PGVanilla (minimalSourceInfo oldTables)
        freshBSI = AB.mkAnyBackend @PGCitus minimalCitusSourceInfo

        cache = minimalSchemaCache (HashMap.singleton SNDefault oldBSI)
        result = mergeSchemaIntoSchemaCache cache SNDefault "public" freshBSI

    -- Source still present
    HashMap.size (scSources result) `shouldBe` 1

    -- Old entry preserved: unpack as Vanilla succeeds and tables are unchanged
    let resultSI = AB.unpackAnyBackend @PGVanilla =<< HashMap.lookup SNDefault (scSources result)
    case resultSI of
      Nothing -> expectationFailure "Expected a Vanilla SourceInfo to be present"
      Just si ->
        HashMap.keysSet (_siTables si)
          `shouldBe` HashMap.keysSet oldTables

  it "merges fresh tables for the given schema, leaving other schemas intact" do
    let publicT = mkTableInSchema "public" "users"
        oldAnalyticsT = mkTableInSchema "analytics" "old_events"
        newAnalyticsT = mkTableInSchema "analytics" "new_events"

        oldTables = makeTableCache [minimalTableInfo publicT, minimalTableInfo oldAnalyticsT]
        freshTables = makeTableCache [minimalTableInfo newAnalyticsT]

        oldBSI = AB.mkAnyBackend @PGVanilla (minimalSourceInfo oldTables)
        freshBSI = AB.mkAnyBackend @PGVanilla (minimalSourceInfo freshTables)

        cache = minimalSchemaCache (HashMap.singleton SNDefault oldBSI)
        result = mergeSchemaIntoSchemaCache cache SNDefault "analytics" freshBSI

    let resultSI =
          AB.unpackAnyBackend @PGVanilla =<< HashMap.lookup SNDefault (scSources result)
    case resultSI of
      Nothing -> expectationFailure "Expected a Vanilla SourceInfo to be present"
      Just si -> do
        let resultKeys = HashMap.keysSet (_siTables si)
        -- New analytics table present
        resultKeys `setContains` [newAnalyticsT]
        -- Old analytics table replaced
        resultKeys `setNotContains` [oldAnalyticsT]
        -- Public table untouched
        resultKeys `setContains` [publicT]

-------------------------------------------------------------------------------
-- partitionIntrospectionBySchema

spec_partitionIntrospectionBySchema :: Spec
spec_partitionIntrospectionBySchema = describe "partitionIntrospectionBySchema" do
  it "places each table into its schema's bucket" do
    let t_public = mkTableInSchema "public" "users"
        t_analytics1 = mkTableInSchema "analytics" "events"
        t_analytics2 = mkTableInSchema "analytics" "clicks"
        introspection =
          DBObjectsIntrospection
            { _rsTables =
                HashMap.fromList
                  [ (t_public, minimalDBTableMeta),
                    (t_analytics1, minimalDBTableMeta),
                    (t_analytics2, minimalDBTableMeta)
                  ],
              _rsFunctions = mempty,
              _rsScalars = ScalarMap mempty,
              _rsLogicalModels = mempty
            }
        result = partitionIntrospectionBySchema @PGVanilla introspection

    HashMap.keysSet result `shouldBe` HashSet.fromList ["public", "analytics"]

    let publicSlice = HashMap.lookup "public" result
        analyticsSlice = HashMap.lookup "analytics" result

    fmap (HashMap.keysSet . _rsTables) publicSlice
      `shouldBe` Just (HashSet.singleton t_public)

    fmap (HashMap.keysSet . _rsTables) analyticsSlice
      `shouldBe` Just (HashSet.fromList [t_analytics1, t_analytics2])

  it "places each function into its schema's bucket" do
    let fn_public = mkFn "public" "fn_public"
        fn_analytics = mkFn "analytics" "fn_analytics"
        introspection =
          DBObjectsIntrospection
            { _rsTables = mempty,
              _rsFunctions =
                HashMap.fromList
                  [ (fn_public, singleFnOverload),
                    (fn_analytics, singleFnOverload)
                  ],
              _rsScalars = ScalarMap mempty,
              _rsLogicalModels = mempty
            }
        result = partitionIntrospectionBySchema @PGVanilla introspection

    HashMap.keysSet result `shouldBe` HashSet.fromList ["public", "analytics"]

    let publicSlice = HashMap.lookup "public" result
        analyticsSlice = HashMap.lookup "analytics" result

    fmap (HashMap.keysSet . _rsFunctions) publicSlice
      `shouldBe` Just (HashSet.singleton fn_public)

    fmap (HashMap.keysSet . _rsFunctions) analyticsSlice
      `shouldBe` Just (HashSet.singleton fn_analytics)

  it "broadcasts scalars and logicalModels to every schema slice" do
    let t_public = mkTableInSchema "public" "users"
        t_analytics = mkTableInSchema "analytics" "events"
        sharedScalars = ScalarMap (HashMap.singleton (unsafeMkName "int4") PGInteger)
        introspection =
          DBObjectsIntrospection
            { _rsTables =
                HashMap.fromList
                  [ (t_public, minimalDBTableMeta),
                    (t_analytics, minimalDBTableMeta)
                  ],
              _rsFunctions = mempty,
              _rsScalars = sharedScalars,
              _rsLogicalModels = mempty
            }
        result = partitionIntrospectionBySchema @PGVanilla introspection

    -- Both slices share the same scalar keys
    let publicScalars = fmap (HashMap.keys . getScalarMap . _rsScalars) (HashMap.lookup "public" result)
        analyticsScalars = fmap (HashMap.keys . getScalarMap . _rsScalars) (HashMap.lookup "analytics" result)
        expectedScalarKeys = HashMap.keys (getScalarMap sharedScalars)
    publicScalars `shouldBe` Just expectedScalarKeys
    analyticsScalars `shouldBe` Just expectedScalarKeys

  it "returns an empty map for empty introspection" do
    let result =
          partitionIntrospectionBySchema @PGVanilla
            (DBObjectsIntrospection mempty mempty (ScalarMap mempty) mempty)

    HashMap.size result `shouldBe` 0

-------------------------------------------------------------------------------
-- invalidateKeys — ciSourceSchemas behaviour

spec_invalidateKeys :: Spec
spec_invalidateKeys = describe "invalidateKeys / ciSourceSchemas" do
  it "increments only the targeted (source, schema) key; others unchanged" do
    let src = SNDefault
        schemaA = "schema_a"
        schemaB = "schema_b"
        src2 = SNName (mkNonEmptyTextUnsafe "src2")

        baseKeys =
          initialInvalidationKeys
            { _ikSourceSchemas =
                HashMap.fromList
                  [ (srcSchema src schemaA, Inc.initialInvalidationKey),
                    (srcSchema src schemaB, Inc.initialInvalidationKey),
                    (srcSchema src2 schemaA, Inc.initialInvalidationKey)
                  ]
            }
        ci = mempty {ciSourceSchemas = HashSet.singleton (srcSchema src schemaA)}
        result = invalidateKeys ci baseKeys

    -- Targeted key was incremented
    HashMap.lookup (srcSchema src schemaA) (_ikSourceSchemas result)
      `shouldBe` Just (Inc.invalidate Inc.initialInvalidationKey)

    -- Other keys are unchanged
    HashMap.lookup (srcSchema src schemaB) (_ikSourceSchemas result)
      `shouldBe` Just Inc.initialInvalidationKey

    HashMap.lookup (srcSchema src2 schemaA) (_ikSourceSchemas result)
      `shouldBe` Just Inc.initialInvalidationKey

  it "cascades to all schema keys for a fully-invalidated source" do
    let src = SNDefault
        schemaA = "schema_a"
        schemaB = "schema_b"

        baseKeys =
          initialInvalidationKeys
            { _ikSourceSchemas =
                HashMap.fromList
                  [ (srcSchema src schemaA, Inc.initialInvalidationKey),
                    (srcSchema src schemaB, Inc.initialInvalidationKey)
                  ]
            }
        ci = mempty {ciSources = HashSet.singleton src}
        result = invalidateKeys ci baseKeys

    -- Both schema keys for 'src' are incremented
    HashMap.lookup (srcSchema src schemaA) (_ikSourceSchemas result)
      `shouldBe` Just (Inc.invalidate Inc.initialInvalidationKey)

    HashMap.lookup (srcSchema src schemaB) (_ikSourceSchemas result)
      `shouldBe` Just (Inc.invalidate Inc.initialInvalidationKey)

  it "does not touch other sources' schema keys when one source is fully invalidated" do
    let src1 = SNName (mkNonEmptyTextUnsafe "src1")
        src2 = SNName (mkNonEmptyTextUnsafe "src2")
        schemaA = "schema_a"

        baseKeys =
          initialInvalidationKeys
            { _ikSourceSchemas =
                HashMap.fromList
                  [ (srcSchema src1 schemaA, Inc.initialInvalidationKey),
                    (srcSchema src2 schemaA, Inc.initialInvalidationKey)
                  ]
            }
        ci = mempty {ciSources = HashSet.singleton src1}
        result = invalidateKeys ci baseKeys

    -- src1's schema key is incremented
    HashMap.lookup (srcSchema src1 schemaA) (_ikSourceSchemas result)
      `shouldBe` Just (Inc.invalidate Inc.initialInvalidationKey)

    -- src2's schema key is untouched
    HashMap.lookup (srcSchema src2 schemaA) (_ikSourceSchemas result)
      `shouldBe` Just Inc.initialInvalidationKey

  it "touches nothing when both ciSources and ciSourceSchemas are empty" do
    let src = SNDefault
        schemaA = "schema_a"

        baseKeys =
          initialInvalidationKeys
            { _ikSourceSchemas =
                HashMap.singleton (srcSchema src schemaA) Inc.initialInvalidationKey
            }
        result = invalidateKeys mempty baseKeys

    _ikSourceSchemas result `shouldBe` _ikSourceSchemas baseKeys

-------------------------------------------------------------------------------
-- Internal test helpers

getScalarMap :: ScalarMap b -> HashMap.HashMap Name (ScalarType b)
getScalarMap (ScalarMap m) = m

mkFn :: SchemaName -> Text -> QualifiedObject FunctionName
mkFn schema name = QualifiedObject {qSchema = schema, qName = FunctionName name}

-- | Assert that all given elements are members of the 'HashSet'.
setContains ::
  (Hashable a) =>
  HashSet.HashSet a ->
  [a] ->
  IO ()
setContains hs xs =
  mapM_ (\x -> HashSet.member x hs `shouldBe` True) xs

-- | Assert that none of the given elements are members of the 'HashSet'.
setNotContains ::
  (Hashable a) =>
  HashSet.HashSet a ->
  [a] ->
  IO ()
setNotContains hs xs =
  mapM_ (\x -> HashSet.member x hs `shouldBe` False) xs

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Phase 8 Stage 2d: the correctness gate for 'EFPersistentMemoCache'.
--
-- Everything else in Phase 8 tests /mechanism/: that @evictWith@ reaches the right
-- nodes, that each memo key shape is classified as intended. None of it can prove
-- the classification is __complete__ — a shape nobody thought of is only safe if
-- someone thought to leave it in the conservative bucket. A shape silently misread
-- as "provably unaffected" gets reused stale, and the engine then serves a wrong
-- GraphQL schema with no crash and no log line.
--
-- The only thing that catches that is differential testing: build a schema
-- incrementally (seeded from a previous build, then evicted) and cold (from
-- @mempty@), and assert both produce __identical SDL__. A stale parser shows up as
-- a diff.
--
-- The fixture deliberately has a relationship. Production metadata has almost none
-- (28 across 653 tables, RFC §9), so a fixture modelled on production would
-- exercise no transitive invalidation and would pass a broken evictor.
module Hasura.GraphQL.Schema.MemoCacheGateSpec (spec) where

import Data.Aeson (toJSON)
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Text.NonEmpty (nonEmptyTextQQ)
import Hasura.Authentication.Role (adminRoleName)
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types (PGScalarType (..), QualifiedTable, SchemaName (..))
import Hasura.Base.Error (showQErr)
import Hasura.GraphQL.ApolloFederation (generateSDL)
import Hasura.Server.Types (ApolloFederationStatus (..))
import Hasura.GraphQL.Schema (assemblePerPairContexts, buildAllRoleParsersForSchema)
import Hasura.GraphQL.Schema.Common (SchemaSampledFeatureFlags (..))
import Hasura.GraphQL.Schema.TableFieldCache (TableFieldStore, newTableFieldStore)
import Hasura.Prelude
import Hasura.RQL.Types.BackendType (BackendSourceKind (PostgresVanillaKind), BackendType (Postgres), PostgresKind (Vanilla))
import Hasura.RQL.Types.Column (ColumnType (..))
import Hasura.RQL.Types.Common (InsertOrder (..), RelName (..), RelType (..), SQLGenCtx (..), SourceName (..))
import Hasura.RQL.Types.NamingCase (NamingCase (..))
import Hasura.RQL.Types.Relationships.Local (RelInfo (..), RelMapping (..), RelTarget (..))
import Hasura.RQL.Types.Schema.Options qualified as Options
import Hasura.RQL.Types.Source (DBObjectsIntrospection (..), SourceInfo (..))
import Hasura.RQL.Types.SourceCustomization (ResolvedSourceCustomization (..))
import Hasura.Table.Cache (TableCoreInfoG (_tciName), TableInfo (_tiCoreInfo))
import Test.Hspec
import Test.Parser.Internal
  ( ColumnInfoBuilder (..),
    TableInfoBuilder (columns, relations),
    buildTableInfo,
    mkTable,
    tableInfoBuilder,
  )
import Test.Parser.Monad (defaultSchemaOptions, notImplementedYet)

type PG = 'Postgres 'Vanilla

--------------------------------------------------------------------------------
-- Fixture: album 1--* track.
--
-- The relationship is the point: album's selection set embeds track's, so a change
-- to track must transitively invalidate album. If the evictor misses that edge,
-- album keeps a parser referencing track's *old* definition and the SDL diverges.

albumTable, trackTable :: QualifiedTable
albumTable = mkTable "album"
trackTable = mkTable "track"

col :: Text -> Int -> ColumnType PG -> ColumnInfoBuilder
col name pos ty =
  ColumnInfoBuilder
    { cibName = name,
      cibPosition = pos,
      cibType = ty,
      cibNullable = False,
      cibIsPrimaryKey = name == "id"
    }

tracksRel :: RelInfo PG
tracksRel =
  RelInfo
    { riName = RelName [nonEmptyTextQQ|tracks|],
      riType = ArrRel,
      riMapping = RelMapping $ HashMap.fromList [("id", "album_id")],
      riTarget = RelTargetTable trackTable,
      riIsManual = False,
      riInsertOrder = AfterParent
    }

albumTableInfo :: TableInfo PG
albumTableInfo =
  buildTableInfo
    (tableInfoBuilder albumTable)
      { columns = [col "id" 1 (ColumnScalar PGInteger), col "title" 2 (ColumnScalar PGText)],
        relations = [tracksRel]
      }

-- | @track@ before and after a metadata change. The extra column is what a
-- @run_sql ALTER TABLE ADD COLUMN@ would produce.
trackTableInfo :: Bool -> TableInfo PG
trackTableInfo withExtraColumn =
  buildTableInfo
    (tableInfoBuilder trackTable)
      { columns =
          [col "id" 1 (ColumnScalar PGInteger), col "album_id" 2 (ColumnScalar PGInteger)]
            <> [col "duration" 3 (ColumnScalar PGInteger) | withExtraColumn],
        relations = []
      }

mkSourceInfo :: [TableInfo PG] -> SourceInfo PG
mkSourceInfo tables =
  SourceInfo
    { _siName = SNDefault,
      _siSourceKind = PostgresVanillaKind,
      _siTables = HashMap.fromList [(_tciName (_tiCoreInfo ti), ti) | ti <- tables],
      _siFunctions = mempty,
      _siNativeQueries = mempty,
      _siStoredProcedures = mempty,
      _siLogicalModels = mempty,
      _siConfiguration = notImplementedYet "SourceConfig",
      _siQueryTagsConfig = Nothing,
      _siCustomization = ResolvedSourceCustomization mempty mempty HasuraCase Nothing,
      _siDbObjectsIntrospection = DBObjectsIntrospection mempty mempty mempty mempty
    }

-- | The schema before the change.
sourceBefore :: SourceInfo PG
sourceBefore = mkSourceInfo [albumTableInfo, trackTableInfo False]

-- | The schema after @track@ gains a column.
sourceAfter :: SourceInfo PG
sourceAfter = mkSourceInfo [albumTableInfo, trackTableInfo True]

--------------------------------------------------------------------------------
-- Driving a build

-- | 'Nothing' builds cold (the default engine path); 'Just' seeds from the store
-- and evicts, i.e. the 'EFPersistentMemoCache' path.
-- | Build the parsers, then assemble them exactly as the engine does, and render
-- the resulting introspection as SDL.
--
-- Going through 'assemblePerPairContexts' rather than re-deriving the type
-- universe by hand matters: it is the same call the engine makes, so the SDL
-- compared here is the SDL a client would actually receive.
--
-- 'Nothing' builds cold (the default engine path); 'Just' seeds from the store and
-- evicts, i.e. the 'EFPersistentMemoCache' path.
runBuildSdl :: Maybe TableFieldStore -> SourceInfo PG -> IO Text
runBuildSdl mStore sourceInfo = do
  result <- runExceptT do
    parsers <-
      buildAllRoleParsersForSchema @PG
        mStore
        (SchemaName "public")
        -- computed exactly as Cache.hs does, so the gate exercises the real key
        (toJSON <$> _siTables sourceInfo)
        sampledFlags
        defaultSchemaOptions
        mempty -- SourceCache: no remote relationships in this fixture
        mempty -- remote schemas
        Options.DisableRemoteSchemaPermissions
        [adminRoleName]
        sourceInfo
    assemblePerPairContexts
      sampledFlags
      (sqlGenCtx, Options.InferFunctionPermissions)
      mempty
      Options.DisableRemoteSchemaPermissions
      mempty -- experimental features
      ApolloFederationDisabled
      Nothing -- no schema registry
      parsers
  case result of
    Left err -> error ("schema build failed: " <> T.unpack (showQErr err))
    Right byRole -> case HashMap.lookup adminRoleName byRole of
      Nothing -> error "admin role missing from build output"
      Just (_, _, introspection) -> pure (generateSDL introspection)
  where
    sampledFlags = SchemaSampledFeatureFlags []
    -- Matches Test.Parser.Monad's defaultSchemaOptions, so the options
    -- 'assemblePerPairContexts' derives agree with the ones the parsers were built
    -- under. Only equality between the two builds matters, not the values.
    sqlGenCtx =
      SQLGenCtx
        { stringifyNum = Options.Don'tStringifyNumbers,
          dangerousBooleanCollapse = Options.Don'tDangerouslyCollapseBooleans,
          nullInNonNullableVariables = Options.Don'tAllowNullInNonNullableVariables,
          noNullUnboundVariableDefault = Options.DefaultUnboundNullableVariablesToNull,
          removeEmptySubscriptionResponses = Options.PreserveEmptyResponses,
          remoteNullForwardingPolicy = Options.RemoteForwardAccurately,
          optimizePermissionFilters = Options.Don'tOptimizePermissionFilters,
          bigqueryStringNumericInput = Options.EnableBigQueryStringNumericInput
        }

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "persistent memo cache: incremental build == cold build" do
  it "reuse with no change at all preserves the SDL" do
    store <- newTableFieldStore
    _ <- runBuildSdl (Just store) sourceBefore
    -- second pass reuses everything; nothing changed, so nothing may drift
    incremental <- runBuildSdl (Just store) sourceBefore
    cold <- runBuildSdl Nothing sourceBefore
    incremental `shouldBe` cold

  it "a changed table's own parsers are rebuilt, not reused stale" do
    store <- newTableFieldStore
    _ <- runBuildSdl (Just store) sourceBefore
    incremental <- runBuildSdl (Just store) sourceAfter
    cold <- runBuildSdl Nothing sourceAfter
    -- if track's nodes were reused, `duration` would be missing here
    incremental `shouldBe` cold

  it "a change to track transitively rebuilds album, which embeds it" do
    -- This is the case the dependency graph exists for. album's key does not
    -- change, so only reverse reachability from track can save it.
    store <- newTableFieldStore
    _ <- runBuildSdl (Just store) sourceBefore
    incremental <- runBuildSdl (Just store) sourceAfter
    cold <- runBuildSdl Nothing sourceAfter
    incremental `shouldBe` cold

  it "reverting a change also reverts the SDL" do
    store <- newTableFieldStore
    _ <- runBuildSdl (Just store) sourceBefore
    _ <- runBuildSdl (Just store) sourceAfter
    incremental <- runBuildSdl (Just store) sourceBefore
    cold <- runBuildSdl Nothing sourceBefore
    incremental `shouldBe` cold

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Hasura.GraphQL.Schema
  ( buildGQLContext,
    buildSchemaOptions,
    buildSchemaRoleParsers,
    buildAllRoleParsersForSchema,
    assemblePerPairContexts,
    partitionSourceBySchema,
    SchemaFieldParsers (..),
    RoleContextValue,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Exception qualified as E
import Control.Lens hiding (contexts)
import Control.Monad.Memoize
import Data.Aeson qualified as J
import Data.Aeson.Ordered qualified as JO
import Data.HashMap.Strict qualified as HashMap
import Data.HashMap.Strict.InsOrd qualified as InsOrdHashMap
import Data.HashSet qualified as Set
import Data.List.Extended (duplicates)
import Data.Text.Extended
import Data.Text.NonEmpty qualified as NT
import Data.Typeable (Typeable)
import Database.PG.Query.Pool qualified as PG
import Hasura.Authentication.Role (RoleName, adminRoleName, mkRoleNameSafe)
import Hasura.Base.Error
import Hasura.Base.ErrorMessage
import Hasura.Base.ToErrorValue
import Hasura.Function.Cache
import Hasura.GraphQL.ApolloFederation
import Hasura.GraphQL.Context
import Hasura.GraphQL.Namespace
import Hasura.GraphQL.Parser.Schema.Convert (convertToSchemaIntrospection)
import Hasura.GraphQL.Schema.Backend
import Hasura.GraphQL.Schema.Common
import Hasura.GraphQL.Schema.Instances ()
import Hasura.GraphQL.Schema.Introspect
import Hasura.GraphQL.Schema.TableDeps (tableDependencyGraph)
import Hasura.GraphQL.Schema.TableFieldCache (TableFieldStore, TableFieldsCacher (..), mkTableFieldsCacher, noTableFieldsCache, prepareForBuild)
import Hasura.GraphQL.Schema.Parser
  ( FieldParser,
    Kind (..),
    MonadParse,
    Parser,
    Schema,
  )
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.GraphQL.Schema.Postgres
import Hasura.GraphQL.Schema.Relay
import Hasura.GraphQL.Schema.Remote (buildRemoteParser)
import Hasura.GraphQL.Schema.RemoteRelationship
import Hasura.GraphQL.Schema.Table
import Hasura.GraphQL.Schema.Typename (MkTypename (..))
import Hasura.Logging
import Hasura.LogicalModel.Cache (_lmiPermissions)
import Hasura.Name qualified as Name
import Hasura.NativeQuery.Cache (NativeQueryCache, _nqiReturns)
import Hasura.Prelude
import Hasura.QueryTags.Types
import Hasura.RQL.DDL.SchemaRegistry
import Hasura.RQL.IR
import Hasura.RQL.Types.Action
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.BackendTag (HasTag)
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.CustomTypes
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.Permission
import Hasura.RQL.Types.Relationships.Remote
import Hasura.RQL.Types.Schema.Options (SchemaOptions (..))
import Hasura.RQL.Types.Schema.Options qualified as Options
import Hasura.RQL.Types.SchemaCache hiding (askTableInfo)
import Hasura.RQL.Types.Source
import Hasura.RQL.Types.SourceCustomization as SC
import Hasura.RemoteSchema.Metadata
import Hasura.RemoteSchema.SchemaCache
import Hasura.Backends.Postgres.SQL.Types (SchemaName, getSchemaTxt)
import Hasura.RQL.Types.Metadata.Backend (BackendMetadata, functionNameSchema, tableNameSchema)
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.Server.Init.Logging
import Hasura.Server.Types
import Hasura.StoredProcedure.Cache (StoredProcedureCache, _spiReturns)
import Hasura.Table.Cache
import Language.GraphQL.Draft.Syntax qualified as G
import System.IO.Unsafe (unsafeInterleaveIO)

-------------------------------------------------------------------------------

-- | Per-role field parsers produced for a single DB schema partition of a single source.
-- Designed as a 'Monoid' so that per-schema results can be @mconcat@'d into a per-source
-- result, and per-source results can be @mconcat@'d into the global merged parsers.
data SchemaFieldParsers = SchemaFieldParsers
  { _sfpQuery :: [FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))],
    _sfpMutFrontend :: [FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))],
    _sfpMutBackend :: [FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))],
    _sfpSubscription :: [FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))],
    _sfpApolloFed :: [(G.Name, Parser 'Output P.Parse (ApolloFederationParserFunction P.Parse))]
    -- NOTE: Relay fields are intentionally NOT cached per (source, schema).
    -- The Relay @Node@ interface (and @PageInfo@ etc.) is a single global type
    -- spanning every source/schema; building the per-schema connection types in
    -- separate memoize tables mints divergent @Node@ definitions (each carrying
    -- only its partition's tables) and triggers "conflicting definitions for
    -- GraphQL type 'Node'".  The full Relay schema is therefore built once per
    -- role, in a single memoize pass, in 'assembleRelayRoleContext'.
  }

instance Semigroup SchemaFieldParsers where
  a <> b =
    SchemaFieldParsers
      (_sfpQuery a <> _sfpQuery b)
      (_sfpMutFrontend a <> _sfpMutFrontend b)
      (_sfpMutBackend a <> _sfpMutBackend b)
      (_sfpSubscription a <> _sfpSubscription b)
      (_sfpApolloFed a <> _sfpApolloFed b)

instance Monoid SchemaFieldParsers where
  mempty = SchemaFieldParsers [] [] [] [] []

-------------------------------------------------------------------------------

-- | An alias for the `Context` information that is stored per role and the admin
--    introspection that is stored in the schema cache.
type RoleContextValue = (RoleContext GQLContext, HashSet InconsistentMetadata, G.SchemaIntrospection)

-- Building contexts

-- | Builds the full GraphQL context for a given query type.
--
-- A 'GQLContext' stores how an incoming request should be processed: how to
-- translate each incoming field of a request into a corresponding semantic
-- representation. There is a different one per 'Role', as each role might have
-- different permissions, and therefore not access to the same set of objects in
-- the schema.
--
-- This function takes all necessary information from the metadata, and the
-- 'GraphQLQueryType', and builds all relevant contexts: a hash map from
-- 'RoleName' to their 'GQLContext' and the "default" context for
-- unauthenticated users.
--
-- When building the schema for each role, we treat the remote schemas as
-- "second-class citizens" compared to sources; more specifically, we attempt to
-- detect whether the inclusion of a given remote schema would result in root
-- fields conflict, and only keep schemas that don't generate any. This results
-- in a partial schema being available to the users, and a better error message
-- than would arise from 'safeSelectionSet'.

-- | Carries a 'QErr' from a Relay role-context build that was deferred via
-- 'unsafeInterleaveIO' (see 'buildGQLContext'), so the error can be raised when
-- the lazily-built context is first forced (e.g. on the first @/v1beta1/relay@
-- request). In practice this should never fire: if the Relay schema were going
-- to fail to build, the Hasura schema build would already have failed eagerly.
newtype RelayBuildException = RelayBuildException QErr

instance Show RelayBuildException where
  show (RelayBuildException qerr) = "RelayBuildException " <> show (showQErr qerr)

instance E.Exception RelayBuildException

buildGQLContext ::
  forall m.
  ( MonadError QErr m,
    MonadIO m
  ) =>
  SchemaSampledFeatureFlags ->
  Options.InferFunctionPermissions ->
  Options.RemoteSchemaPermissions ->
  HashSet ExperimentalFeature ->
  SQLGenCtx ->
  ApolloFederationStatus ->
  SourceCache ->
  -- | Per-role, per-(source, schema) field parsers. Unlike the old global build,
  -- these are NOT merged across pairs: each (source, schema) is assembled into
  -- its own 'GQLContext' (see @per-schema-gql-context.md@, Phase 1). Retained
  -- here only to build the root-field routing index.
  HashMap RoleName (HashMap (SourceName, SchemaName) SchemaFieldParsers) ->
  -- | Per-role, per-(source, schema) GraphQL contexts, already assembled and
  -- cached independently per pair in 'buildSchemaCacheRule' (§5.3, "where the
  -- win is"): a mutation to one pair re-assembles only that pair, and this
  -- function just stitches the cached results together. The 'RoleContextValue'
  -- carries the role context, its assembly inconsistencies, and its
  -- introspection universe.
  HashMap RoleName (HashMap (SourceName, SchemaName) RoleContextValue) ->
  HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject) ->
  ActionCache ->
  AnnotatedCustomTypes ->
  Maybe SchemaRegistryContext ->
  Logger Hasura ->
  m
    ( -- Hasura schema, split per (source, schema)
      ( G.SchemaIntrospection,
        HashMap RoleName (HashMap (SourceName, SchemaName) (RoleContext GQLContext)),
        HashMap (SourceName, SchemaName) GQLContext,
        HashMap G.Name (SourceName, SchemaName),
        HashSet InconsistentMetadata
      ),
      -- Relay schema (dormant; still built globally, admin-only deployments don't use it)
      ( HashMap RoleName (RoleContext GQLContext),
        GQLContext
      ),
      SchemaRegistryAction
    )
buildGQLContext
  sampledFeatureFlags
  functionPermissions
  remoteSchemaPermissions
  experimentalFeatures
  sqlGen
  -- 'apolloFederationStatus' is consumed by the per-pair assembly node (which
  -- now runs in 'buildSchemaCacheRule'), not here.
  _apolloFederationStatus
  sources
  perPairParsers
  perRolePairContexts
  allRemoteSchemas
  allActions
  customTypes
  mSchemaRegistryContext
  logger = do
    let remoteSchemasRoles = concatMap (HashMap.keys . _rscPermissions . fst . snd) $ HashMap.toList allRemoteSchemas
        actionRoles =
          Set.insert adminRoleName
            $ Set.fromList (allActionInfos ^.. folded . aiPermissions . to HashMap.keys . folded)
            <> Set.fromList (bool mempty remoteSchemasRoles $ remoteSchemaPermissions == Options.EnableRemoteSchemaPermissions)
        allActionInfos = HashMap.elems allActions
        -- All roles: from pre-computed per-pair source parsers plus action/remote-schema roles
        allRoles = actionRoles <> HashMap.keysSet perPairParsers

    -- Relay contexts are nominally deferred with 'unsafeInterleaveIO', but in
    -- practice the schema-cache build forces them on every rebuild (the deferral
    -- does not hold — see @rfcs/per-schema-gql-context.md@ §12.11). The full Relay
    -- schema spans every source/schema (its global @Node@ interface forbids
    -- per-schema caching, so it cannot be incrementally rebuilt like the Hasura
    -- schema) and costs O(total) seconds to assemble — dominating mutation latency
    -- on large metadata. It is therefore **disabled by default**: only built when a
    -- deployment opts in with the 'EFEnableRelaySchema' experimental feature.
    -- When disabled, relay requests fall back to the (empty) unauthenticated relay
    -- context. A build error surfaces as a 'RelayBuildException' when first forced.
    relayContexts <-
      if EFEnableRelaySchema `Set.member` experimentalFeatures
        then
          fmap HashMap.fromList
            $ for (Set.toList allRoles)
            $ \role -> do
              lazyCtx <-
                liftIO $ unsafeInterleaveIO $ do
                  res <-
                    runExceptT
                      $ assembleRelayRoleContext
                        (sqlGen, functionPermissions)
                        sources
                        allActionInfos
                        customTypes
                        role
                        experimentalFeatures
                        sampledFeatureFlags
                  either (E.throwIO . RelayBuildException) pure res
              pure (role, lazyCtx)
        else pure mempty

    -- The per-(role, pair) 'RoleContext' map.
    let contexts :: HashMap RoleName (HashMap (SourceName, SchemaName) (RoleContext GQLContext))
        contexts = fmap (fmap (view _1)) perRolePairContexts

        -- All assembly inconsistencies, collected across every (role, pair).
        assemblyErrors :: HashSet InconsistentMetadata
        assemblyErrors =
          Set.unions
            $ concatMap (fmap (view _2) . HashMap.elems)
            $ HashMap.elems perRolePairContexts

    -- The admin role's per-pair results: required for the global admin
    -- introspection (allowlist / query-collection validation, schema registry).
    adminPairResults <-
      case HashMap.lookup adminRoleName perRolePairContexts of
        Just r -> pure r
        Nothing -> throw500 "buildGQLContext failed to build for the admin role"
    let adminIntrospection = mergeSchemaIntrospections $ view _3 <$> HashMap.elems adminPairResults

    -- The unauthenticated context, per pair. Admin-only deployment (locked
    -- decision 5): the unauthenticated universe equals the admin frontend
    -- schema. It is only consulted for internal conflict introspection;
    -- unauthenticated GraphQL access is gated upstream.
    let unauthenticated :: HashMap (SourceName, SchemaName) GQLContext
        unauthenticated = _rctxDefault <$> HashMap.findWithDefault mempty adminRoleName contexts

    -- Routing index: top-level root-field name -> owning (source, schema). Built
    -- from the admin role's parsers (the superset of visible root fields). A name
    -- mapping to two different pairs is a naming-convention misconfiguration and
    -- is surfaced as an inconsistency.
    let adminPairParsers = HashMap.findWithDefault mempty adminRoleName perPairParsers
        (rootFieldSchema, routingConflicts) = buildRootFieldIndex adminPairParsers

    -- A single global unauthenticated context is required only by the (dormant)
    -- Relay transport slot. Building it spans every source (it is NOT split per
    -- pair), so it would re-run on every schema rebuild and defeat the
    -- per-(source, schema) incremental win (§5.3). Defer it with
    -- 'unsafeInterleaveIO' — exactly as 'relayContexts' above — so the O(total)
    -- unauthenticated build only happens if the dormant Relay slot is ever
    -- forced. With no remote schemas its error set is empty, so nothing needs to
    -- be surfaced eagerly into 'assemblyErrors'.
    relayUnauthenticated <-
      liftIO $ unsafeInterleaveIO $ do
        res <-
          runExceptT
            $ unauthenticatedContext (sqlGen, functionPermissions) sources allRemoteSchemas experimentalFeatures sampledFeatureFlags remoteSchemaPermissions
        either (E.throwIO . RelayBuildException) (pure . fst) res

    -- Per-role merged introspection for the schema registry.
    let perRoleIntrospection :: HashMap RoleName G.SchemaIntrospection
        perRoleIntrospection =
          fmap (mergeSchemaIntrospections . fmap (view _3) . HashMap.elems) perRolePairContexts

    writeToSchemaRegistryAction <-
      forM mSchemaRegistryContext $ \schemaRegistryCtx -> do
        -- NOTE!: Where this code path is reached it's absolutely crucial that
        -- we have a thread reading, otherwise we have an unbounded space leak
        res <- liftIO $ runExceptT $ PG.runTx' (_srpaMetadataDbPoolRef schemaRegistryCtx) selectNowQuery
        case res of
          Left err ->
            pure $ \_ _ _ ->
              unLogger logger $ mkGenericLog @Text LevelWarn "schema-registry" ("Failed to fetch the time from metadata db correctly: " <> showQErr err)
          Right now -> do
            let schemaRegistryMap = generateSchemaRegistryMap perRoleIntrospection
                projectSchemaInfo = \metadataResourceVersion inconsistentMetadata metadata ->
                  ProjectGQLSchemaInformation
                    schemaRegistryMap
                    (IsMetadataInconsistent $ checkMdErrs inconsistentMetadata)
                    (calculateSchemaSDLHash (generateSDL adminIntrospection) adminRoleName)
                    metadataResourceVersion
                    now
                    metadata
            pure
              $ \metadataResourceVersion inconsistentMetadata metadata ->
                STM.atomically
                  $ STM.writeTQueue (_srpaSchemaRegistryTQueueRef schemaRegistryCtx)
                  -- NOTE!: this is a rare case where we'd like this to be a thunk
                  -- because it is significant work we can avoid entirely in
                  -- EE, where this queue is just drained and items discarded
                  $ projectSchemaInfo metadataResourceVersion inconsistentMetadata metadata

    pure
      ( ( adminIntrospection,
          contexts,
          unauthenticated,
          rootFieldSchema,
          assemblyErrors <> Set.fromList routingConflicts
        ),
        ( relayContexts,
          -- Currently, remote schemas are exposed through Relay, but ONLY through
          -- the unauthenticated role.  This is probably an oversight.  See
          -- hasura/graphql-engine-mono#3883.
          relayUnauthenticated
        ),
        writeToSchemaRegistryAction
      )
    where
      checkMdErrs = not . null

      generateSchemaRegistryMap :: HashMap RoleName G.SchemaIntrospection -> SchemaRegistryMap
      generateSchemaRegistryMap mpr =
        flip HashMap.mapWithKey mpr $ \r schemaIntrospection ->
          let schemaSdl = generateSDL schemaIntrospection
           in (GQLSchemaInformation (SchemaSDL schemaSdl) (calculateSchemaSDLHash schemaSdl r))

      -- Union the per-pair introspection universes into one global universe.
      mergeSchemaIntrospections :: [G.SchemaIntrospection] -> G.SchemaIntrospection
      mergeSchemaIntrospections =
        G.SchemaIntrospection . HashMap.unions . fmap (\(G.SchemaIntrospection m) -> m)

      -- Build the rootField -> (source, schema) routing index from one role's
      -- per-pair parsers, surfacing any name claimed by two different pairs as
      -- an inconsistency (a naming-convention misconfiguration, see §4).
      buildRootFieldIndex ::
        HashMap (SourceName, SchemaName) SchemaFieldParsers ->
        (HashMap G.Name (SourceName, SchemaName), [InconsistentMetadata])
      buildRootFieldIndex pairParsers =
        foldl' insertName (mempty, []) entries
        where
          entries =
            [ (name, pair)
              | (pair, parsers) <- HashMap.toList pairParsers,
                name <- pairRootFieldNames parsers
            ]
          insertName (idx, conflicts) (name, pair) =
            case HashMap.lookup name idx of
              Just existing
                | existing /= pair ->
                    (idx, routingConflict name existing pair : conflicts)
              _ -> (HashMap.insert name pair idx, conflicts)

      pairRootFieldNames :: SchemaFieldParsers -> [G.Name]
      pairRootFieldNames SchemaFieldParsers {..} =
        fmap (P.dName . P.fDefinition) _sfpQuery
          <> fmap (P.dName . P.fDefinition) _sfpMutFrontend
          <> fmap (P.dName . P.fDefinition) _sfpMutBackend
          <> fmap (P.dName . P.fDefinition) _sfpSubscription

      routingConflict :: G.Name -> (SourceName, SchemaName) -> (SourceName, SchemaName) -> InconsistentMetadata
      routingConflict name (srcA, schA) (srcB, schB) =
        InconsistentObject
          ( "root field "
              <> toTxt name
              <> " is generated by multiple (source, schema) pairs: ("
              <> toTxt srcA
              <> ", "
              <> getSchemaTxt schA
              <> ") and ("
              <> toTxt srcB
              <> ", "
              <> getSchemaTxt schB
              <> "); type/root-field naming must uniquely encode (source, schema)"
          )
          Nothing
          (MetadataObject (MOSource srcB) (J.toJSON name))

buildSchemaOptions ::
  (SQLGenCtx, Options.InferFunctionPermissions) ->
  HashSet ExperimentalFeature ->
  SchemaOptions
buildSchemaOptions
  ( SQLGenCtx stringifyNum dangerousBooleanCollapse _nullInNonNullableVariables noNullUnboundVariableDefault removeEmptySubscriptionResponses remoteNullForwardingPolicy optimizePermissionFilters bigqueryStringNumericInput,
    functionPermsCtx
    )
  expFeatures =
    SchemaOptions
      { soStringifyNumbers = stringifyNum,
        soDangerousBooleanCollapse = dangerousBooleanCollapse,
        soRemoteNullForwardingPolicy = remoteNullForwardingPolicy,
        soInferFunctionPermissions = functionPermsCtx,
        soOptimizePermissionFilters = optimizePermissionFilters,
        soIncludeUpdateManyFields =
          if EFHideUpdateManyFields `Set.member` expFeatures
            then Options.Don'tIncludeUpdateManyFields
            else Options.IncludeUpdateManyFields,
        soIncludeAggregationPredicates =
          if EFHideAggregationPredicates `Set.member` expFeatures
            then Options.Don'tIncludeAggregationPredicates
            else Options.IncludeAggregationPredicates,
        soIncludeStreamFields =
          if EFHideStreamFields `Set.member` expFeatures
            then Options.Don'tIncludeStreamFields
            else Options.IncludeStreamFields,
        soBigQueryStringNumericInput = bigqueryStringNumericInput,
        soIncludeGroupByAggregateFields =
          if EFGroupByAggregations `Set.member` expFeatures
            then Options.IncludeGroupByAggregateFields
            else Options.ExcludeGroupByAggregateFields,
        soPostgresArrays =
          if EFDisablePostgresArrays `Set.member` expFeatures
            then Options.DontUsePostgresArrays
            else Options.UsePostgresArrays,
        soNoNullUnboundVariableDefault =
          noNullUnboundVariableDefault,
        soRemoveEmptySubscriptionResponses =
          removeEmptySubscriptionResponses
      }

-- | Assemble the per-role GQL context from pre-computed source parsers plus
-- actions, remote schemas, and introspection.  Extracted from 'buildRoleContext'
-- so the source-parser computation can be lifted out of the assembly loop.
assembleGQLContext ::
  forall m.
  (MonadError QErr m, MonadIO m) =>
  SchemaSampledFeatureFlags ->
  (SQLGenCtx, Options.InferFunctionPermissions) ->
  SourceCache ->
  HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject) ->
  [ActionInfo] ->
  AnnotatedCustomTypes ->
  RoleName ->
  Options.RemoteSchemaPermissions ->
  Set.HashSet ExperimentalFeature ->
  ApolloFederationStatus ->
  Maybe SchemaRegistryContext ->
  SchemaFieldParsers ->
  m RoleContextValue
assembleGQLContext sampledFeatureFlags options sources remotes actions customTypes role remoteSchemaPermsCtx expFeatures apolloFederationStatus mSchemaRegistryContext sourceParsers = do
  let schemaOptions = buildSchemaOptions options expFeatures
      schemaContext =
        SchemaContext
          HasuraSchema
          ( remoteRelationshipField
              schemaContext
              schemaOptions
              sources
              (fst <$> remotes)
              remoteSchemaPermsCtx
              IncludeRemoteSourceRelationship
          )
          role
          sampledFeatureFlags
      -- Unpack the pre-computed source parsers
      sourcesQueryFields = _sfpQuery sourceParsers
      sourcesMutationFrontendFields = _sfpMutFrontend sourceParsers
      sourcesMutationBackendFields = _sfpMutBackend sourceParsers
      sourcesSubscriptionFields = _sfpSubscription sourceParsers
      apolloFedTableParsers = _sfpApolloFed sourceParsers
  runMemoizeT $ do
    -- build all actions
    -- we use the source context due to how async query relationships are implemented
    (actionsQueryFields, actionsMutationFields, actionsSubscriptionFields) <-
      runActionSchema schemaContext schemaOptions
        $ fmap mconcat
        $ for actions \action -> do
          queryFields <- buildActionQueryFields customTypes action
          mutationFields <- buildActionMutationFields customTypes action
          subscriptionFields <- buildActionSubscriptionFields customTypes action
          pure (queryFields, mutationFields, subscriptionFields)

    -- build all remote schemas
    -- we only keep the ones that don't result in a name conflict
    (remoteSchemaFields, !remoteSchemaErrors) <-
      runRemoteSchema schemaContext (soRemoteNullForwardingPolicy schemaOptions)
        $ buildAndValidateRemoteSchemas remotes sourcesQueryFields sourcesMutationBackendFields actionsQueryFields actionsMutationFields role remoteSchemaPermsCtx
    let remotesQueryFields = concatMap (\(n, rf) -> (n,) <$> piQuery rf) remoteSchemaFields
        remotesMutationFields = concat $ mapMaybe (\(n, rf) -> fmap (n,) <$> piMutation rf) remoteSchemaFields
        remotesSubscriptionFields = concat $ mapMaybe (\(n, rf) -> fmap (n,) <$> piSubscription rf) remoteSchemaFields
        apolloQueryFields = apolloRootFields apolloFederationStatus apolloFedTableParsers

    mutationParserFrontend <-
      buildMutationParser sourcesMutationFrontendFields remotesMutationFields actionsMutationFields
    mutationParserBackend <-
      buildMutationParser sourcesMutationBackendFields remotesMutationFields actionsMutationFields
    subscriptionParser <-
      buildSubscriptionParser sourcesSubscriptionFields remotesSubscriptionFields actionsSubscriptionFields
    queryParserFrontend <-
      buildQueryParser sourcesQueryFields apolloQueryFields remotesQueryFields actionsQueryFields mutationParserFrontend subscriptionParser
    queryParserBackend <-
      buildQueryParser sourcesQueryFields apolloQueryFields remotesQueryFields actionsQueryFields mutationParserBackend subscriptionParser

    -- In order to catch errors early, we attempt to generate the data
    -- required for introspection, which ends up doing a few correctness
    -- checks in the GraphQL schema. Furthermore, we want to persist this
    -- information in the case of the admin role.
    !introspectionSchema <- do
      result <-
        throwOnConflictingDefinitions
          $ convertToSchemaIntrospection
          <$> buildIntrospectionSchema
            (P.parserType queryParserBackend)
            (P.parserType <$> mutationParserBackend)
            (P.parserType <$> subscriptionParser)
      pure
        $
        -- TODO(nicuveo,sam): we treat the admin role differently in this function,
        -- which is a bit inelegant; we might want to refactor this function and
        -- split it into several steps, so that we can make a separate function for
        -- the admin role that reuses the common parts and avoid such tests.
        -- There's also the involvement of the Schema Registry feature in this step
        -- which makes it furthermore inelegant
        case mSchemaRegistryContext of
          Nothing ->
            if role == adminRoleName
              then result
              else G.SchemaIntrospection mempty
          Just _ -> result

    -- We deliberately do NOT run a second conflicting-definitions check on the
    -- frontend schema: the backend check above already subsumes it. The frontend
    -- schema is a strict subset of the backend one. Every Scenario guard in
    -- Hasura.GraphQL.Schema.* has the shape "not (scenario == Frontend and
    -- backendOnly)", so Frontend only ever removes backend_only mutation fields;
    -- nothing is frontend-only and the query/subscription roots are identical.
    -- Hence every type reachable from the frontend roots is reachable from the
    -- backend roots with the same definition, and a name conflict could not arise
    -- in the frontend without also arising in the backend (a subset of a
    -- conflict-free type set is conflict-free). Re-collecting the whole type
    -- universe a second time measured ~56ms/build on a ~600-table schema (~44% of
    -- per-pair context assembly) for a check that can never fire independently.

    -- (since we're running this in parallel in caller, be strict)
    let !frontendContext =
          GQLContext
            (finalizeParser queryParserFrontend)
            (finalizeParser <$> mutationParserFrontend)
            (finalizeParser <$> subscriptionParser)
        !backendContext =
          GQLContext
            (finalizeParser queryParserBackend)
            (finalizeParser <$> mutationParserBackend)
            (finalizeParser <$> subscriptionParser)

    pure
      ( RoleContext frontendContext $ Just backendContext,
        remoteSchemaErrors,
        introspectionSchema
      )

-- | Assemble every role's 'GQLContext' for a single @(source, schema)@ pair from
-- that pair's per-role field parsers (§5.3). This is the expensive,
-- introspection-heavy step ('assembleGQLContext' per role); running it here —
-- inside the per-(source, schema) 'Inc.cache' node — is what makes a mutation to
-- one pair re-assemble only that pair. With locked decisions (1) actions /
-- remote schemas / custom types are empty and (3) each pair is self-contained,
-- so the action/remote/custom-type inputs are passed empty.
assemblePerPairContexts ::
  forall m.
  (MonadError QErr m, MonadIO m) =>
  SchemaSampledFeatureFlags ->
  (SQLGenCtx, Options.InferFunctionPermissions) ->
  SourceCache ->
  Options.RemoteSchemaPermissions ->
  Set.HashSet ExperimentalFeature ->
  ApolloFederationStatus ->
  Maybe SchemaRegistryContext ->
  HashMap RoleName SchemaFieldParsers ->
  m (HashMap RoleName RoleContextValue)
assemblePerPairContexts sampledFeatureFlags options sources remoteSchemaPermsCtx expFeatures apolloFederationStatus mSchemaRegistryContext roleParsers =
  fmap HashMap.fromList
    $ for (HashMap.toList roleParsers)
    $ \(role, parsers) ->
      (role,)
        <$> assembleGQLContext
          sampledFeatureFlags
          options
          sources
          mempty
          []
          mempty
          role
          remoteSchemaPermsCtx
          expFeatures
          apolloFederationStatus
          mSchemaRegistryContext
          parsers

-- | Partition a 'SourceInfo b' into per-DB-schema slices so that each slice
-- can be fed independently into 'buildSchemaRoleParsers'.  Tables and functions
-- are assigned to their own schema; native queries (no schema component) are
-- assigned only to the first schema alphabetically.
partitionSourceBySchema ::
  forall b.
  (BackendMetadata b) =>
  SourceInfo b ->
  HashMap SchemaName (SourceInfo b)
partitionSourceBySchema si@SourceInfo {..} =
  HashMap.mapWithKey buildSlice allSchemas
  where
    tableSchemas =
      HashMap.fromListWith (\_ x -> x)
        [(tableNameSchema @b tn, ()) | tn <- HashMap.keys _siTables]
    functionSchemas =
      HashMap.fromListWith (\_ x -> x)
        [(functionNameSchema @b fn, ()) | fn <- HashMap.keys _siFunctions]
    storedProcSchemas =
      HashMap.fromListWith (\_ x -> x)
        [(functionNameSchema @b fn, ()) | fn <- HashMap.keys _siStoredProcedures]
    allSchemas = tableSchemas <> functionSchemas <> storedProcSchemas

    -- Native queries have no schema component; assign them to the first schema.
    firstSchema = listToMaybe $ sort $ HashMap.keys allSchemas

    buildSlice schemaName _ =
      si
        { _siTables =
            HashMap.filterWithKey (\tn _ -> tableNameSchema @b tn == schemaName) _siTables,
          _siFunctions =
            HashMap.filterWithKey (\fn _ -> functionNameSchema @b fn == schemaName) _siFunctions,
          _siStoredProcedures =
            HashMap.filterWithKey (\fn _ -> functionNameSchema @b fn == schemaName) _siStoredProcedures,
          -- Native queries go to the first schema only; empty for all others.
          _siNativeQueries =
            if Just schemaName == firstSchema then _siNativeQueries else mempty,
          -- Logical models are referenced by name only; include in all slices.
          _siLogicalModels = _siLogicalModels
        }

-- | Build 'SchemaFieldParsers' for a single role using a schema-partitioned
-- 'SourceInfo b'.  Analogous to the local @buildSource@ in 'buildRoleContext'
-- but returns the structured 'SchemaFieldParsers' rather than a raw 5-tuple.
buildSchemaRoleParsers ::
  forall b m.
  (BackendSchema b, MonadError QErr m, MonadIO m) =>
  -- | Phase 9 per-table field cache; 'noTableFieldsCache' rebuilds everything.
  TableFieldsCacher b ->
  -- | Hasura schema context (HasuraSchema kind, remote relationships enabled)
  SchemaContext ->
  SchemaOptions ->
  SourceInfo b ->
  MemoizeT m SchemaFieldParsers
buildSchemaRoleParsers cacher hasuraSchemaContext schemaOptions sourceInfo@(SourceInfo {..}) =
  runSourceSchema hasuraSchemaContext schemaOptions sourceInfo do
    let validFunctions = takeValidFunctions _siFunctions
        validNativeQueries = takeValidNativeQueries _siNativeQueries
        validStoredProcedures = takeValidStoredProcedures _siStoredProcedures
        validTables = takeValidTables _siTables
        mkRootFieldName = _rscRootFields _siCustomization
        makeTypename = SC._rscTypeNames _siCustomization
    (uncustomizedQueryFs, uncustomizedSubFs, apolloFed) <-
      buildQueryAndSubscriptionFields cacher mkRootFieldName sourceInfo validTables validFunctions validNativeQueries validStoredProcedures
    qFs <-
      customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__query))
        (pure uncustomizedQueryFs)
    mutFE <-
      customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__mutation_frontend))
        (buildMutationFields cacher mkRootFieldName Frontend sourceInfo validTables validFunctions)
    mutBE <-
      customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__mutation_backend))
        (buildMutationFields cacher mkRootFieldName Backend sourceInfo validTables validFunctions)
    sFs <-
      customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__subscription))
        (pure uncustomizedSubFs)
    pure
      SchemaFieldParsers
        { _sfpQuery = qFs,
          _sfpMutFrontend = mutFE,
          _sfpMutBackend = mutBE,
          _sfpSubscription = sFs,
          _sfpApolloFed = apolloFed
        }

-- | Build the Relay per-source field parsers for a single schema partition.
--
-- This is exactly the local @buildSource@ helper that used to live inside
-- 'buildRelayRoleContext', scoped to one DB schema so it is memoised per
-- (source, DB schema). It MUST be run in its own 'runMemoizeT', separate from
-- 'buildSchemaRoleParsers': 'defaultTableSelectionSet' memoises on
-- @(sourceName, tableName)@ only (not on the schema kind), so sharing a memo
-- table with the Hasura build would make the Relay connection's @edges.node@
-- reuse the Hasura (non-@Node@) selection set, producing conflicting
-- definitions against the top-level @node@ field. The top-level @node@ field /
-- @Node@ interface are NOT built here (they are cross-schema); they are added
-- once per role in 'assembleRelayRoleContext'.
buildSchemaRelayParsers ::
  forall b m.
  (BackendSchema b, MonadError QErr m, MonadIO m) =>
  -- | Relay schema context (RelaySchema kind, remote relationships ignored)
  SchemaContext ->
  SchemaOptions ->
  SourceInfo b ->
  MemoizeT
    m
    ( [FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))],
      [FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))],
      [FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))],
      [FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))]
    )
buildSchemaRelayParsers relaySchemaContext schemaOptions sourceInfo@(SourceInfo {..}) =
  runSourceSchema relaySchemaContext schemaOptions sourceInfo do
    let validFunctions = takeValidFunctions _siFunctions
        validTables = takeValidTables _siTables
        mkRootFieldName = _rscRootFields _siCustomization
        makeTypename = SC._rscTypeNames _siCustomization
    (uncustomizedRelayQueryFs, uncustomizedRelaySubFs) <-
      buildRelayQueryAndSubscriptionFields mkRootFieldName sourceInfo validTables validFunctions
    (,,,)
      <$> customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__query))
        (pure uncustomizedRelayQueryFs)
      <*> customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__mutation_frontend))
        (buildMutationFields noTableFieldsCache mkRootFieldName Frontend sourceInfo validTables validFunctions)
      <*> customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__mutation_backend))
        (buildMutationFields noTableFieldsCache mkRootFieldName Backend sourceInfo validTables validFunctions)
      <*> customizeFields
        _siCustomization
        (makeTypename <> MkTypename (<> Name.__subscription))
        (pure uncustomizedRelaySubFs)

-- | Build per-role 'SchemaFieldParsers' for all roles using a single
-- schema-partitioned 'SourceInfo b'.  Builds a fresh 'SchemaContext' for each
-- role so that permission checks are applied correctly.
buildAllRoleParsersForSchema ::
  forall b m.
  (BackendSchema b, MonadError QErr m, MonadIO m) =>
  -- | Per-table field caches, or 'Nothing' to rebuild every table unconditionally.
  -- Populated by default; 'Nothing' is the 'EFDisablePerTableSchemaCache' escape
  -- hatch and the pre-Phase-9 behaviour.
  Maybe TableFieldStore ->
  -- | The DB schema this partition covers; part of the cache's key.
  SchemaName ->
  -- | Per-table content fingerprints, computed once by the caller and shared with
  -- the 'Inc.cache' key that gates this build (§10.2). These decide which tables
  -- changed; 'tableDependencyGraph' expands that into the set to rebuild.
  HashMap (TableName b) J.Value ->
  SchemaSampledFeatureFlags ->
  SchemaOptions ->
  SourceCache ->
  HashMap RemoteSchemaName RemoteSchemaCtx ->
  Options.RemoteSchemaPermissions ->
  [RoleName] ->
  SourceInfo b ->
  m (HashMap RoleName SchemaFieldParsers)
buildAllRoleParsersForSchema mTableFieldStore schemaName tableFingerprints sampledFeatureFlags schemaOptions sources remotes remoteSchemaPermsCtx roles filteredSi = do
  let dependencyGraph = tableDependencyGraph @b (_siTables filteredSi)
  fmap HashMap.fromList $ for roles $ \role -> do
    let hasuraSchemaContext =
          SchemaContext
            HasuraSchema
            ( remoteRelationshipField
                hasuraSchemaContext
                schemaOptions
                sources
                remotes
                remoteSchemaPermsCtx
                IncludeRemoteSourceRelationship
            )
            role
            sampledFeatureFlags
    -- Only the Hasura query/mutation/subscription parsers are schema-partitioned
    -- and cached here. The Relay schema is built separately, once per role, in
    -- 'assembleRelayRoleContext' (see the note on 'SchemaFieldParsers'): its
    -- global 'Node' interface cannot be split across per-schema memoize tables
    -- without producing conflicting type definitions.
    -- Phase 9: with a store, an unchanged table's builders are never called; the
    -- cache is consulted above them, so there is no key to compute and no memo
    -- table to probe. 'Nothing' rebuilds every table (the default).
    cacher <- case mTableFieldStore of
      Nothing -> pure noTableFieldsCache
      Just store -> do
        let pairKey = (_siName filteredSi, schemaName, role)
        -- MUST precede any withTableFields call for this pair: it is what drops the
        -- entries a change invalidated.
        _stats <- prepareForBuild @b store pairKey dependencyGraph tableFingerprints
        pure $ mkTableFieldsCacher @b store pairKey
    hasuraParsers <- runMemoizeT $ buildSchemaRoleParsers cacher hasuraSchemaContext schemaOptions filteredSi
    pure (role, hasuraParsers)

-- | Assemble the per-role Relay 'RoleContext'.
--
-- Unlike the Hasura schema (which is built per (source, DB schema) and cached
-- in 'buildSchemaRoleParsers'), the Relay schema is built here in full, once per
-- role, in a SINGLE 'runMemoizeT'. This is mandatory: the Relay @Node@ interface
-- (and @PageInfo@ etc.) is a single global type whose '_ifObjects' spans every
-- relay-enabled table across all sources/schemas. Building the per-source/-schema
-- connection types in separate memoize tables would mint divergent @Node@
-- definitions and fail with "conflicting definitions for GraphQL type 'Node'".
-- The per-source Relay fields are built by 'buildSchemaRelayParsers' over the
-- full 'SourceCache' inside the same memoize pass as 'nodeField'/'nodeInterface'.
assembleRelayRoleContext ::
  forall m.
  (MonadError QErr m, MonadIO m) =>
  (SQLGenCtx, Options.InferFunctionPermissions) ->
  SourceCache ->
  [ActionInfo] ->
  AnnotatedCustomTypes ->
  RoleName ->
  Set.HashSet ExperimentalFeature ->
  SchemaSampledFeatureFlags ->
  m (RoleContext GQLContext)
assembleRelayRoleContext options sources actions customTypes role expFeatures schemaSampledFeatureFlags = do
  let schemaOptions = buildSchemaOptions options expFeatures
      -- TODO: At the time of writing this, remote schema queries are not supported in relay.
      -- When they are supported, we should get do what `buildRoleContext` does. Since, they
      -- are not supported yet, we use `mempty` below for `RemoteSchemaMap`.
      schemaContext =
        SchemaContext
          (RelaySchema $ nodeInterface sources)
          -- Remote relationships aren't currently supported in Relay, due to type conflicts, and
          -- introspection issues such as https://github.com/hasura/graphql-engine/issues/5144.
          ignoreRemoteRelationship
          role
          schemaSampledFeatureFlags
  runMemoizeT do
    -- Build the global @node@ root AND every source's Relay fields in this single
    -- memoize table, so the cross-schema @Node@ interface is constructed exactly once.
    node <- fmap NotNamespaced <$> nodeField sources schemaContext schemaOptions
    fieldsList <-
      for (toList sources) \exists ->
        AB.dispatchAnyBackend @BackendSchema exists (buildSchemaRelayParsers schemaContext schemaOptions)
    let (queryFields, mutationFrontendFields, mutationBackendFields, subscriptionFields) = mconcat fieldsList
        allQueryFields = node : queryFields
        allSubscriptionFields = node : subscriptionFields

    -- build all actions
    -- we only build mutations in the relay schema
    actionsMutationFields <-
      runActionSchema schemaContext schemaOptions
        $ fmap concat
        $ traverse (buildActionMutationFields customTypes) actions

    -- Remote schema mutations aren't exposed in relay because many times it throws
    -- the conflicting definitions error between the relay types like `Node`, `PageInfo` etc
    mutationParserFrontend <-
      buildMutationParser mutationFrontendFields mempty actionsMutationFields
    mutationParserBackend <-
      buildMutationParser mutationBackendFields mempty actionsMutationFields
    subscriptionParser <-
      buildSubscriptionParser allSubscriptionFields [] []
    queryParserFrontend <-
      queryWithIntrospectionHelper allQueryFields mutationParserFrontend subscriptionParser
    queryParserBackend <-
      queryWithIntrospectionHelper allQueryFields mutationParserBackend subscriptionParser

    -- In order to catch errors early, we attempt to generate the data
    -- required for introspection, which ends up doing a few correctness
    -- checks in the GraphQL schema.
    void
      . throwOnConflictingDefinitions
      $ buildIntrospectionSchema
        (P.parserType queryParserBackend)
        (P.parserType <$> mutationParserBackend)
        (P.parserType <$> subscriptionParser)
    void
      . throwOnConflictingDefinitions
      $ buildIntrospectionSchema
        (P.parserType queryParserFrontend)
        (P.parserType <$> mutationParserFrontend)
        (P.parserType <$> subscriptionParser)

    let frontendContext =
          GQLContext
            (finalizeParser queryParserFrontend)
            (finalizeParser <$> mutationParserFrontend)
            (finalizeParser <$> subscriptionParser)
        backendContext =
          GQLContext
            (finalizeParser queryParserBackend)
            (finalizeParser <$> mutationParserBackend)
            (finalizeParser <$> subscriptionParser)

    pure $ RoleContext frontendContext $ Just backendContext

-- | Builds the schema context for unauthenticated users.
--
-- This context is used whenever the user queries the engine with a role that is
-- unknown, and therefore not present in the context map. Before remote schema
-- permissions were introduced, remotes were considered to be a public entity,
-- and we therefore allowed an unknown role also to query the remotes. To
-- maintain backwards compatibility, we check if remote schema permissions are
-- enabled; remote schemas will only be available to unauthenticated users if
-- permissions aren't enabled.
unauthenticatedContext ::
  forall m.
  ( MonadError QErr m,
    MonadIO m
  ) =>
  (SQLGenCtx, Options.InferFunctionPermissions) ->
  SourceCache ->
  HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject) ->
  Set.HashSet ExperimentalFeature ->
  SchemaSampledFeatureFlags ->
  Options.RemoteSchemaPermissions ->
  m (GQLContext, HashSet InconsistentMetadata)
unauthenticatedContext options sources allRemotes expFeatures schemaSampledFeatureFlags remoteSchemaPermsCtx = do
  let schemaOptions = buildSchemaOptions options expFeatures
      fakeSchemaContext =
        SchemaContext
          HasuraSchema
          ( remoteRelationshipField
              fakeSchemaContext
              schemaOptions
              sources
              (fst <$> allRemotes)
              remoteSchemaPermsCtx
              -- A remote schema is available in an unauthenticated context when the
              -- remote schema permissions are disabled but sources are by default
              -- not accessible to the unauthenticated context. Therefore,
              -- the remote source relationship building is skipped.
              ExcludeRemoteSourceRelationship
          )
          fakeRole
          schemaSampledFeatureFlags
      -- chosen arbitrarily to be as improbable as possible
      fakeRole = mkRoleNameSafe [NT.nonEmptyTextQQ|MyNameIsOzymandiasKingOfKingsLookOnMyWorksYeMightyAndDespair|]

  runMemoizeT do
    (queryFields, mutationFields, subscriptionFields, remoteErrors) <- case remoteSchemaPermsCtx of
      Options.EnableRemoteSchemaPermissions ->
        -- Permissions are enabled, unauthenticated users have access to nothing.
        pure ([], [], [], mempty)
      Options.DisableRemoteSchemaPermissions -> do
        -- Permissions are disabled, unauthenticated users have access to remote schemas.
        (remoteFields, remoteSchemaErrors) <-
          runRemoteSchema fakeSchemaContext (soRemoteNullForwardingPolicy schemaOptions)
            $ buildAndValidateRemoteSchemas allRemotes [] [] [] [] fakeRole remoteSchemaPermsCtx
        pure
          ( (\(n, rf) -> fmap (fmap (RFRemote n)) rf) <$> concatMap (\(n, q) -> (n,) <$> piQuery q) remoteFields,
            (\(n, rf) -> fmap (fmap (RFRemote n)) rf) <$> concat (mapMaybe (\(n, q) -> fmap (n,) <$> piMutation q) remoteFields),
            (\(n, rf) -> fmap (fmap (RFRemote n)) rf) <$> concat (mapMaybe (\(n, q) -> fmap (n,) <$> piSubscription q) remoteFields),
            remoteSchemaErrors
          )
    mutationParser <-
      whenMaybe (not $ null mutationFields)
        $ safeSelectionSet mutationRoot (Just $ G.Description "mutation root") mutationFields
        <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)
    subscriptionParser <-
      whenMaybe (not $ null subscriptionFields)
        $ safeSelectionSet subscriptionRoot (Just $ G.Description "subscription root") subscriptionFields
        <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)
    queryParser <- queryWithIntrospectionHelper queryFields mutationParser Nothing
    void
      . throwOnConflictingDefinitions
      $ buildIntrospectionSchema
        (P.parserType queryParser)
        (P.parserType <$> mutationParser)
        (P.parserType <$> subscriptionParser)
    pure (GQLContext (finalizeParser queryParser) (finalizeParser <$> mutationParser) (finalizeParser <$> subscriptionParser), remoteErrors)

-------------------------------------------------------------------------------
-- Building parser fields

buildAndValidateRemoteSchemas ::
  forall m.
  ( MonadError QErr m,
    MonadIO m
  ) =>
  HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject) ->
  [FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))] -> -- Sources query fields
  [FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))] -> -- Sources mutation fields
  [FieldParser P.Parse (QueryRootField UnpreparedValue)] -> -- Action query fields
  [FieldParser P.Parse (MutationRootField UnpreparedValue)] -> -- Action mutation fields
  RoleName ->
  Options.RemoteSchemaPermissions ->
  SchemaT
    ( SchemaContext,
      Options.RemoteNullForwardingPolicy,
      MkTypename,
      CustomizeRemoteFieldName
    )
    (MemoizeT m)
    ([(RemoteSchemaName, RemoteSchemaParser P.Parse)], HashSet InconsistentMetadata)
buildAndValidateRemoteSchemas remotes sourcesQueryFields sourcesMutationFields actionQueryFields actionMutationFields role remoteSchemaPermsCtx =
  runWriterT $ foldlM step [] (HashMap.elems remotes)
  where
    getFieldName = P.getName . P.fDefinition

    sourcesQueryFieldNames = getFieldName <$> sourcesQueryFields
    sourcesMutationFieldNames = getFieldName <$> sourcesMutationFields

    step validatedSchemas (remoteSchemaContext, metadataId) = do
      let previousSchemasQueryFieldNames = map getFieldName $ concatMap (piQuery . snd) validatedSchemas
          previousSchemasMutationFieldNames = map getFieldName $ concat $ mapMaybe (piMutation . snd) validatedSchemas
          reportInconsistency reason = tell $ Set.singleton $ InconsistentObject reason Nothing metadataId
      maybeParser <- lift $ buildRemoteSchemaParser remoteSchemaPermsCtx role remoteSchemaContext
      case maybeParser of
        Nothing -> pure validatedSchemas
        Just remoteSchemaParser -> do
          (_, inconsistencies) <- listen $ do
            let newSchemaQueryFieldNames = map getFieldName $ piQuery remoteSchemaParser
                newSchemaMutationFieldNames = foldMap (map getFieldName) $ piMutation remoteSchemaParser
            -- First we check for conflicts in query_root:
            --   - between this remote and the previous ones:
            for_
              (duplicates $ newSchemaQueryFieldNames <> previousSchemasQueryFieldNames)
              \name -> reportInconsistency $ "Duplicate remote field " <> squote name
            --   - between this remote and the sources:
            for_ (duplicates $ newSchemaQueryFieldNames <> sourcesQueryFieldNames)
              $ \name -> reportInconsistency $ "Field cannot be overwritten by remote field " <> squote name
            -- Ditto, but for mutations - i.e. with mutation_root:
            unless (null newSchemaMutationFieldNames) do
              --   - between this remote and the previous ones:
              for_ (duplicates $ newSchemaMutationFieldNames <> previousSchemasMutationFieldNames)
                $ \name -> reportInconsistency $ "Duplicate remote field " <> squote name
              --   - between this remote and the sources:
              for_ (duplicates $ newSchemaMutationFieldNames <> sourcesMutationFieldNames)
                $ \name -> reportInconsistency $ "Field cannot be overwritten by remote field " <> squote name
            -- No need to check for conflicts between subscription fields, since
            -- remote subscriptions aren't supported yet.

            -- check for conflicting types of remote schemas with existing sources and actions schema
            let collectedTypes =
                  P.collectTypeDefinitions @MetadataObjId
                    [ -- sources and actions schema
                      P.TypeDefinitionsWrapper $ map P.fDefinition sourcesQueryFields,
                      P.TypeDefinitionsWrapper $ map P.fDefinition sourcesMutationFields,
                      P.TypeDefinitionsWrapper $ map P.fDefinition actionQueryFields,
                      P.TypeDefinitionsWrapper $ map P.fDefinition actionMutationFields,
                      -- remote schema
                      P.TypeDefinitionsWrapper $ map P.fDefinition $ piQuery remoteSchemaParser,
                      P.TypeDefinitionsWrapper $ map P.fDefinition <$> piMutation remoteSchemaParser
                    ]
            onLeft_ collectedTypes $ \conflictingTypes ->
              reportInconsistency $ "Conflicting types: " <> fromErrorMessage (toErrorValue conflictingTypes)

          -- Only add this new remote to the list if there was no error
          pure
            $ if Set.null inconsistencies
              then (_rscName remoteSchemaContext, remoteSchemaParser) : validatedSchemas
              else validatedSchemas

buildRemoteSchemaParser ::
  forall m.
  (MonadError QErr m, MonadIO m) =>
  Options.RemoteSchemaPermissions ->
  RoleName ->
  RemoteSchemaCtx ->
  SchemaT
    ( SchemaContext,
      Options.RemoteNullForwardingPolicy,
      MkTypename,
      CustomizeRemoteFieldName
    )
    (MemoizeT m)
    (Maybe (RemoteSchemaParser P.Parse))
buildRemoteSchemaParser remoteSchemaPermsCtx roleName context = do
  let maybeIntrospection = getIntrospectionResult remoteSchemaPermsCtx roleName context
  for maybeIntrospection \introspection -> do
    RemoteSchemaParser {..} <- buildRemoteParser introspection (_rscRemoteRelationships context) (_rscInfo context)
    pure $ RemoteSchemaParser (setOrigin piQuery) (setOrigin <$> piMutation) (setOrigin <$> piSubscription)
  where
    setOrigin = fmap (P.setFieldParserOrigin (MORemoteSchema (_rscName context)))

-- | `buildQueryAndSubscriptionFields` builds the query and the subscription
--   fields of the tables tracked in the source. The query root fields and
--   the subscription root fields may not be equal because a root field may be
--   enabled in the `query_root_field` and not in the `subscription_root_field`,
--   so a tuple of array of field parsers corresponding to query field parsers and
--   subscription field parsers.
buildQueryAndSubscriptionFields ::
  forall b r m n.
  (MonadBuildSchema b r m n, MonadIO m, Typeable n) =>
  -- | Phase 9: reuses an unchanged table's fields instead of rebuilding them.
  -- 'noTableFieldsCache' is the pre-Phase-9 behaviour.
  TableFieldsCacher b ->
  MkRootFieldName ->
  SourceInfo b ->
  TableCache b ->
  FunctionCache b ->
  NativeQueryCache b ->
  StoredProcedureCache b ->
  SchemaT
    r
    m
    ( [P.FieldParser n (QueryRootField UnpreparedValue)],
      [P.FieldParser n (SubscriptionRootField UnpreparedValue)],
      [(G.Name, Parser 'Output n (ApolloFederationParserFunction n))]
    )
buildQueryAndSubscriptionFields cacher mkRootFieldName sourceInfo tables (takeExposedAs FEAQuery -> functions) nativeQueries storedProcedures = do
  roleName <- retrieve scRole
  functionPermsCtx <- retrieve Options.soInferFunctionPermissions
  functionSelectExpParsers <-
    concat
      . catMaybes
      <$> for (HashMap.toList functions) \(functionName, functionInfo) -> runMaybeT $ do
        guard
          $ roleName
          == adminRoleName
          || roleName
          `HashMap.member` _fiPermissions functionInfo
          || functionPermsCtx
          == Options.InferFunctionPermissions
        let targetReturnName = _fiReturnType functionInfo
        lift $ mkRFs $ buildFunctionQueryFields mkRootFieldName functionName functionInfo targetReturnName
  nativeQueryRootFields <-
    buildNativeQueryFields sourceInfo nativeQueries

  storedProceduresRootFields <-
    buildStoredProcedureFields sourceInfo storedProcedures

  (tableQueryFields, tableSubscriptionFields, apolloFedTableParsers) <-
    unzip3
      . catMaybes
      <$> for (HashMap.toList tables) \(tableName, tableInfo) ->
        -- The cache wraps the whole per-table build, including
        -- getTableIdentifierName: the point is to skip the walk, not just its tail.
        runTableFieldsCacher cacher "query" tableName $ runMaybeT $ do
          tableIdentifierName <- getTableIdentifierName @b tableInfo
          lift $ buildTableQueryAndSubscriptionFields mkRootFieldName tableName tableInfo tableIdentifierName

  let tableQueryRootFields = fmap mkRF $ concat tableQueryFields
      tableSubscriptionRootFields = fmap mkRF $ concat tableSubscriptionFields

  pure
    ( tableQueryRootFields <> functionSelectExpParsers <> nativeQueryRootFields <> storedProceduresRootFields,
      tableSubscriptionRootFields <> functionSelectExpParsers <> nativeQueryRootFields,
      catMaybes apolloFedTableParsers
    )
  where
    mkRFs = mkRootFields sourceName sourceConfig queryTagsConfig QDBR
    mkRF = mkRootField sourceName sourceConfig queryTagsConfig QDBR
    sourceName = _siName sourceInfo
    sourceConfig = _siConfiguration sourceInfo
    queryTagsConfig = _siQueryTagsConfig sourceInfo

runMaybeTmempty :: (Monad m, Monoid a) => MaybeT m a -> m a
runMaybeTmempty = (`onNothingM` (pure mempty)) . runMaybeT

buildNativeQueryFields ::
  forall b r m n.
  (MonadBuildSchema b r m n) =>
  SourceInfo b ->
  NativeQueryCache b ->
  SchemaT r m [P.FieldParser n (QueryRootField UnpreparedValue)]
buildNativeQueryFields sourceInfo nativeQueries = runMaybeTmempty $ do
  roleName <- retrieve scRole

  map mkRF . catMaybes <$> for (HashMap.elems nativeQueries) \nativeQuery -> do
    -- only include this native query in the schema
    -- if the current role is admin, or we have a select permission
    -- for this role (this is the broad strokes check. later, we'll filter
    -- more granularly on columns and then rows)
    guard
      $ roleName
      == adminRoleName
      || roleName
      `HashMap.member` _lmiPermissions (_nqiReturns nativeQuery)

    lift (buildNativeQueryRootFields nativeQuery)
  where
    mkRF ::
      FieldParser n (QueryDB b (RemoteRelationshipField UnpreparedValue) (UnpreparedValue b)) ->
      FieldParser n (QueryRootField UnpreparedValue)
    mkRF = mkRootField sourceName sourceConfig queryTagsConfig QDBR
    sourceName = _siName sourceInfo
    sourceConfig = _siConfiguration sourceInfo
    queryTagsConfig = _siQueryTagsConfig sourceInfo

buildStoredProcedureFields ::
  forall b r m n.
  (MonadBuildSchema b r m n) =>
  SourceInfo b ->
  StoredProcedureCache b ->
  SchemaT r m [P.FieldParser n (QueryRootField UnpreparedValue)]
buildStoredProcedureFields sourceInfo storedProcedures = runMaybeTmempty $ do
  roleName <- retrieve scRole

  map mkRF . catMaybes <$> for (HashMap.elems storedProcedures) \storedProcedure -> do
    -- only include this stored procedure in the schema
    -- if the current role is admin, or we have a select permission
    -- for this role (this is the broad strokes check. later, we'll filter
    -- more granularly on columns and then rows)
    guard
      $ roleName
      == adminRoleName
      || roleName
      `HashMap.member` _lmiPermissions (_spiReturns storedProcedure)

    lift (buildStoredProcedureRootFields storedProcedure)
  where
    mkRF ::
      FieldParser n (QueryDB b (RemoteRelationshipField UnpreparedValue) (UnpreparedValue b)) ->
      FieldParser n (QueryRootField UnpreparedValue)
    mkRF = mkRootField sourceName sourceConfig queryTagsConfig QDBR
    sourceName = _siName sourceInfo
    sourceConfig = _siConfiguration sourceInfo
    queryTagsConfig = _siQueryTagsConfig sourceInfo

buildRelayQueryAndSubscriptionFields ::
  forall b r m n.
  (MonadBuildSchema b r m n) =>
  MkRootFieldName ->
  SourceInfo b ->
  TableCache b ->
  FunctionCache b ->
  SchemaT r m ([P.FieldParser n (QueryRootField UnpreparedValue)], [P.FieldParser n (SubscriptionRootField UnpreparedValue)])
buildRelayQueryAndSubscriptionFields mkRootFieldName sourceInfo tables (takeExposedAs FEAQuery -> functions) = do
  roleName <- retrieve scRole
  (tableConnectionQueryFields, tableConnectionSubscriptionFields) <-
    unzip
      . catMaybes
      <$> for (HashMap.toList tables) \(tableName, tableInfo) -> runMaybeT do
        tableIdentifierName <- getTableIdentifierName @b tableInfo
        SelPermInfo {..} <- hoistMaybe $ tableSelectPermissions roleName tableInfo
        pkeyColumns <- hoistMaybe $ tableInfo ^? tiCoreInfo . tciPrimaryKey . _Just . pkColumns
        relayRootFields <- lift $ mkRFs $ buildTableRelayQueryFields mkRootFieldName tableName tableInfo tableIdentifierName pkeyColumns
        let includeRelayWhen True = Just relayRootFields
            includeRelayWhen False = Nothing
        pure
          ( includeRelayWhen (isRootFieldAllowed QRFTSelect spiAllowedQueryRootFields),
            includeRelayWhen (isRootFieldAllowed SRFTSelect spiAllowedSubscriptionRootFields)
          )

  functionConnectionFields <- for (HashMap.toList functions) $ \(functionName, functionInfo) -> runMaybeT do
    let returnTableName = _fiReturnType functionInfo

    -- FIXME: only extract the TableInfo once to avoid redundant cache lookups
    returnTableInfo <- lift $ askTableInfo returnTableName
    pkeyColumns <- MaybeT $ (^? tiCoreInfo . tciPrimaryKey . _Just . pkColumns) <$> pure returnTableInfo
    lift $ mkRFs $ buildFunctionRelayQueryFields mkRootFieldName functionName functionInfo returnTableName pkeyColumns
  pure
    $ ( concat $ catMaybes $ tableConnectionQueryFields <> functionConnectionFields,
        concat $ catMaybes $ tableConnectionSubscriptionFields <> functionConnectionFields
      )
  where
    mkRFs = mkRootFields sourceName sourceConfig queryTagsConfig QDBR
    sourceName = _siName sourceInfo
    sourceConfig = _siConfiguration sourceInfo
    queryTagsConfig = _siQueryTagsConfig sourceInfo

buildMutationFields ::
  forall b r m n.
  (MonadBuildSchema b r m n, MonadIO m, Typeable n) =>
  TableFieldsCacher b ->
  MkRootFieldName ->
  Scenario ->
  SourceInfo b ->
  TableCache b ->
  FunctionCache b ->
  SchemaT r m [P.FieldParser n (MutationRootField UnpreparedValue)]
buildMutationFields cacher mkRootFieldName scenario sourceInfo tables (takeExposedAs FEAMutation -> functions) = do
  roleName <- retrieve scRole
  -- Frontend and Backend produce different fields for the same table, so they must
  -- not share a cache slot.
  let mutationSlot = case scenario of
        Frontend -> "mutation-frontend"
        Backend -> "mutation-backend"
  tableMutations <- for (HashMap.toList tables) \(tableName, tableInfo) -> runTableFieldsCacher cacher mutationSlot tableName do
    tableIdentifierName <- getTableIdentifierName @b tableInfo
    inserts <-
      mkRFs (MDBR . MDBInsert) $ buildTableInsertMutationFields mkRootFieldName scenario tableName tableInfo tableIdentifierName
    updates <-
      mkRFs (MDBR . MDBUpdate) $ buildTableUpdateMutationFields scenario tableInfo tableIdentifierName
    deletes <-
      mkRFs (MDBR . MDBDelete) $ buildTableDeleteMutationFields mkRootFieldName scenario tableName tableInfo tableIdentifierName
    pure $ concat [inserts, updates, deletes]
  functionMutations <- for (HashMap.toList functions) \(functionName, functionInfo) -> runMaybeT $ do
    let targetTableName = _fiReturnType functionInfo

    -- A function exposed as mutation must have a function permission
    -- configured for the role. See Note [Function Permissions]
    guard
      $
      -- when function permissions are inferred, we don't expose the
      -- mutation functions for non-admin roles. See Note [Function Permissions]

      -- when function permissions are inferred, we don't expose the
      -- mutation functions for non-admin roles. See Note [Function Permissions]

      -- when function permissions are inferred, we don't expose the
      -- mutation functions for non-admin roles. See Note [Function Permissions]
      roleName
      == adminRoleName
      || roleName
      `HashMap.member` _fiPermissions functionInfo
    lift $ mkRFs MDBR $ buildFunctionMutationFields mkRootFieldName functionName functionInfo targetTableName
  pure $ concat $ tableMutations <> catMaybes functionMutations
  where
    mkRFs :: forall a db remote action raw. (a -> db b) -> SchemaT r m [FieldParser n a] -> SchemaT r m [FieldParser n (RootField db remote action raw)]
    mkRFs = mkRootFields sourceName sourceConfig queryTagsConfig
    sourceName = _siName sourceInfo
    sourceConfig = _siConfiguration sourceInfo
    queryTagsConfig = _siQueryTagsConfig sourceInfo

----------------------------------------------------------------
-- Building root parser from fields

-- | Prepare the parser for query-type GraphQL requests, but with introspection
--   for queries, mutations and subscriptions built in.
buildQueryParser ::
  forall n m.
  (MonadMemoize m, MonadError QErr m, MonadParse n) =>
  [P.FieldParser n (NamespacedField (QueryRootField UnpreparedValue))] ->
  [P.FieldParser n (G.SchemaIntrospection -> QueryRootField UnpreparedValue)] ->
  [(RemoteSchemaName, P.FieldParser n (NamespacedField (RemoteSchemaRootField (RemoteRelationshipField UnpreparedValue) RemoteSchemaVariable)))] ->
  [P.FieldParser n (QueryRootField UnpreparedValue)] ->
  Maybe (Parser 'Output n (RootFieldMap (MutationRootField UnpreparedValue))) ->
  Maybe (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue))) ->
  m (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue)))
buildQueryParser sourceQueryFields apolloFederationFields remoteQueryFields actionQueryFields mutationParser subscriptionParser = do
  -- This method is aware of our rudimentary support for Apollo federation.
  -- Apollo federation adds two fields, `_service` and `_entities`. The
  -- `_service` field parser is a selection set that contains an `sdl` field.
  -- The `sdl` field, exposes a _serialized_ introspection of the schema. So in
  -- that sense it is similar to the `__type` and `__schema` introspection
  -- fields. However, a few things must be excluded from this introspection
  -- data, notably the Apollo federation fields `_service` and `_entities`
  -- themselves. So in this method we build a version of the introspection for
  -- Apollo federation purposes.
  let partialApolloQueryFP = sourceQueryFields <> fmap (fmap NotNamespaced) actionQueryFields <> fmap (\(n, rf) -> fmap (fmap (RFRemote n)) rf) remoteQueryFields
  basicQueryPForApollo <- queryRootFromFields partialApolloQueryFP
  let buildApolloIntrospection buildQRF = do
        partialSchema <-
          parseBuildIntrospectionSchema
            (P.parserType basicQueryPForApollo)
            (P.parserType <$> mutationParser)
            (P.parserType <$> subscriptionParser)
        pure $ NotNamespaced $ buildQRF $ convertToSchemaIntrospection partialSchema
      apolloFederationFieldsWithIntrospection :: [P.FieldParser n (NamespacedField (QueryRootField UnpreparedValue))]
      apolloFederationFieldsWithIntrospection = apolloFederationFields <&> (`P.bindField` buildApolloIntrospection)
      allQueryFields = partialApolloQueryFP <> apolloFederationFieldsWithIntrospection
  queryWithIntrospectionHelper allQueryFields mutationParser subscriptionParser

-- | Builds a @Schema@ at query parsing time
parseBuildIntrospectionSchema ::
  (MonadParse m) =>
  P.Type 'Output ->
  Maybe (P.Type 'Output) ->
  Maybe (P.Type 'Output) ->
  m Schema
parseBuildIntrospectionSchema q m s =
  buildIntrospectionSchema q m s `onLeft` (P.parseErrorWith P.ConflictingDefinitionsError . toErrorValue)

queryWithIntrospectionHelper ::
  forall n m.
  (MonadMemoize m, MonadParse n, MonadError QErr m) =>
  [P.FieldParser n (NamespacedField (QueryRootField UnpreparedValue))] ->
  Maybe (Parser 'Output n (RootFieldMap (MutationRootField UnpreparedValue))) ->
  Maybe (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue))) ->
  m (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue)))
queryWithIntrospectionHelper basicQueryFP mutationP subscriptionP = do
  let -- Per the GraphQL spec:
      --  * "The query root operation type must be provided and must be an Object type." (§3.2.1)
      --  * "An Object type must define one or more fields." (§3.6, type validation)
      -- Those two requirements cannot both be met when a service is mutations-only, and does not
      -- provide any query. In such a case, to meet both of those, we introduce a placeholder query
      -- in the schema.
      placeholderText = "There are no queries available to the current role. Either there are no sources or remote schemas configured, or the current role doesn't have the required permissions."
      placeholderField = NotNamespaced (RFRaw $ JO.String placeholderText) <$ P.selection_ Name._no_queries_available (Just $ G.Description placeholderText) P.string
      fixedQueryFP = if null basicQueryFP then [placeholderField] else basicQueryFP
  basicQueryP <- queryRootFromFields fixedQueryFP
  let buildIntrospectionResponse printResponseFromSchema =
        NotNamespaced
          . RFRaw
          . printResponseFromSchema
          <$> parseBuildIntrospectionSchema
            (P.parserType basicQueryP)
            (P.parserType <$> mutationP)
            (P.parserType <$> subscriptionP)
      introspection = [schema, typeIntrospection] <&> (`P.bindField` buildIntrospectionResponse)
      {-# INLINE introspection #-}
      partialQueryFields = fixedQueryFP ++ introspection
  safeSelectionSet queryRoot Nothing partialQueryFields <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)

queryRootFromFields ::
  forall n m.
  (MonadError QErr m, MonadParse n) =>
  [P.FieldParser n (NamespacedField (QueryRootField UnpreparedValue))] ->
  m (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue)))
queryRootFromFields fps =
  safeSelectionSet queryRoot Nothing fps <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)

buildMutationParser ::
  forall n m.
  (MonadMemoize m, MonadError QErr m, MonadParse n) =>
  [P.FieldParser n (NamespacedField (MutationRootField UnpreparedValue))] ->
  [(RemoteSchemaName, P.FieldParser n (NamespacedField (RemoteSchemaRootField (RemoteRelationshipField UnpreparedValue) RemoteSchemaVariable)))] ->
  [P.FieldParser n (MutationRootField UnpreparedValue)] ->
  m (Maybe (Parser 'Output n (RootFieldMap (MutationRootField UnpreparedValue))))
buildMutationParser mutationFields remoteFields actionFields = do
  let mutationFieldsParser =
        mutationFields
          <> ((\(n, rf) -> fmap (fmap (RFRemote n)) rf) <$> remoteFields)
          <> (fmap NotNamespaced <$> actionFields)
  whenMaybe (not $ null mutationFieldsParser)
    $ safeSelectionSet mutationRoot (Just $ G.Description "mutation root") mutationFieldsParser
    <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)

-- | Prepare the parser for subscriptions. Every postgres query field is
-- exposed as a subscription along with fields to get the status of
-- asynchronous actions.
buildSubscriptionParser ::
  forall n m.
  (MonadMemoize m, MonadError QErr m, MonadParse n) =>
  [P.FieldParser n (NamespacedField (QueryRootField UnpreparedValue))] ->
  [(RemoteSchemaName, P.FieldParser n (NamespacedField (RemoteSchemaRootField (RemoteRelationshipField UnpreparedValue) RemoteSchemaVariable)))] ->
  [P.FieldParser n (QueryRootField UnpreparedValue)] ->
  m (Maybe (Parser 'Output n (RootFieldMap (QueryRootField UnpreparedValue))))
buildSubscriptionParser sourceSubscriptionFields remoteSubscriptionFields actionFields = do
  let subscriptionFields =
        sourceSubscriptionFields
          <> fmap (\(n, rf) -> fmap (fmap (RFRemote n)) rf) remoteSubscriptionFields
          <> (fmap NotNamespaced <$> actionFields)
  whenMaybe (not $ null subscriptionFields)
    $ safeSelectionSet subscriptionRoot Nothing subscriptionFields
    <&> fmap (flattenNamespaces . fmap typenameToNamespacedRawRF)

-------------------------------------------------------------------------------
-- Local helpers

-- | Calls 'P.safeSelectionSet', and rethrows any error as a 'QErr'.
safeSelectionSet ::
  forall n m a.
  (QErrM n, MonadParse m) =>
  G.Name ->
  Maybe G.Description ->
  [FieldParser m a] ->
  n (Parser 'Output m (InsOrdHashMap.InsOrdHashMap G.Name (P.ParsedSelection a)))
safeSelectionSet name description fields =
  P.safeSelectionSet name description fields `onLeft` (throw500 . fromErrorMessage)

-- | Apply a source's customization options to a list of its fields.
customizeFields ::
  forall f n db remote action.
  (Functor f, MonadParse n) =>
  ResolvedSourceCustomization ->
  MkTypename ->
  f [FieldParser n (RootField db remote action JO.Value)] ->
  f [FieldParser n (NamespacedField (RootField db remote action JO.Value))]
customizeFields ResolvedSourceCustomization {..} =
  fmap . customizeNamespace _rscRootNamespace (const typenameToRawRF)

-- | All the 'BackendSchema' methods produce something of the form @m
-- [FieldParser n a]@, where @a@ is something specific to what is being parsed
-- by the given method.
--
-- In order to build the complete schema these must be
-- homogenised and be annotated with query-tag data, which this function makes
-- easy.
-- This function converts a single field parser. @mkRootFields@ transforms a
-- list of field parsers.
mkRootField ::
  forall b n a db remote action raw.
  (HasTag b, Functor n) =>
  SourceName ->
  SourceConfig b ->
  Maybe QueryTagsConfig ->
  (a -> db b) ->
  FieldParser n a ->
  FieldParser n (RootField db remote action raw)
mkRootField sourceName sourceConfig queryTagsConfig inj =
  fmap
    ( RFDB sourceName
        . AB.mkAnyBackend @b
        . SourceConfigWith sourceConfig queryTagsConfig
        . inj
    )

-- | `mkRootFields` is `mkRootField` applied on a list of `FieldParser`.
mkRootFields ::
  forall b m n a db remote action raw.
  (HasTag b, Functor m, Functor n) =>
  SourceName ->
  SourceConfig b ->
  Maybe QueryTagsConfig ->
  (a -> db b) ->
  m [FieldParser n a] ->
  m [FieldParser n (RootField db remote action raw)]
mkRootFields sourceName sourceConfig queryTagsConfig inj =
  fmap
    ( map
        (mkRootField sourceName sourceConfig queryTagsConfig inj)
    )

takeExposedAs :: FunctionExposedAs -> FunctionCache b -> FunctionCache b
takeExposedAs x = HashMap.filter ((== x) . _fiExposedAs)

subscriptionRoot :: G.Name
subscriptionRoot = Name._subscription_root

mutationRoot :: G.Name
mutationRoot = Name._mutation_root

queryRoot :: G.Name
queryRoot = Name._query_root

finalizeParser :: Parser 'Output P.Parse a -> ParserFn a
finalizeParser parser = P.toQErr . P.runParse . P.runParser parser

throwOnConflictingDefinitions :: (QErrM m) => Either P.ConflictingDefinitions a -> m a
throwOnConflictingDefinitions = either (throw500 . fromErrorMessage . toErrorValue) pure

typenameToNamespacedRawRF ::
  P.ParsedSelection (NamespacedField (RootField db remote action JO.Value)) ->
  NamespacedField (RootField db remote action JO.Value)
typenameToNamespacedRawRF = P.handleTypename $ NotNamespaced . RFRaw . JO.String . toTxt

typenameToRawRF ::
  P.ParsedSelection (RootField db remote action JO.Value) ->
  RootField db remote action JO.Value
typenameToRawRF = P.handleTypename $ RFRaw . JO.String . toTxt

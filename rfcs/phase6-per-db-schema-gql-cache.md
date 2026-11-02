# Phase 6 — Per-DB-Schema GQL Schema Cache

Companion to [`partial-schema-cache-rebuild.md`](./partial-schema-cache-rebuild.md).
Supersedes the earlier `phase6-gql-schema-regen.md` and
`phase7-per-db-schema-gql-cache.md` drafts, which are now obsolete.

## Context

After Phases 1–5, `buildGQLContext` still regenerates the full GraphQL schema
(all roles × all sources × all DB schemas) on every DDL operation. Phases 1–5
eliminated the dominant cost for the table cache — `buildTableCacheForSchema`
already caches `TableCoreInfo` per `(SourceName, SchemaName)`. The GQL layer
has not yet caught up: DDL on `auth` still rebuilds field parsers for `public`,
`analytics`, and every other DB schema in the same source.

The original Phase 6 draft proposed an intermediate per-source cache; Phase 7
proposed pushing that one level deeper to per-DB-schema. Because per-DB-schema
strictly subsumes per-source, this RFC goes directly to the finer granularity
and skips the intermediate step.

**Assumption inherited from Phases 1–5:** no cross-schema foreign keys. Remote
schema joins are out of scope.

---

## Current Data Flow

```
buildOutputsAndSchema  (one Inc.cache block — coarse)
  └─ buildAndCollectInfo  (full source resolution)
  └─ buildGQLContext
       └─ for each role:
            buildRoleContext(role, ALL sources)
              └─ for each source: buildSource(role, source)
                   └─ for each table in ALL schemas: build field parsers
              └─ mconcat → GQLContext
```

Any metadata change causes the outer `Inc.cache buildOutputsAndSchema` to miss,
and `buildGQLContext` rebuilds every schema in every source for every role.

## Target Data Flow

```
buildOutputsAndSchema  (outer coarse Inc.cache removed)
  └─ buildAndCollectInfo  (unchanged)
  └─ Inc.keyed over sources:
       for each source:
         Inc.keyed over DB schemas within source:
           for each schema:
             Inc.cache (schemaKey, metadataKey, dynamicConfig, allRoles)
               └─ buildAllRoleParsersForSchema(allRoles, filteredSourceInfo)
                    └─ for each role: buildSchemaRoleParsers → SchemaFieldParsers
  └─ assemble (pure):
       mconcat per-schema parsers per role  →  per-source parsers per role
       mconcat per-source parsers per role  →  merged parsers per role
       assembleGQLContext per role           →  GQLContext per role
```

**Invalidation semantics:**

| Event | What re-runs |
|---|---|
| DDL on `auth` in `pg-main` | Only `pg-main / auth` cache block |
| DDL on `public` in `pg-main` | Only `pg-main / public` cache block |
| Permission change (any) | All schema blocks re-run via `metadataKey` — correct, permissions affect GQL |
| New role added | All schema blocks re-run — unavoidable |
| `dynamicConfig` changes | All schema blocks re-run — unavoidable |

---

## Steps

### Step 1 — Add `schemaNameOf` to `BackendMetadata`

**File:** `server/src-lib/Hasura/RQL/Types/Backend.hs`

`PartialRebuild.hs` (Phase 4) already uses a local `schemaNameOf` to filter
`_siTables`. Promote it to the `BackendMetadata` type class so the GQL pipeline
can use it:

```haskell
class BackendMetadata b where
  ...
  -- Extract the DB schema from a table's qualified name.
  -- Backends with no schema namespace (e.g. BigQuery datasets) return a
  -- constant sentinel so they produce a single cache block per source,
  -- behaving identically to a coarse per-source cache.
  schemaNameOf :: TableName b -> SchemaName
```

Postgres implementation (`Backends/Postgres/Instances/Schema.hs`):

```haskell
schemaNameOf = qSchema . tableInfoName
```

Default for non-Postgres backends:

```haskell
schemaNameOf _ = SchemaName "default"
```

**Risk:** Low — additive; all existing backends compile with the default.

---

### Step 2 — Add `SchemaFieldParsers` type

**File:** `server/src-lib/Hasura/GraphQL/Context.hs`

A single result type used at both the per-schema and the per-source aggregation
levels. Because it is a `Monoid`, schemas `mconcat` into a source and sources
`mconcat` into the global result without needing a separate `SourceFieldParsers`
type.

```haskell
data SchemaFieldParsers = SchemaFieldParsers
  { _sfpQuery        :: [P.FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))]
  , _sfpMutFrontend  :: [P.FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))]
  , _sfpMutBackend   :: [P.FieldParser P.Parse (NamespacedField (MutationRootField UnpreparedValue))]
  , _sfpSubscription :: [P.FieldParser P.Parse (NamespacedField (QueryRootField UnpreparedValue))]
  , _sfpApolloFed    :: [(G.Name, Parser 'Output P.Parse (ApolloFederationParserFunction P.Parse))]
  }

instance Semigroup SchemaFieldParsers where
  a <> b = SchemaFieldParsers
    (_sfpQuery        a <> _sfpQuery        b)
    (_sfpMutFrontend  a <> _sfpMutFrontend  b)
    (_sfpMutBackend   a <> _sfpMutBackend   b)
    (_sfpSubscription a <> _sfpSubscription b)
    (_sfpApolloFed    a <> _sfpApolloFed    b)

instance Monoid SchemaFieldParsers where
  mempty = SchemaFieldParsers [] [] [] [] []
```

**Risk:** Low — new type, no existing code touched.

---

### Step 3 — Extract `buildSchemaRoleParsers` and `partitionSourceBySchema`

**File:** `server/src-lib/Hasura/GraphQL/Schema.hs`

#### 3a — `buildSchemaRoleParsers`

Extracted from `buildSource` (the local helper inside `buildRoleContext`). The
only difference: it receives a `SourceInfo b` whose `_siTables` and
`_siFunctions` have already been filtered to one DB schema.

```haskell
buildSchemaRoleParsers
  :: forall b m.
     (BackendSchema b, MonadError QErr m, MonadIO m)
  => SchemaContext
  -> SchemaOptions
  -> SourceInfo b          -- _siTables / _siFunctions filtered to one SchemaName
  -> MemoizeT m SchemaFieldParsers
buildSchemaRoleParsers schemaContext schemaOptions sourceInfo@(SourceInfo {..}) =
  runSourceSchema schemaContext schemaOptions sourceInfo do
    let validTables         = takeValidTables         _siTables
        validFunctions      = takeValidFunctions      _siFunctions
        validNativeQueries  = takeValidNativeQueries  _siNativeQueries
        validStoredProcs    = takeValidStoredProcedures _siStoredProcedures
        mkRootFieldName     = _rscRootFields _siCustomization
        mkTypename          = SC._rscTypeNames _siCustomization
        mkRoot sfx          = mkTypename <> MkTypename (<> sfx)
    (queryFs, subscriptionFs, apolloFed) <-
      buildQueryAndSubscriptionFields mkRootFieldName sourceInfo
        validTables validFunctions validNativeQueries validStoredProcs
    mutFE <- customizeFields _siCustomization (mkRoot Name.__mutation_frontend)
               (buildMutationFields mkRootFieldName Frontend sourceInfo validTables validFunctions)
    mutBE <- customizeFields _siCustomization (mkRoot Name.__mutation_backend)
               (buildMutationFields mkRootFieldName Backend  sourceInfo validTables validFunctions)
    qFs   <- customizeFields _siCustomization (mkRoot Name.__query)        (pure queryFs)
    sFs   <- customizeFields _siCustomization (mkRoot Name.__subscription) (pure subscriptionFs)
    pure SchemaFieldParsers
      { _sfpQuery        = qFs
      , _sfpMutFrontend  = mutFE
      , _sfpMutBackend   = mutBE
      , _sfpSubscription = sFs
      , _sfpApolloFed    = apolloFed
      }
```

Add a wrapper that iterates over all roles for one schema, used by the arrow
pipeline:

```haskell
buildAllRoleParsersForSchema
  :: forall b m.
     (BackendSchema b, MonadError QErr m, MonadIO m)
  => SchemaContext          -- role-independent context
  -> SchemaOptions
  -> [RoleName]
  -> SourceInfo b           -- schema-filtered
  -> m (HashMap RoleName SchemaFieldParsers)
buildAllRoleParsersForSchema schemaContext schemaOptions roles filteredSourceInfo =
  fmap HashMap.fromList $ for roles \role -> do
    let ctx = schemaContext { scRole = role }
    parsers <- runMemoizeT $ buildSchemaRoleParsers ctx schemaOptions filteredSourceInfo
    pure (role, parsers)
```

#### 3b — `partitionSourceBySchema`

Pure helper that splits a `SourceInfo b` into one entry per DB schema, each
containing only the objects belonging to that schema:

```haskell
partitionSourceBySchema
  :: forall b. (BackendMetadata b, Hashable (TableName b))
  => SourceInfo b
  -> HashMap SchemaName (SourceInfo b)
partitionSourceBySchema si@(SourceInfo {..}) =
  HashMap.mapWithKey (\schemaName _ ->
    si
      { _siTables    = HashMap.filterWithKey
                         (\tn _ -> schemaNameOf @b tn == schemaName) _siTables
      , _siFunctions = HashMap.filterWithKey
                         (\fn _ -> schemaNameOf @b (functionInfoName fn) == schemaName) _siFunctions
      -- NativeQueries and StoredProcedures: filter by the schema component of
      -- their qualified name in the same way.
      }
  ) schemaGroups
  where
    schemaGroups = HashMap.fromList [(schemaNameOf @b tn, ()) | tn <- HashMap.keys _siTables]
```

Only schemas with at least one tracked table get a cache block. A source with
no tables produces an empty map — correct.

#### 3c — Update `buildRoleContext`

Replace the internal `buildSource` call with a loop over schema partitions so
the monadic path stays correct and produces the same GQL output:

```haskell
-- inside buildRoleContext, replacing the existing per-source loop:
(sourcesQueryFields, ...) <-
  fmap mconcat $ for (toList sources) \backendSourceInfo ->
    AB.dispatchAnyBackend @BackendSchema backendSourceInfo \(si :: SourceInfo b) -> do
      let schemaMap = partitionSourceBySchema @b si
      fmap (mconcat . fmap toTuple) $ for (toList schemaMap) \filteredSi ->
        buildSchemaRoleParsers schemaContext schemaOptions filteredSi
```

This is a pure refactor — behaviour is identical to today; no `Inc` machinery
is involved here.

**Risk:** Medium — `partitionSourceBySchema` must not silently drop functions
whose schema has no tracked table. Test with a fixture containing a function in
a schema that has no tables.

---

### Step 4 — Extract `assembleGQLContext` from `buildGQLContext`

**File:** `server/src-lib/Hasura/GraphQL/Schema.hs`

`buildGQLContext` currently rebuilds everything from `SourceCache`. Refactor it
so that the source-specific work is pre-computed (by the arrow pipeline) and
`buildGQLContext` becomes a pure assembly step that handles only the
non-source-specific parts: actions, remote schemas, introspection, and the
unauthenticated/admin contexts.

```haskell
-- New signature — accepts pre-computed per-role source parsers instead of SourceCache.
buildGQLContext
  :: ...
  -> HashMap RoleName SchemaFieldParsers   -- pre-computed; SourceCache removed
  -> HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject)
  -> [ActionInfo]
  -> AnnotatedCustomTypes
  -> Maybe SchemaRegistryContext
  -> Logger Hasura
  -> m (ContextMap, GQLContext, HashSet InconsistentMetadata)
```

Extract `assembleGQLContext` as the per-role combiner:

```haskell
assembleGQLContext
  :: (MonadError QErr m, MonadIO m)
  => SchemaSampledFeatureFlags
  -> (SQLGenCtx, Options.InferFunctionPermissions)
  -> SchemaFieldParsers         -- pre-computed source fields for this role
  -> HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject)
  -> [ActionInfo]
  -> AnnotatedCustomTypes
  -> RoleName
  -> Options.RemoteSchemaPermissions
  -> Set.HashSet ExperimentalFeature
  -> ApolloFederationStatus
  -> Maybe SchemaRegistryContext
  -> m RoleContextValue
```

`assembleGQLContext` does everything `buildRoleContext` does today *except* the
`buildSource` loop — it starts from already-computed `SchemaFieldParsers` and
adds action fields, remote schema fields, Apollo fields, and introspection.

The unauthenticated context and admin introspection are derived from
`mergedParsers ! adminRole` without a separate source scan (same approach as
the original Phase 6d).

**Risk:** Medium — interface change to `buildGQLContext` and `buildRoleContext`.
All callers go through `buildOutputsAndSchema`; no external call sites.
Golden-output test catches regressions.

---

### Step 5 — Per-schema `Inc.keyed × Inc.cache` in the arrow pipeline

**File:** `server/src-lib/Hasura/RQL/DDL/Schema/Cache.hs`

Inside `buildOutputsAndSchema`, replace the `bindA -< buildGQLContext ...` call
with nested `Inc.keyed` blocks and per-schema `Inc.cache` blocks:

```haskell
-- Compute allRoles (same as today — from sources + actions + inherited roles).
-- allRoles is declared as an Inc.Dependency so every cache block re-runs when
-- a role is added or removed.
allRolesDep <- Inc.newDependency -< allRoles

-- Per-source, per-schema cached parser building:
perSourceParsers <-
  ( | Inc.keyed    -- outer key: SourceName
      ( \sourceName backendSourceInfo ->
          AB.dispatchAnyBackendArrow @BackendMetadata
            ( \(si :: SourceInfo b) ->
                let schemaMap = partitionSourceBySchema @b si
                in  ( | Inc.keyed    -- inner key: SchemaName
                        ( \schemaName filteredSi ->
                            Inc.cache proc
                              ( dynamicConfig
                              , allRolesDep
                              , schemaKeyDep    -- Inc.Dependency (Maybe Inc.InvalidationKey)
                              , metadataKeyDep  -- Inc.Dependency Inc.InvalidationKey
                              ) -> do
                              -- Declare dependencies so the cache re-runs when
                              -- either the targeted schema or global metadata changes.
                              schemaKeyVal   <- Inc.dependOn -< schemaKeyDep
                              metadataKeyVal <- Inc.dependOn -< metadataKeyDep
                              let effectiveKey = fromMaybe metadataKeyVal schemaKeyVal
                              bindA -< buildAllRoleParsersForSchema
                                         dynamicConfig (Inc.value allRolesDep)
                                         filteredSi
                        )
                    |) schemaMap
            )
            backendSourceInfo
      )
  |) (_boSources resolvedOutputs)

-- perSourceParsers :: HashMap SourceName (HashMap SchemaName (HashMap RoleName SchemaFieldParsers))
```

`schemaKeyDep` for each `(sourceName, schemaName)` pair:

```haskell
schemaKeyDep =
  Inc.selectD #_ikSourceSchemas invalidationKeysDep
    >>^ HashMap.lookup (sourceName, schemaName)
```

`metadataKeyDep`:

```haskell
metadataKeyDep = Inc.selectD #_ikMetadata invalidationKeysDep
```

This mirrors the exact pattern of `buildTableCacheForSchema` (Step 3b of
Phase 3), which already uses both a schema-specific key and a metadata key
fallback.

**Why two keys?**

- `schemaKeyDep` is `Nothing` until `ciSourceSchemas` fires for this
  `(sourceName, schemaName)`. DDL on `auth` increments only the `auth` entry.
- `metadataKeyDep` is the global metadata counter. A permission change sets
  `ciMetadata = True` → `_ikMetadata` increments → all schema blocks re-run.
  This is correct: permission changes affect GQL field visibility.
- Using `effectiveKey = fromMaybe metadataKey schemaKey` means: prefer the
  schema-specific key when available; fall back to metadata key otherwise.

**Risk:** High — the two-key pattern must be declared correctly. If
`schemaKeyDep` or `metadataKeyDep` is read as a plain value (not via
`Inc.dependOn`), the cache will not invalidate. Cross-check against
`buildTableCacheForSchema`'s implementation.

---

### Step 6 — Assemble: schema → source → GQLContext

**File:** `server/src-lib/Hasura/RQL/DDL/Schema/Cache.hs`
(inline in `buildOutputsAndSchema`, after Step 5)

```haskell
-- Collapse schemas within each source:
let perSourceMerged :: HashMap SourceName (HashMap RoleName SchemaFieldParsers)
    perSourceMerged =
      HashMap.map
        (foldl' (HashMap.unionWith (<>)) mempty . HashMap.elems)
        perSourceParsers

-- Collapse sources:
let mergedParsers :: HashMap RoleName SchemaFieldParsers
    mergedParsers =
      foldl' (HashMap.unionWith (<>)) mempty (HashMap.elems perSourceMerged)

-- Assemble GQLContext per role (actions + remotes + introspection added here):
out3 <- bindA -<
  buildGQLContext
    (_cdcSchemaSampledFeatureFlags dynamicConfig)
    ...
    mergedParsers   -- replaces _boSources resolvedOutputs
    (_boRemoteSchemas resolvedOutputs)
    (_boActions resolvedOutputs)
    (_boCustomTypes resolvedOutputs)
    mSchemaRegistryContext
    logger
```

**Risk:** Low — pure `mconcat` over `Monoid SchemaFieldParsers`.

---

### Step 7 — Remove the outer coarse `Inc.cache` on `buildOutputsAndSchema`

**File:** `server/src-lib/Hasura/RQL/DDL/Schema/Cache.hs`

The outer `Inc.cache buildOutputsAndSchema` at line 464 was the only caching
guard for the full GQL regeneration. Now that each `(sourceName, schemaName)`
pair has its own `Inc.cache` block (Step 5), the outer cache is
counterproductive: its key must include all invalidation keys, so any schema
DDL causes an outer cache miss and re-enters `buildOutputsAndSchema` — which is
correct, but then re-enters `buildAndCollectInfo` unnecessarily.

Drop the `Inc.cache` wrapper and invoke `buildOutputsAndSchema` directly:

```haskell
-- Before:
Inc.cache buildOutputsAndSchema -< (metadataDep, dynamicConfig, invalidationKeysDep, storedIntrospection)

-- After:
buildOutputsAndSchema -< (metadataDep, dynamicConfig, invalidationKeysDep, storedIntrospection)
```

`buildAndCollectInfo` inside `buildOutputsAndSchema` already has its own
fine-grained `Inc.cache` blocks for source resolution, table cache, etc. —
the outer cache was only doing useful work for `buildGQLContext`, which is now
handled by the per-schema blocks.

**Risk:** Medium — removing the outer cache means `buildAndCollectInfo` runs on
every invalidation (not just schema-triggering ones). Verify via the existing
incremental-build benchmarks that this does not regress non-GQL rebuild times.
If needed, scope the outer cache to only `buildAndCollectInfo` (not GQL), then
feed its outputs into the per-schema keyed blocks.

---

## Files Changed

| File | Change |
|---|---|
| `Hasura/RQL/Types/Backend.hs` | Add `schemaNameOf` to `BackendMetadata` with a constant default |
| `Hasura/Backends/Postgres/Instances/Schema.hs` | Implement `schemaNameOf = qSchema . tableInfoName` |
| `Hasura/GraphQL/Context.hs` | Add `SchemaFieldParsers` with `Semigroup` / `Monoid` instances |
| `Hasura/GraphQL/Schema.hs` | Extract `buildSchemaRoleParsers`, `buildAllRoleParsersForSchema`, `partitionSourceBySchema`, `assembleGQLContext`; refactor `buildRoleContext` and `buildGQLContext` |
| `Hasura/RQL/DDL/Schema/Cache.hs` | Add `Inc.keyed × Inc.keyed × Inc.cache` over sources × schemas; inline assembly; remove outer coarse `Inc.cache` |

No new files needed.

---

## Testing

### Unit

- **`partitionSourceBySchema`** — fixture with tables in `public`, `auth`, `analytics`
  and a function in `public`:
  - Each partition contains only its schema's tables and functions.
  - Union of all partitions equals the original `_siTables`.
  - A function in a schema with no tracked table still appears in that schema's
    partition (schemaGroups must include function schemas too — see Risk below).
- **`SchemaFieldParsers` `Monoid`** — `sfp1 <> sfp2 <> sfp3` field counts equal
  sum of individual counts; `mempty <> sfp == sfp`.
- **`assembleGQLContext` identity** — same inputs before and after refactor
  produce identical `GQLContext` (golden output test).

### Incremental cache correctness

Fixture: one source, schemas `public` (100 tables) and `auth` (50 tables),
3 roles.

| Step | Expected |
|---|---|
| DDL on `auth` | Only `auth` cache block re-entered; `public` block is a cache hit |
| DDL on `public` | Only `public` block re-entered; `auth` is a cache hit |
| Add a role | All schema blocks re-run exactly once |
| Permission change on `auth.users` | All blocks re-run via `metadataKey`; none are skipped |
| Reload metadata | All blocks re-run (metadataKey increments) |

### Integration

- Full DDL suite (`runTrackTable`, `runUntrackTable`, `runSQL`) passes
  unchanged.
- Golden-schema test: `buildGQLContext old_path == buildGQLContext new_path` on
  identical metadata, confirming the refactor is behaviour-preserving.

### Benchmark

Extend the existing Phase 1–5 benchmark (1 source, 5 schemas × 200 tables):

| Scenario | Before | Target |
|---|---|---|
| DDL on 1 schema | Rebuild all 5 (1000 tables) | Rebuild 1 (200 tables) |
| GQL regen p50 | Proportional to all tables × all roles | Proportional to 1 schema × all roles |
| Permission change | Full rebuild (unavoidable) | Full rebuild (unavoidable, same cost) |

---

## Risk Summary

| Risk | Severity | Mitigation |
|---|---|---|
| `schemaKeyDep` or `metadataKeyDep` not declared via `Inc.dependOn` → stale GQL | High | Mirror `buildTableCacheForSchema` exactly; integration tests catch stale GQL |
| `partitionSourceBySchema` drops functions/NQs in schemas with no tracked table | High | Extend `schemaGroups` to include function schemas; add explicit unit test for this case |
| Removing outer `Inc.cache` regresses `buildAndCollectInfo` rebuild frequency | Medium | Measure with existing incremental benchmarks; if needed, scope the outer cache to only `buildAndCollectInfo` |
| `assembleGQLContext` misses action / introspection fields after refactor | Medium | Golden-output test: compare full schema before and after with no DDL changes |
| Non-Postgres backends produce single-bucket partitions (one `"default"` schema) | Low | Correct by design; behaviour identical to a coarse per-source cache |
| `SchemaFieldParsers` `Monoid` misorders fields vs current `mconcat` | Low | Property test: `buildGQLContext old == buildGQLContext new` on same inputs |

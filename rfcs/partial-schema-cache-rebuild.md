# Partial Schema Cache Rebuild per DB Schema

## Problem

Every DDL operation calls `buildSchemaCache`, which invalidates and re-runs the
full arrow pipeline for the affected source:

1. `tryResolveSource` — re-queries the Postgres catalog for all tracked tables
   in the source, even if only one schema changed.
2. `buildTableCache` — rebuilds `TableCoreInfo` for every table in the source.
3. `buildGQLContext` — regenerates GraphQL schema for all roles across all
   sources.

For a source with many tables spread across multiple schemas, a DDL operation
touching a single schema (e.g. `CREATE TABLE analytics.events`) still pays the
full cost of rebuilding every schema.

**Assumption:** no cross-schema foreign keys are used. This eliminates the main
risk of stale FK references after a partial merge.

---

## Current Call Path (Simplified)

```
DDL API handler
  └─ buildSchemaCacheWithInvalidations
       └─ tryBuildSchemaCacheWithOptions
            └─ buildSchemaCacheRule   (arrow pipeline)
                 ├─ tryResolveSource          ← Inc.cache at SOURCE level
                 │    └─ resolveDatabaseMetadata  ← PG catalog query (all tracked tables)
                 ├─ buildTableCache           ← rebuilds ALL tables in source
                 ├─ buildSource               ← resolves rels/perms/functions
                 └─ buildGQLContext           ← full GraphQL schema regen
```

Key files:
- `server/src-lib/Hasura/RQL/Types/SchemaCache/Build.hs` — `CacheInvalidations`,
  `InvalidationKeys`, `buildSchemaCacheFor`, `buildSchemaCacheWithInvalidations`
- `server/src-lib/Hasura/RQL/DDL/Schema/Cache.hs` — arrow pipeline,
  `tryResolveSource`, `buildAndCollectInfo`
- `server/src-lib/Hasura/RQL/DDL/Schema/Cache/Common.hs` — `InvalidationKeys`,
  `invalidateKeys`
- `server/src-lib/Hasura/Backends/Postgres/DDL/Source.hs` — `resolveDatabaseMetadata`
- `server/src-lib/Hasura/RQL/Types/Source.hs` — `SourceInfo`,
  `DBObjectsIntrospection`

New file (to be created):
- `server/src-lib/Hasura/RQL/DDL/Schema/Cache/PartialRebuild.hs`

---

## Implementation Phases

### Phase 1 — Add Schema-Level Invalidation Keys

**Files:** `Build.hs`, `Cache/Common.hs`

Extend `CacheInvalidations` with a new field for schema-level invalidations:

```haskell
-- Build.hs
data CacheInvalidations = CacheInvalidations
  { ciMetadata       :: Bool
  , ciRemoteSchemas  :: HashSet RemoteSchemaName
  , ciSources        :: HashSet SourceName
  , ciDataConnectors :: HashSet DataConnectorName
  , ciSourceSchemas  :: HashSet (SourceName, SchemaName)   -- NEW
  }
```

Update the `Semigroup` instance (currently a 4-tuple pattern match) to include
the new field. `SchemaName` is `Hasura.Backends.Postgres.SQL.Types.SchemaName`
(a newtype over `Text`); import it here or introduce a shared alias.

Extend `InvalidationKeys` with a per-schema map:

```haskell
-- Cache/Common.hs
data InvalidationKeys = InvalidationKeys
  { _ikMetadata      :: Inc.InvalidationKey
  , _ikRemoteSchemas :: HashMap RemoteSchemaName Inc.InvalidationKey
  , _ikSources       :: HashMap SourceName Inc.InvalidationKey
  , _ikBackends      :: BackendMap BackendInvalidationKeysWrapper
  , _ikSourceSchemas :: HashMap (SourceName, SchemaName) Inc.InvalidationKey  -- NEW
  }
```

Update `initialInvalidationKeys` (add `mempty`), `invalidateKeys` (increment
schema key for each element in `ciSourceSchemas`; invalidating a whole source
via `ciSources` must also invalidate all its schema keys to keep consistency).
Update `makeLenses` call and the `Inc.Select` instance (derived via `Generic`,
so this is automatic).

**Risk:** Low. Additive change; `mempty` on the new field means all existing
call sites are unaffected.

---

### Phase 2 — Schema-Filtered Catalog Introspection

**Files:** `Backends/Postgres/DDL/Source.hs`

`resolveDatabaseMetadata` currently passes all tracked table names into
`fetchTableMetadata`. Add a schema-filtered variant:

```haskell
-- Source.hs (Postgres)
resolveDatabaseMetadataForSchemas ::
  ( Backend ('Postgres pgKind), ToMetadataFetchQuery pgKind,
    FetchFunctionMetadata pgKind, FetchTableMetadata pgKind,
    MonadIO m, MonadBaseControl IO m, FF.HasFeatureFlagChecker m ) =>
  SourceMetadata ('Postgres pgKind) ->
  SourceConfig ('Postgres pgKind) ->
  NonEmpty SchemaName ->          -- only introspect these schemas
  m (Either QErr (DBObjectsIntrospection ('Postgres pgKind)))
```

Implementation: filter `_smTables` to those whose `qSchema` matches one of the
provided `SchemaName`s before passing to `fetchTableMetadata`. Functions are
filtered the same way via `pronamespace`.

This is purely a filtering change on the already-scoped query — no new SQL
needed. The result is a `DBObjectsIntrospection` covering only the requested
schemas; the caller is responsible for merging it with the cached introspection
of untouched schemas (see Phase 4).

**Risk:** Low. Existing `resolveDatabaseMetadata` is unchanged; new function is
additive.

---

### Phase 3 — Per-Schema Caching in the Arrow Pipeline

**Files:** `Cache.hs`

Currently `tryResolveSource` is one `Inc.cache` block keyed at the source
level. Split it so each schema within a source gets its own cache entry.

**Step 3a.** After `tryResolveSource` succeeds, partition `DBObjectsIntrospection`
by schema:

```haskell
partitionIntrospectionBySchema
  :: DBObjectsIntrospection ('Postgres pgKind)
  -> HashMap SchemaName (DBObjectsIntrospection ('Postgres pgKind))
```

**Step 3b.** Replace the single `buildTableCache` call with an `Inc.keyed`
dispatch over schemas:

```haskell
-- inside the arrow pipeline, after tryResolveSource:
perSchemaCoreInfo <-
  ( | Inc.keyed
      ( \schemaName schemaIntrospection ->
          Inc.cache proc (sourceConfig, tableInputs, schemaInvalidationKey, ...) -> do
            buildTableCache -< (sourceName, sourceConfig, _rsTables schemaIntrospection,
                                tableInputs, schemaInvalidationKey, namingConv, logicalModels)
      )
  |) schemaMap
```

The `schemaInvalidationKey` for each schema is
`Inc.selectD #_ikSourceSchemas invalidationKeys >>^ HashMap.lookup (sourceName, schemaName)`.

When schema X's key has not changed, `Inc.cache` skips its block entirely and
returns the memoised `HashMap (TableName b) TableCoreInfo`. When schema X's key
changes (because `ciSourceSchemas` contained `(sourceName, X)`), only that
block re-runs.

**Risk:** Moderate. `Inc.ArrowCache` / `Inc.keyed` requires careful dependency
tracking. If a key is read inside the arrow but not declared as an
`Inc.Dependency`, the cache will not invalidate when it changes. Test with the
existing incremental-build test harness.

---

### Phase 4 — Merge Partial Results

**Files:** `Cache/PartialRebuild.hs` (new)

After a schema-scoped rebuild, merge the new `TableCache` slice back into the
existing `SourceInfo` without touching other schemas.

```haskell
-- PartialRebuild.hs
mergeSchemaIntoSourceInfo
  :: forall b. (BackendMetadata b, Hashable (TableName b))
  => SchemaName                                -- schema that was rebuilt
  -> HashMap (TableName b) (TableInfo b)       -- freshly built tables for that schema
  -> SourceInfo b                              -- current full source info
  -> SourceInfo b
mergeSchemaIntoSourceInfo schemaName newTables existing =
  existing
    { _siTables =
        HashMap.union
          newTables
          (HashMap.filter ((/= schemaName) . tableSchema) (_siTables existing))
    }
  where
    tableSchema :: TableInfo b -> SchemaName
    tableSchema = schemaNameOf @b . tableInfoName
```

`schemaNameOf` extracts the schema from a `TableName b`. For Postgres this is
`qSchema`; other backends can implement it trivially (single-schema backends
always return a constant).

Add `mergeSchemaIntoSchemaCache` at the top level to thread the update through
`scSources`.

**Risk:** Low given no cross-schema FKs. The union is a pure `HashMap` operation.
The only invariant to preserve is that tables belonging to other schemas are
untouched — enforced by the `filter`.

---

### Phase 5 — New DDL Entry Point

**Files:** `Build.hs`, `PartialRebuild.hs`

```haskell
-- Build.hs
buildSchemaCacheForDbSchema
  :: (QErrM m, CacheRWM m, MetadataM m)
  => SourceName
  -> SchemaName
  -> MetadataModifier
  -> m ()
buildSchemaCacheForDbSchema sourceName schemaName modifier =
  buildSchemaCacheWithInvalidations
    (mempty { ciSourceSchemas = HashSet.singleton (sourceName, schemaName) })
    modifier
```

Wire this into DDL handlers where the schema is statically known:

| DDL Operation | Current call | Target call |
|---|---|---|
| `runSQL` (DDL SQL) | `buildSchemaCache` | `buildSchemaCacheForDbSchema src schema` |
| Track table | `buildSchemaCacheFor` (per-object) | unchanged — already fast |
| Add/drop relationship | `buildSchemaCacheFor` | unchanged |
| Add/drop permission | `buildSchemaCacheFor` | unchanged |
| `reload_metadata` | `buildSchemaCacheWithInvalidations` | unchanged |

The schema name is available from the `TrackTable` payload's `QualifiedObject`
(`qSchema`) or from parsing the SQL statement for `runSQL`.

---

### Phase 6 — GraphQL Schema Regeneration (Deferred)

`buildGQLContext` still runs in full after a partial table cache merge. This is
intentional for the first iteration — the partial rebuild eliminates the
dominant cost (DB catalog query + `buildTableCache`) while keeping correctness
simple.

Future work: scope `buildGQLContext` to only the changed source's roles. The
function already processes sources in isolation; the main complication is that
remote schema joins reference cross-source types.

---

## Testing Plan

**Unit tests** (`server/tests-hspec/`):
- `mergeSchemaIntoSourceInfo` preserves tables from untouched schemas and fully
  replaces tables in the rebuilt schema.
- `invalidateKeys` on `ciSourceSchemas` increments only the targeted
  `(SourceName, SchemaName)` keys; other schemas and sources are unchanged.
- Invalidating a full source (`ciSources`) also invalidates all its schema keys.

**Integration tests** (existing DDL suite):
- Run the full `runTrackTable` / `runUntrackTable` / `runSQL` test suite after
  each phase. Any stale cache entry surfaces as a GraphQL query returning the
  wrong result or an inconsistency error.

**Benchmark**:
- Fixture: 1 source, 5 schemas × 200 tables = 1000 tables total.
- Measure `p50`/`p99` latency of `run_sql` DDL before and after.
- Target: latency proportional to 1 schema (200 tables), not all 5 (1000 tables).

---

## Risk Summary

| Risk | Severity | Mitigation |
|---|---|---|
| `Inc.cache` dependency not declared → stale cache | High | Property tests; `--debug-inc-cache` flag to force full rebuild |
| `Semigroup` / JSON instances for `CacheInvalidations` broken by new field | Medium | Compiler + golden JSON tests catch this immediately |
| Non-PG backends break if `schemaNameOf` not implemented | Medium | Default implementation returns a constant; opt-in flag per backend |
| `buildGQLContext` still full-cost | Low | Accepted; documented as Phase 6 |

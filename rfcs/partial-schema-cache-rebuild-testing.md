# Testing Plan — Partial Schema Cache Rebuild

Related RFC: [partial-schema-cache-rebuild.md](partial-schema-cache-rebuild.md)

---

## 1. Unit Tests — Pure Functions

**Location:** `server/src-lib/Hasura/RQL/DDL/Schema/Cache/PartialRebuildSpec.hs`
**Runner:** `cabal test graphql-engine-tests` (add to the hspec suite)

### `mergeSchemaIntoSourceInfo`

| Test | Setup | Assert |
|---|---|---|
| Replaces only the target schema | `existing` has tables in `public` and `analytics`; `newTables` covers only `analytics` | `_siTables result` contains the new `analytics` tables AND the original `public` tables unchanged |
| Drops tables removed from target schema | `existing.analytics` has `t1,t2`; `newTables` has only `t1` | `t2` is absent from result; `t1` has the fresh `TableInfo` |
| No-op when schema is absent in existing | `newTables` targets `staging` but `existing` has no `staging` tables | Result = union of `newTables` and all existing tables unchanged |
| Does not touch other schemas | 3 schemas in `existing`; only one rebuilt | The other 2 schemas are byte-for-byte identical in result |

### `mergeSchemaIntoSchemaCache`

| Test | Setup | Assert |
|---|---|---|
| Source absent → cache unchanged | `sourceName` not in `scSources` | Returns the same `SchemaCache` |
| Backend type mismatch → old entry preserved | `oldBSI` is Postgres; `freshBSI` is MSSQL | `scSources` is unchanged |
| Happy path | Same backend, `freshBSI` has new tables for schema X | Cache now has new tables for X, other schemas untouched |

### `partitionIntrospectionBySchema`

| Test | Setup | Assert |
|---|---|---|
| Tables go into correct buckets | 3 tables across 2 schemas | Each `DBObjectsIntrospection` slice contains only its schema's tables |
| Functions go into correct buckets | 2 functions in different schemas | Same as above for functions |
| `scalars` and `logicalModels` are broadcast to every slice | 2 schemas | Both slices share the same `_rsScalars` / `_rsLogicalModels` values |
| Empty input → empty map | `mempty` introspection | Returns `HashMap.empty` |

### `invalidateKeys` — `ciSourceSchemas` behaviour

**Location:** extend `server/lib/incremental/test/Hasura/IncrementalSpec.hs` or a new `CacheInvalidationsSpec.hs`

| Test | Input | Assert |
|---|---|---|
| Schema-level invalidation increments only the targeted key | `ciSourceSchemas = {(src, schemaA)}`; keys for `(src, schemaA)`, `(src, schemaB)`, `(src2, schemaA)` all pre-set | Only `(src, schemaA)` key is incremented; others unchanged |
| Full-source invalidation cascades to all its schema keys | `ciSources = {src}`; keys for `(src, schemaA)` and `(src, schemaB)` pre-set | Both schema keys are incremented |
| Full-source invalidation does NOT touch other sources' schema keys | `ciSources = {src1}` | Keys for `(src2, *)` unchanged |
| `mempty` invalidation touches nothing | `ciSources = ∅`, `ciSourceSchemas = ∅` | All keys identical before/after |

---

## 2. Integration Tests — DDL Correctness

**Location:** `server/lib/api-tests/` (existing Hspec suite with a live Postgres fixture)

These tests catch stale cache entries by querying GraphQL after DDL and expecting the correct schema.

```
fixture: source "default", schemas "public" and "analytics"
  each with 5 tracked tables
```

### `run_sql` with `"schema"` field

| Test | Action | Assert |
|---|---|---|
| CREATE TABLE is visible after partial rebuild | `run_sql` `CREATE TABLE analytics.events (id int)` with `"schema":"analytics"` | GQL introspection shows `analytics_events` |
| DROP TABLE is reflected after partial rebuild | `run_sql` `DROP TABLE analytics.events` with `"schema":"analytics"` | `analytics_events` absent from introspection |
| Other schema untouched | Same CREATE as above | `public.*` tables unchanged and still queryable |
| Omitting `"schema"` still works (fallback path) | Same `run_sql` without `"schema"` key | Full rebuild fires; result is still correct |
| `"schema"` mismatch (wrong schema specified) | `CREATE TABLE public.foo` but `"schema":"analytics"` | `public_foo` NOT reflected (known limitation; document it) |

### Cache consistency after multiple operations

| Test | Sequence | Assert |
|---|---|---|
| Two successive partial rebuilds on different schemas | CREATE in `analytics`, then CREATE in `reporting` | Both tables visible; `public` unchanged |
| Partial rebuild then full reload | Partial rebuild on `analytics`, then `reload_metadata` | All schemas consistent |

---

## 3. Incremental Pipeline Tests — `Inc.cache` behaviour

**Location:** `server/lib/incremental/test/Hasura/IncrementalSpec.hs`

These tests verify that `Inc.keyed` actually skips re-running untouched schema blocks. Use `Inc.trackAccesses` or a counter ref to confirm memoisation.

| Test | Setup | Assert |
|---|---|---|
| Changing schema A's key does not re-run schema B's `buildTableCacheForSchema` | Two schemas, increment only schema A's `InvalidationKey` | Schema B's arrow block fires 0 times on the second run |
| Changing schema A's key DOES re-run schema A | Same | Schema A's block fires once on second run |
| Full-source invalidation re-runs all schema blocks | Increment source-level key | All schema blocks fire once |

---

## 4. Benchmark

**Location:** `server/bench/` or a standalone cabal benchmark target

```
fixture:
  1 Postgres source
  5 schemas × 50 tracked tables = 250 tables total
```

| Metric | Baseline (full rebuild) | Target (partial rebuild) |
|---|---|---|
| `p50` latency of `run_sql` DDL touching 1 schema | measured | ≤ 1/5 of baseline |
| `p99` latency | measured | proportional to 1 schema (50 tables), not 5 |
| Postgres catalog queries fired | 1 (all 250 tables) | 1 (50 tables for the target schema) |

Run with `criterion` or `tasty-bench`; output a comparison table before/after the feature flag.

---

## 5. Regression Checklist

Before merging, manually verify these in a dev instance:

- [ ] `track_table`, `untrack_table`, `create_object_relationship`, `drop_permission` — all use the old `buildSchemaCacheFor` path and are unaffected
- [ ] `reload_metadata` still triggers a full `buildSchemaCacheWithInvalidations` (no regression in `ciSourceSchemas`)
- [ ] A `run_sql` with no `"schema"` key falls back to full-source invalidation (not a panic/error)
- [ ] Non-Postgres backends (MSSQL, BigQuery, DataConnector) hit the `tableNameSchema _ = publicSchema` default and produce a single-bucket partition — no crash

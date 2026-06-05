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

**Location:** `server/bench/SchemaCacheRebench.hs` (new cabal benchmark target in `graphql-engine.cabal`)

```
fixture:
  1 Postgres source
  5 schemas × 200 tracked tables = 1000 tables total
```

The 200-table-per-schema size is intentional: it makes the catalog query cost dominate so
the difference between partial and full rebuild is unambiguous in wall-clock time.

---

### Step 1 — SQL fixture

Create and populate the fixture schemas before running the benchmark.
Save this as `server/bench/fixtures/schema_cache_bench_setup.sql`:

```sql
-- Run once against the benchmark Postgres instance.
-- Idempotent: safe to re-run.
DO $$
DECLARE
  s text;
  i int;
BEGIN
  FOREACH s IN ARRAY ARRAY['s1','s2','s3','s4','s5'] LOOP
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', s);
    FOR i IN 1..200 LOOP
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I.tbl_%s (id serial PRIMARY KEY, payload text)',
        s, i
      );
    END LOOP;
  END LOOP;
END$$;
```

And the matching teardown `server/bench/fixtures/schema_cache_bench_teardown.sql`:

```sql
DROP SCHEMA IF EXISTS s1, s2, s3, s4, s5 CASCADE;
```

---

### Step 2 — Track all 1 000 tables via the Metadata API

Before timing anything, all 1 000 tables must be tracked so `buildTableCache` has real work.
Run this shell script once against a running Hasura instance:

```bash
#!/usr/bin/env bash
# server/bench/fixtures/track_tables.sh
# Usage: HASURA_URL=http://localhost:8080 HASURA_ADMIN_SECRET=secret bash track_tables.sh

set -euo pipefail
URL="${HASURA_URL:-http://localhost:8080}"
SECRET="${HASURA_ADMIN_SECRET:-}"
HDR=(-H "X-Hasura-Admin-Secret: $SECRET" -H "Content-Type: application/json")

for schema in s1 s2 s3 s4 s5; do
  for i in $(seq 1 200); do
    curl -s -o /dev/null -w "%{http_code}\n" "${HDR[@]}" \
      -d "{\"type\":\"pg_track_table\",\"args\":{\"source\":\"default\",\"table\":{\"schema\":\"$schema\",\"name\":\"tbl_$i\"}}}" \
      "$URL/v1/metadata"
  done
  echo "tracked $schema"
done
```

---

### Step 3 — Enable pg_stat_statements for query counting

Add to `postgresql.conf` (or pass as a flag to the benchmark Postgres instance):

```
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
```

Then create the extension once:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Before each benchmark run, reset the counters:

```sql
SELECT pg_stat_statements_reset();
```

After the run, count catalog queries fired by `fetchTableMetadata` / `resolveDatabaseMetadataForSchemas`:

```sql
SELECT calls, mean_exec_time, query
FROM pg_stat_statements
WHERE query ILIKE '%pg_catalog.pg_class%'
   OR query ILIKE '%hdb_catalog%'
ORDER BY calls DESC
LIMIT 10;
```

**Expected:** full rebuild → catalog query touches all 1 000 tables; partial rebuild → query
touches only the 200 tables belonging to the target schema.

---

### Step 4 — Add the cabal benchmark target

Append to `server/graphql-engine.cabal` (after the last `test-suite` stanza):

```cabal
benchmark schema-cache-bench
  import:         common-all, common-exe, lib-depends
  type:           exitcode-stdio-1.0
  hs-source-dirs: bench
  main-is:        SchemaCacheRebench.hs
  build-depends:
      base
    , aeson
    , bytestring
    , http-client
    , http-client-tls
    , http-types
    , tasty-bench         >= 0.3
    , text
    , time
    , unliftio
```

---

### Step 5 — Write the benchmark module

Create `server/bench/SchemaCacheRebench.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (hContentType)
import System.Environment (lookupEnv)
import Test.Tasty.Bench (bench, bgroup, defaultMain, whnfIO)

-- | POST a JSON body to /v2/query and discard the response body.
runSQL :: HTTP.Manager -> String -> String -> Value -> IO ()
runSQL mgr baseUrl secret payload = do
  req0 <- HTTP.parseRequest (baseUrl <> "/v2/query")
  let req =
        req0
          { HTTP.method = "POST",
            HTTP.requestBody = HTTP.RequestBodyLBS (encode payload),
            HTTP.requestHeaders =
              [ (hContentType, "application/json"),
                ("X-Hasura-Admin-Secret", LBS.toStrict (encode secret))
              ]
          }
  _ <- HTTP.httpLbs req mgr
  pure ()

-- | Full-source rebuild: run_sql without the "schema" field.
fullRebuildSQL :: HTTP.Manager -> String -> String -> IO ()
fullRebuildSQL mgr url secret =
  runSQL mgr url secret $
    object
      [ "type" .= ("pg_run_sql" :: String),
        "args"
          .= object
            [ "source" .= ("default" :: String),
              "sql" .= ("SELECT 1" :: String), -- no-op DDL; forces a full rebuild
              "read_only" .= False
            ]
      ]

-- | Partial rebuild: run_sql with "schema":"s1" (touches only the 200 tables in s1).
partialRebuildSQL :: HTTP.Manager -> String -> String -> IO ()
partialRebuildSQL mgr url secret =
  runSQL mgr url secret $
    object
      [ "type" .= ("pg_run_sql" :: String),
        "args"
          .= object
            [ "source" .= ("default" :: String),
              "sql" .= ("SELECT 1" :: String),
              "schema" .= ("s1" :: String),
              "read_only" .= False
            ]
      ]

main :: IO ()
main = do
  url <- maybe "http://localhost:8080" id <$> lookupEnv "HASURA_URL"
  secret <- maybe "" id <$> lookupEnv "HASURA_ADMIN_SECRET"
  mgr <- newTlsManager
  defaultMain
    [ bgroup
        "schema-cache-rebuild (1 source, 5 schemas × 200 tables)"
        [ bench "full rebuild  (1000 tables touched)" $
            whnfIO (fullRebuildSQL mgr url secret),
          bench "partial rebuild (200 tables touched, schema=s1)" $
            whnfIO (partialRebuildSQL mgr url secret)
        ]
    ]
```

---

### Step 6 — Run the benchmark

```bash
# 1. Start Postgres and Hasura with the fixture (see Steps 1–2).

# 2. Build and run the benchmark (outputs a tasty-bench comparison table).
cabal bench schema-cache-bench \
  --benchmark-options='+RTS -T -RTS --csv bench-results.csv'

# 3. Environment variables forwarded to the benchmark binary:
HASURA_URL=http://localhost:8080 \
HASURA_ADMIN_SECRET=secret \
  cabal bench schema-cache-bench
```

---

### Step 7 — Interpret results

| Metric | Baseline (full rebuild) | Target (partial rebuild) | Pass? |
|---|---|---|---|
| `p50` latency of `run_sql` on 1 schema | measured | ≤ 1/5 of baseline | check |
| `p99` latency | measured | ≤ 1/5 of baseline | check |
| Postgres catalog rows scanned | ~1 000 (all tables) | ~200 (s1 only) | check |
| `pg_stat_statements` query count for `pg_catalog.pg_class` | 1 wide scan | 1 narrow scan | check |

The `tasty-bench` output prints a speedup ratio directly (e.g. `0.19x` means ~5× faster, i.e.
the partial rebuild processes 1/5 of the tables). Any ratio above `0.30x` (i.e. less than
3.3× faster) warrants investigation — it likely means `buildGQLContext` or a non-catalog
cost is dominating and the Phase 6 optimisation should be prioritised.

---

## 5. Regression Checklist

Before merging, manually verify these in a dev instance:

- [ ] `track_table`, `untrack_table`, `create_object_relationship`, `drop_permission` — all use the old `buildSchemaCacheFor` path and are unaffected
- [ ] `reload_metadata` still triggers a full `buildSchemaCacheWithInvalidations` (no regression in `ciSourceSchemas`)
- [ ] A `run_sql` with no `"schema"` key falls back to full-source invalidation (not a panic/error)
- [ ] Non-Postgres backends (MSSQL, BigQuery, DataConnector) hit the `tableNameSchema _ = publicSchema` default and produce a single-bucket partition — no crash

# RFC — Per-(Source, DB-Schema) GraphQL Contexts (selected per request)

> **Three phases.**
> **Phase 1 — Per-(source, schema) GraphQL contexts** (§§1–10): split the single global served
> schema into one independently-built/cached `GQLContext` per `(source, schema)`, selected per
> request. Delivers O(changed schema) context assembly.
> **Phase 2 — Per-(source, schema) metadata storage** (§11): partition metadata storage by
> `(source, schema)` to remove the blob serialize/write residual and enable concurrent per-schema
> writes. Strictly follows Phase 1.
> **Phase 3 — Per-(source, schema) source resolution** (§12): partition `buildSource` (relationship /
> permission / dependency resolution) per `(source, schema)` to remove the **dominant** O(total)
> rebuild residual that Phases 1–2 leave untouched. Strictly follows Phase 1.

## 1. Summary (Phase 1)

Replace the single, global served GraphQL schema with **N independent GraphQL schemas,
one per `(source, DB schema)` pair**. Each pair (e.g. `default.s1`, `default.s5`,
`otherSource.public`) gets its own `GQLContext` (query/mutation/subscription parsers + its
own introspection universe), built and cached independently. A request selects which
`(source, schema)` it targets via headers; configurable env vars pick the default.

This is **not** an attempt to make the global assembly incremental — it removes the global
object entirely. See `phase7-incremental-gql-context-assembly.md` §12.4–§12.7 for why a
single global schema's assembly is intrinsically O(total). This RFC changes the requirement:
we no longer need one unified API across sources/schemas.

## 2. Locked decisions (from product owner)

1. **No actions, remote schemas, or action custom types.** Not used in this deployment. ⇒
   each context is *purely* the tables of one `(source, schema)`; there is no global,
   non-schema blob to place anywhere. This also dead-codes the action/remote-schema branches
   of `assembleGQLContext`.
2. **Multiple sources are used.** The unit of a served schema is `(SourceName, SchemaName)`,
   not just `SchemaName`. Two different sources may legitimately reuse a DB-schema name (e.g.
   both have `public`); they are distinct contexts.
3. **Relationships are always within a single `(source, schema)`.** No relationship, remote
   relationship, or query crosses source or schema boundaries. ⇒ every context is
   self-contained; nothing to merge or cross-validate.
4. **A request targets exactly one `(source, schema)`.** When the selector is omitted, fall
   back to the configured default.
5. **Full replacement.** The global/merged serving path is removed (no long-lived feature
   flag); admin-only, no Relay/Federation/permissions.

Because of (1)+(3), the expensive global step — `buildIntrospectionSchema`
(`collectTypeDefinitions` over the *whole* type universe + cross-schema conflict detection,
~88% of assembly, measured) — is replaced by N small per-pair collects, each over one
schema's tables. A mutation to `(src, X)` re-assembles **only that pair**.

## 3. Target architecture

### 3.1 Build path (today → proposed)

```
TODAY:    per-(source,schema) parsers ──union(mergedParsers)──► assembleGQLContext (ALL) ──► 1 GQLContext
PROPOSED: per-(source,schema) parsers ──(no union)──► assembleGQLContext (per pair) ──► HashMap (SourceName,SchemaName) GQLContext
```

- Drop the `mergedParsers` union.
- Run `assembleGQLContext` once **per `(source, schema)`**, over that pair's
  `SchemaFieldParsers` only. With decision (1) the action/remote inputs are empty, so the
  context is just the table query/mutation/subscription parsers + that pair's introspection
  universe. With decision (3) there are no dangling cross-pair references, so each context is
  complete and valid alone.
- Cache each pair's `GQLContext` under the **same per-`(source,schema)` fingerprint** the
  Phase 6 parser cache already uses ⇒ only the changed pair re-assembles.

### 3.2 Serve path

```
request ─► resolve target (source, schema)  [headers │ env default]
        ─► look up GQLContext for (role, source, schema)
        ─► run that pair's parser  (introspection returns only that schema's types)
```

## 4. Request-time routing

Headers are needed **only for introspection**. Data operations are routed by name.

- **Data operations (query / mutation / subscription):** no header. Root-field and type names
  are made globally unique and self-identifying via Hasura's source customization /
  naming convention (root-field & type-name prefix/suffix encoding `source` + `schema`). At
  serve time the router reads the operation's top-level field names, looks them up in a
  `rootFieldName → (source, schema)` index built at schema generation, and dispatches to that
  pair's `GQLContext`. All root fields in one operation map to the same pair (guaranteed by
  decision 3); a field unknown to every pair → GraphQL error.
- **Introspection (`__schema` / `__type`):** references no schema-specific field, so the pair
  cannot be inferred. Requires `X-Hasura-Source` / `X-Hasura-Schema`, falling back to
  `HASURA_GRAPHQL_DEFAULT_SOURCE` / `HASURA_GRAPHQL_DEFAULT_SCHEMA` (and, if unset, the first
  pair alphabetically). The selected pair's context already contains only that schema's types,
  so `__schema` returns exactly one schema — no change inside `Schema/Introspect.hs`.
- **Meta-only operations** (`__typename`-only, etc.): treat as introspection (header/default).

**Prerequisite (config):** type/root-field naming must uniquely encode `(source, schema)` —
configured via source `customization` (`root_fields` / `type_names` prefix/suffix) or
`naming_convention`. Without it two pairs could mint the same root-field name and the router
could not disambiguate. Validate at boot: the same name mapping to two pairs in the routing
index is a configuration error to surface.

This also affects **metadata vs GraphQL** calls: `/v1/metadata` and `/v2/query` never use a
`GQLContext` (they carry `source`/`schema` in their JSON args and operate on Metadata/DB
directly), so they need no header and are unaffected. Only the GraphQL endpoints route, and only
their introspection requests consult the header.

## 5. Code impact (file by file, grounded)

### 5.1 Storage — `server/src-lib/Hasura/RQL/Types/SchemaCache.hs` (lines 578–581) — **CORE CHANGE**
```haskell
-- today
scGQLContext              :: HashMap RoleName (RoleContext GQLContext)
scUnauthenticatedGQLContext :: GQLContext
-- proposed (key by source+schema; admin-only keeps the RoleName map trivial)
scGQLContext              :: HashMap RoleName (HashMap (SourceName, SchemaName) (RoleContext GQLContext))
scUnauthenticatedGQLContext :: HashMap (SourceName, SchemaName) GQLContext
-- routing index for header-less data-op dispatch (§4, §5.2)
scRootFieldSchema         :: HashMap G.Name (SourceName, SchemaName)
```
Highest-blast-radius edit: the `toJSON` instances (607–608) and every read site update. The
Relay fields (580–581) are off here and can be left dormant or deleted.

### 5.2 Assembly — `server/src-lib/Hasura/GraphQL/Schema.hs`
- `buildGQLContext` (~160–268): currently returns one `RoleContext GQLContext` per role from
  `mergedParsers`. Change to return `HashMap RoleName (HashMap (SourceName,SchemaName) (RoleContext GQLContext))`
  by mapping `assembleGQLContext` over the **per-pair** parsers.
- `assembleGQLContext` (367): **already takes a `SchemaFieldParsers`** — feed it one pair's
  parsers. With decision (1), `actions`/`remotes`/`customTypes` arguments are empty, so the
  `runActionSchema` / `runRemoteSchema` / `buildAndValidateRemoteSchemas` blocks (lines
  ~408–426) collapse to no-ops and can be elided — a real simplification. The introspection
  build now walks one schema's tables; the `safeSelectionSet` duplicate-name check spans one
  pair only.
- `partitionSourceBySchema` (493), `buildAllRoleParsersForSchema` (635): unchanged — already
  per-`(source,schema)`.
- **Routing index (new gen-time artifact):** while assembling each pair, collect its root-field
  names (from `_sfpQuery` / `_sfpMutFrontend` / `_sfpMutBackend` / `_sfpSubscription`
  `fDefinition` names) into a global `HashMap G.Name (SourceName, SchemaName)`. A name already
  present (mapped to a *different* pair) is a naming-convention misconfiguration → surface as an
  inconsistency. Stored in `SchemaCache` (§5.1) for the serve-time router.

### 5.3 Caching / incremental boundary — `server/src-lib/Hasura/RQL/DDL/Schema/Cache.hs` — **WHERE THE WIN IS**
- `mergedParsers` (~675): remove the union; keep the per-`(source,schema)` map.
- `buildSchemaParsersForSchema` (`Inc.cache`, ~986/1007): extend each per-`(source,schema)`
  node to also produce + cache that pair's **assembled `GQLContext`** alongside its parsers,
  under the same key. A mutation to `(src,X)` then recomputes only X's parsers *and* context;
  all other pairs are `Inc.cache` hits. Reuses the Phase 6 incremental boundary directly.
- `buildGQLContextCached` / `gqlContextCacheKey` (~687, type ~2051): the single global context
  cache (keyed on whole `Metadata`) is **removed**; each pair keys on its own fingerprint.

### 5.4 Request routing — `server/src-lib/Hasura/GraphQL/Execute.hs` — **CORE CHANGE**
- **Resolve the target pair** in `getResolvedExecPlan` (344), which already has both the parsed
  operation and **`reqHeaders` in scope** (382):
  - *Data op:* take the operation's top-level root-field names, look them up in the gen-time
    routing index (§5.2) → `(source, schema)`. (Validate they all agree; unknown → error.)
  - *Introspection / meta-only op:* read `(source,schema)` from `reqHeaders`, else env default.
- `makeGQLContext` (80): currently `UserInfo -> SchemaCache -> GraphQLQueryType -> GQLContext`
  with a one-level `HashMap.lookup role`. Add a `(SourceName, SchemaName)` argument and do a
  two-level lookup `role -> (source,schema) -> RoleContext`, with the per-pair unauthenticated
  context as fallback. (Admin-only ⇒ the role layer is effectively a single entry.) Called at
  Execute.hs:390 and `Hasura/GraphQL/Explain.hs` (115) — both pass the resolved pair.

### 5.5 Subscriptions / WebSocket
- The WS transport (`Hasura/GraphQL/Transport/WebSocket*`) resolves the plan per operation; the
  target `(source,schema)` must come from the connection-init payload or per-op headers and be
  threaded into the same `makeGQLContext` call. WS exec path still to be traced.

### 5.6 Config / env — `server/src-lib/Hasura/Server/Init/{Config,Arg/Command/Serve,Env}.hs`
- Add `HASURA_GRAPHQL_DEFAULT_SOURCE` and `HASURA_GRAPHQL_DEFAULT_SCHEMA` (+ CLI flags) →
  `ServeOptions` → available to the transport layer that resolves the request target. Build-time
  config does not need them; only serving does.

### 5.7 Header constants — `server/src-lib/Hasura/Authentication/Session.hs` (54–66)
- Register `x-hasura-source` / `x-hasura-schema` near the other `x-hasura-*` constants, or parse
  them as plain transport headers from `reqHeaders` (no Session change).

### 5.8 Likely unchanged
- `Hasura/GraphQL/Context.hs` (`GQLContext`, `RoleContext`) — reused as-is.
- `Schema/Introspect.hs`, `schema-parsers` — unchanged; per-pair scoping is routing, not parsing.

## 6. Performance expectation

| Operation | Today | Proposed |
|---|---|---|
| Mutation to `(src,X)` (assembly) | O(total): ~526 ms eager (all schemas) | O(X): only that pair re-assembled |
| Introspection build | whole universe (~465 ms) every rebuild | one pair's universe, only when it changes |
| Startup | 1 global assembly | N per-pair assemblies (parallelizable; total ≈ same) |

Per-mutation assembly finally scales with the **changed** pair — the goal Phase 7 could not
reach without this requirement change. One O(total) residual remains — rewriting and re-parsing
the single metadata blob on every mutation — removed by **Phase 2 (§11)**.

## 7. Tradeoffs / risks

- **No cross-source / cross-schema queries in one request** (accepted — decisions 3–4).
- **Clients must send `X-Hasura-Source` + `X-Hasura-Schema`.** Tooling introspects one pair at a
  time; document the headers. Omitted → default; unknown → error.
- **Memory:** N contexts instead of 1. Shared types (scalars, `*_comparison_exp`, `order_by`)
  duplicate across pairs, so resident types ≈ Σ(per-pair) > union. Modest; measure on the real
  dataset.
- **Blast radius:** `scGQLContext`'s type change ripples to all read sites + JSON instances;
  `makeGQLContext`'s new argument ripples to its 2 callers + the WS path.
- **Full replacement** means no fallback path: tooling/console/metadata-API features that assumed
  one global schema must become pair-aware before cutover.

## 8. Rollout (full replacement)

Per decision (5) the global path is removed rather than flagged long-term. Suggested safe
sequence so the large `SchemaCache` change still lands reviewably:
1. Land the storage + build changes producing the per-pair map, but keep a thin shim that still
   answers requests from a chosen default pair (parity check).
2. Switch `makeGQLContext` + transport to header-based selection; delete the merged path.
3. **Correctness gate:** for each pair, its introspection SDL must equal the subset of the old
   global SDL restricted to that pair's types.
4. **Perf gate:** a small-schema mutation's assembly drops from ~526 ms to tens of ms.

## 9. Resolved questions

| # | Question | Decision |
|---|---|---|
| 1 | Actions / remote schemas / custom types | Not used — no global blob; dead-code those branches |
| 2 | Multiple sources | Yes — key/select by `(source, schema)` |
| 3 | No selector behavior | Fall back to configured default `(source, schema)` |
| 4 | Replace vs flag | Full replacement of the global path |

Residual (non-blocking) confirmations:
- **Default when env unset:** first `(source,schema)` alphabetically vs hard startup error?
- **Selector transport:** `X-Hasura-Source`/`X-Hasura-Schema` headers only, or also distinct
  paths like `/v1/graphql/<source>/<schema>`?
- **Relay:** confirmed off — delete the dormant Relay context fields, or leave them?

## 10. Effort

High but mechanically bounded. The two invasive edits are (i) the `SchemaCache` context field
type + its read sites and JSON instances, and (ii) `makeGQLContext`'s new `(source,schema)`
argument across callers + the WS path. The build side (per-pair assembly + caching) reuses the
Phase 6 incremental machinery and is *simplified* by decision (1) (no action/remote assembly).
Recommend: prototype the per-pair build + cache first (build side, lowest risk, immediately
benchmarkable), then the storage/serving cutover.

---

## 11. Phase 2 (follow-on) — Per-(source, schema) metadata storage

Phase 1 makes the GQL build O(changed schema), but a metadata mutation still **rewrites and
re-parses the single global metadata blob** — the last O(total) factor (§6/§7 residual). Phase 2
partitions metadata *storage* by `(source, schema)` so a track touches only its row → truly
O(changed) end-to-end, and per-schema writes stop contending on one row.

### 11.1 Storage model

Today: `hdb_catalog.hdb_metadata` is **one row** `(id, metadata json, resource_version)` holding the
whole `Metadata` (`Metadata.hs:145`, `_metaSources :: Sources`; tables live flat under
`SourceMetadata._smTables`, `Common.hs:134`, keyed by qualified name so the schema is derivable).

Proposed:
- **`hdb_catalog.hdb_metadata_partition (source_name text, schema_name text, partition jsonb,
  resource_version int, PRIMARY KEY (source_name, schema_name))`** — each row is that schema's slice
  of `SourceMetadata` (its `_smTables`/`_smFunctions`/… filtered to the schema, split exactly as
  `partitionSourceBySchema` does for `SourceInfo`).
- A small **skeleton** (keep `hdb_metadata`): `Metadata` minus the per-schema table groups — source
  list + connection config + settings (+ the here-empty actions/remotes/custom types). O(sources).

### 11.2 Operations (`MonadMetadataStorage`, `Class.hs:97`)

- Add scoped `fetchSchemaMetadata (source,schema)` / `setSchemaMetadata (source,schema) version
  partition`.
- `fetchMetadata` (boot / `export_metadata`): read skeleton + all partitions, reassemble `Metadata`
  — O(total), acceptable off the hot path.
- `setMetadata` / `replace_metadata`: re-partition the incoming `Metadata` into rows (full rewrite;
  used only by replace/import).
- **Schema-scoped mutations** (`track_table`, `untrack_table`, within-schema permission/relationship)
  write **only** the affected partition → O(changed).

### 11.3 Concurrency / versioning

- Replace the single `resource_version` with **per-partition versions** + a global generation counter
  for the in-memory cache.
- `fetchMetadataNotifications` / `CacheInvalidations` become **partition-aware**: a write records
  which `(source,schema)` changed so other instances invalidate just that partition (multi-instance
  correctness).
- Multi-partition ops (`replace_metadata`; any cross-schema op — none here per decision 3) update
  rows in one transaction.

### 11.4 Inc-framework tie-in (`Cache.hs`)

The per-partition `resource_version` becomes the natural per-`(source,schema)` invalidation key,
replacing/strengthening today's content fingerprint `schemaContentKey` (`Cache.hs:634`, computed by
hashing the resolved `SourceInfo`). Downstream nodes already key per `(source,schema)` —
`buildTableCacheForSchema` (`:950`), `buildSchemaParsersForSchema` (`:1007`), and the Phase-1 per-pair
context cache — so this closes the loop: **storage → invalidation → build are all per-schema**.

### 11.5 Code impact

1. `Hasura/Metadata/Class.hs` — add scoped `fetch/setSchemaMetadata`; keep whole-metadata methods for
   boot / export / replace.
2. `Hasura/RQL/DDL/Schema/Catalog.hs` — SQL for the partition table; per-partition read/write;
   reassembly + repartition queries.
3. `Hasura/Server/Migrate.hs` — catalog migration: create the partition table and migrate the existing
   single blob into partitions (one-time, O(total)).
4. `Hasura/RQL/Types/Metadata.hs` / `Metadata/Common.hs` — `splitMetadataBySchema` / `reassembleMetadata`
   helpers (group `_smTables` etc. by the schema component of the qualified name).
5. `Hasura/Server/API/Metadata.hs` (RQL handlers) — route schema-scoped operations to
   `setSchemaMetadata` instead of whole `setMetadata`. **Main behavioral change.**
6. Concurrency / notifications — per-partition `resource_version` + partition-aware `CacheInvalidations`.

### 11.6 Tradeoffs / risks

- **Concurrency model change** (single → per-partition version) is the riskiest part; optimistic
  concurrency and multi-instance invalidation must remain correct.
- **Atomicity** for multi-schema ops (`replace_metadata`) needs a transaction over rows.
- **Migration** of the existing blob; `export`/`replace_metadata` must stay semantically byte-equivalent
  (reassemble == old blob).
- **Bounded immediate payoff:** at 2000 tables the blob write is ~tens of ms, so the absolute saving is
  small. The value is (a) removing the last O(total) factor (truly O(changed) tracks), (b) **concurrent**
  per-schema metadata writes, (c) scaling past the single-blob serialization/row-size ceiling at 10k+
  tables.

### 11.7 Sequencing

Strictly **after** Phase 1 (depends on the per-`(source,schema)` decomposition existing). Independent of
the serving cutover; can land last.

### 11.8 Implementation plan (approved)

Decisions: **full §11.3 concurrency** (per-partition `resource_version` + the existing
`hdb_metadata.resource_version` as a global generation counter + partition-aware `CacheInvalidations`) and
**diff-based write routing** (every write re-partitions the new in-memory `Metadata` and UPSERTs only the
partitions whose content changed, deleting removed ones — correct for all operations, no per-command
special-casing).

**Storage.** Keep `hdb_catalog.hdb_metadata` as the **skeleton** (full `Metadata` with each source's
`_smTables`/`_smFunctions`/`_smStoredProcedures` emptied; everything else stays); its `resource_version`
becomes the global generation counter. Add `hdb_catalog.hdb_metadata_partition (source_name text,
schema_name text, partition jsonb, resource_version int DEFAULT 1, PRIMARY KEY (source_name, schema_name))`,
one row per `(source, schema)`. Native queries / logical models (no schema component) stay in the skeleton.

**Split / reassemble** — new `Hasura/RQL/Types/Metadata/Partition.hs`, reusing the `BackendMetadata` methods
`tableNameSchema`/`functionNameSchema` (`Backend.hs:279,284`) exactly as `partitionSourceBySchema`
(`GraphQL/Schema.hs:624`): `splitSourceMetadataBySchema`, `splitMetadataBySchema :: Metadata -> (Metadata,
[(SourceName, SchemaName, Value)])` (per-source `AB.dispatchAnyBackend`), `reassembleMetadata`. Export stays
byte-equivalent for free (codec sorts collections, `Common.hs:219`).

**Catalog** (`RQL/DDL/Schema/Catalog.hs`): `fetchMetadata*` read skeleton + partitions and reassemble;
`setMetadataInCatalog` becomes the diff write (split → compare by content hash → UPSERT changed with
`resource_version+1`, DELETE removed, write skeleton, bump global version) returning `(MetadataResourceVersion,
HashSet (SourceName, SchemaName))`; `insertMetadataInCatalog` seeds skeleton + partitions.

**Notifications** (`App.hs:829`): `updateMetadataAndNotifySchemaSync` unions the returned changed pairs into
`CacheInvalidations.ciSourceSchemas` (`SchemaCache/Build.hs:230`). No new `MonadMetadataStorage` methods —
diffing lives inside the catalog tx.

**Migration** (`Server/Migrate.hs` + `src-rsr/`): bump `catalog_version.txt` 48→49; `48_to_49.sql` creates
the table; custom `from48To49` (model on `from42To43`) splits the existing blob into partitions and rewrites
the skeleton; `49_to_48.sql` + `from49To48` reassemble and drop the table.

---

## 12. Phase 3 (follow-on) — Per-(source, schema) source resolution

Phases 1, 2 and the earlier Phase 6 (per-schema parser cache) all partition the layers *around* source
resolution but leave the resolution itself global. With those in place, a metadata mutation's wall-time is
**dominated by a residual that scales with the total number of tracked tables, not the changed schema** — the
opposite of the project's goal.

### 12.1 Evidence (measured)

On the 1302-table / 6-schema dev catalog, decomposing a mutation:
- `export_metadata` (fetch + reassemble + serialize): **~30 ms** — metadata I/O is *not* the floor (so Phase 2
  storage was never the bottleneck for latency).
- Tracking a table in the 2-table `public` schema: **~2.5 s at 1302 tracked tables**, but **~30 ms after
  dropping the other ~1300 tables from metadata**. Same changed schema, ~100× difference ⇒ the cost is work
  over the *other* tables: the rebuild floor is **O(total tracked tables)**, independent of which schema changed.
- A full `reload_metadata`: 5–8 s.

### 12.2 Root cause

The schema-cache build has three layers; only the first two are partitioned per schema:

| Layer | Function | Partitioned? |
|---|---|---|
| Table **core** info (columns) | `buildTableCacheForSchema` (`Cache.hs:993`) | ✅ per schema (Phase 6) |
| GQL **parsers + context** | `buildSchemaParsersForSchema` / `assembleSchemaContextForSchema` | ✅ per pair (Phase 1 / §5.3) |
| **Source resolution** | `buildSource` (`Cache.hs:1191`, called `:1714`) + `resolveDependencies` (`Cache.hs:562`) | ❌ whole-source / whole-metadata, **uncached** |

`buildSource` is a plain `proc` inside an `Inc.keyed` over *sources* (not schemas). It rebuilds, for **every
table** of the source on every rebuild: relationships / computed fields (`addNonColumnFields`), permissions
(`buildTablePermissions`), and the `TableInfo`/`FieldInfoMap` records. `resolveDependencies` then resolves the
whole-metadata dependency graph. Even with trivial tables (no relationships/permissions), constructing 1302
`TableInfo`s over several passes every rebuild costs seconds. This is the floor.

### 12.3 Proposed change

Partition `buildSource` per `(source, DB schema)` and `Inc.cache` it under the **same per-`(source,schema)`
key** already used by `buildTableCacheForSchema` and `buildSchemaParsersForSchema` — i.e. lift the Phase-6 move
up one layer. A mutation to `(src, X)` then re-resolves only X's `TableInfo`s; every other schema's resolved
slice is a cache hit. Concretely:
- In `buildAndCollectInfo` (`Cache.hs:1550`), the `sourcesOutput` `Inc.keyed` loop (`:1696`) currently calls
  `buildSource` once per source. Replace with a per-schema `Inc.keyed` (reusing `partitionSourceBySchema`'s
  schema grouping and the `_ikSourceSchemas` invalidation key) that builds + caches each schema's
  `TableInfo`s independently, then `HashMap.unions` the slices into the source's `tableCache` (cheap), exactly
  as `tablesCoreInfo` is already assembled at `:1660`.
- Scope `resolveDependencies` per `(source, schema)` (or at minimum make its per-object work cache per schema),
  so the dependency graph for an unchanged schema is not re-resolved.

### 12.4 Why this is safe

Relies on the same **locked decision 3** as Phase 1: *relationships are always within a single `(source,
schema)`* (and decision: no cross-source relationships). With no cross-schema/cross-source references, each
schema's `TableInfo`s — including `addNonColumnFields` and `buildTablePermissions` — depend only on that
schema's tables, so they can be resolved and cached independently. The two-pass "resolve sources, then build
cross-source relationships" structure (`Cache.hs:1694`) becomes a no-op across pairs and collapses to a single
per-schema pass.

### 12.5 Risks

- **Cross-schema / cross-source relationships or permissions** would break per-schema isolation. They are
  disallowed here by decision 3, but the partitioning must **validate** the invariant and surface a violation
  as an inconsistency rather than silently serving a stale slice.
- **`resolveDependencies`** scoping is the subtler half; if left global it remains an O(total) residual (likely
  smaller than `buildSource`, but measurable). Confirm with the same scaling test after partitioning `buildSource`.
- **`addNonColumnFields` takes `allSources`** (`Cache.hs:1205`) for cross-source relationship resolution; the
  per-schema version must pass only the relevant slice and rely on decision 3 to guarantee completeness.

### 12.6 Code impact

- `Hasura/RQL/DDL/Schema/Cache.hs` — partition the `sourcesOutput` loop (`:1696`) and `buildSource` (`:1191`)
  per schema; add a `buildSourceForSchema` `Inc.cache` node keyed on `(source, schema)` (mirror
  `buildTableCacheForSchema`); thread the `_ikSourceSchemas` key already in scope.
- `Hasura/RQL/DDL/Schema/Cache/Dependencies.hs` — per-`(source,schema)` dependency resolution.
- Reuses `partitionSourceBySchema` (`GraphQL/Schema.hs:624`) / `partitionIntrospectionBySchema` and the
  `tableNameSchema`/`functionNameSchema` primitives.

### 12.7 Expected payoff

This is the change that actually moves the wall-time: per the §12.1 scaling test, a small-schema mutation
should fall from **~2.5 s toward the ~30 ms** observed at 2 tracked tables — finally making the *whole* mutation
path (storage + build) O(changed schema). Independent of Phase 2; depends only on Phase 1's decisions.

### 12.8 Prototype result — corrected root cause

The §12.3 change was prototyped (`buildTableInfosForSchema` + per-schema `sourcesOutput` loop + slimmed
`buildSource`). It **builds cleanly and is correct** (per-schema GraphQL schema matches metadata, no
inconsistencies) but **did not move the floor**: tracking a table in `public` stayed ~2.5–3.0 s at 1302 tracked
tables (still ~30 ms at 2 tables). The prototype thus **falsified the §12.2 hypothesis that `buildSource`
dominates.**

Why: the benchmark tables have **no relationships or permissions**, so `buildSource`'s per-table work
(`addNonColumnFields` / `buildTablePermissions`) was already trivial. Partitioning trivial work changes
nothing. `buildSource` partitioning is still a correct structural improvement (it would help
relationship/permission-heavy schemas), but it is not the bottleneck for this workload.

**Corrected suspects for the O(total) floor** (both run on every rebuild regardless of which schema changed,
and neither is per-schema):
1. **`resolveDependencies`** (`Cache.hs:562`). The per-schema cached nodes *replay* their collected
   `CollectItem` dependencies via `ArrowWriter` on every rebuild, so the dependency `Seq` is rebuilt O(total)
   and resolved O(total) each time — independent of `buildSource`.
2. **The global GQL finalization kept in §5.3's `buildGQLContextCached`** — on every mutation it re-runs
   `mergeSchemaIntrospections` (HashMap-unions the introspection universe of *all* tables — many types each)
   and `buildRootFieldIndex` (over *all* root fields). Both are O(total) per mutation.

**Next step:** add lightweight phase timing to `buildSchemaCacheRule` to split
`buildAndCollectInfo` / `resolveDependencies` / GQL-finalization, then partition whichever dominates (strong
prior: the GQL finalization). The `buildSource` partitioning above is retained as a correct, low-risk
improvement but is not on the critical path for trivial-schema workloads.

### 12.9 Phase-timing investigation — corrected (again): it's the GQL schema build

Instrumented `runMetadataQuery` and `buildSchemaCacheRule` with forced wall-clock probes on the 1302-table dev
DB (a `track_table` on `public`, ~3 s total). Findings:

- **Phase 2 metadata write** (`updateMetadataAndNotifySchemaSync`, the diff write): **~0.02 s.** Not the cost —
  Phase 2 is fine.
- **`fetchMetadata`** (reassemble): ~0.03 s. Not the cost.
- **`resolveDependencies`** (`Cache.hs:562`): **~5 µs.** It is `arrM` (eager) and, with dependency-light tables
  (no FKs/relationships), prunes nothing. **Not the cost** — §12.8 suspect (1) is wrong.
- **GQL finalization** (`mergeSchemaIntrospections` + `buildRootFieldIndex`): merging 35 k introspection types
  ≈ 10 ms, routing index over 14 k root fields ≈ 20 ms. **~0.03 s.** §12.8 suspect (2) is wrong.
- **Spine-level** probes over `buildAndCollectInfo` / parser+context building summed to only ~0.38 s; but
  **deep-forcing the per-pair introspections jumped that phase to ~3.5 s.** And every `track` is ~3 s
  regardless of which schema changed.

**Conclusion:** the floor is the **GraphQL schema build itself** — per-pair parser + introspection
construction (`buildIntrospectionSchema`, the expensive ~88% step from §2) — done **O(total) per mutation**.
The Phase-1/§5.3 per-pair *context* cache is **not** preventing unchanged schemas' parser/introspection work
from being redone (or re-forced) on every mutation; that, not `buildSource`/`resolveDependencies`/storage, is
the real bottleneck.

**Limits of this method:** manual lazy-`evaluate` timing can only bound spines vs. deep values, not attribute
cleanly across thunks. Definitive attribution (parser-build vs. introspection-build; and *why* the per-pair
cache isn't saving the work across mutations — cache-key churn vs. lazy-thunk re-forcing) needs a **GHC
profiling build** (`cabal build --enable-profiling` + cost-centres + `+RTS -p`), which is the recommended next
step. The true Phase-3 win is to make the per-pair parser/introspection build effectively incremental across
mutations (cache hit ⇒ no rebuild *and* no re-force for unchanged pairs), not to partition `buildSource`.

### 12.10 GHC profiling result — definitive attribution: it's parser memoization

Ran the §12.9 recommended profiling build and captured a cost-centre time profile.

**Method.** Built `lib:graphql-engine` + `exe:graphql-engine` with `profiling: True`,
`profiling-detail: late-toplevel` (cabal.project.local). Ran the profiled server (`+RTS -p -RTS serve`)
against the dev DB (`…:25432/postgres`, 5 schemas × 200 tables tracked) and drove it with **`pg_track_table`**
mutations — 5 untrack/track cycles on `s1.tbl_1` (10 metadata mutations, each forcing a full schema-cache
rebuild). Each mutation took **~7 s** under profiling (≈2× the ~3 s un-profiled baseline). SIGINT → graceful
shutdown flushed `graphql-engine.prof`. **Total profiled run: 80.4 s, 36.5 GB alloc.**

**Flat profile — top cost centres by individual %time:**

| %time | Cost centre | Module |
|------:|-------------|--------|
| 15.8 | `gcompare` (MemoizationKey) | `Control.Monad.Memoize:221` |
|  4.2 | `$fApplicativeMemoizeT` | `Control.Monad.Memoize` |
|  4.1 | `$fFunctorMemoizeT` | `Control.Monad.Memoize` |
|  3.3 | `defaultTableSelectionSet` | `…Schema.Select:565` |
|  3.0 | `boolExpInternal` | `…Schema.BoolExp:101` |
|  2.9 | `buildIntrospectionSchema340` | `…Schema.Introspect` |
|  2.6 | `memoizeOn` | `Control.Monad.Memoize:148` |
|  2.4 | `columnParser` | `…Postgres.Instances.Schema:425` |

**By module (summed individual %time):**

- **`Control.Monad.Memoize` — 34.3%** (dominant)
- GQL schema/parser modules combined ≈ **30%**: `Schema.Introspect` 4.9, `Schema.BoolExp` 4.2,
  `Schema.Mutation` 3.9, `Schema.Update` 3.3, `Schema.Select` 3.3, `Schema.Common` 2.5,
  `Postgres.Instances.Schema` 2.4, `Schema.OnConflict` 2.0, `Schema.Update.Batch` 1.6, `Schema.Table` 0.7
- `Hasura.RQL.DDL.Schema.Cache` (storage/inc machinery): **0.8%**

**Conclusion (confirms §12.9, sharpened).** The floor is the GraphQL parser/introspection build, *not* storage,
`buildSource`, or `resolveDependencies` (Cache.hs ≈ 0.8%). The single hottest line is the **memoization
machinery** — `GCompare MemoizationKey.gcompare` (`Memoize.hs:221`) at **15.8% alone**, plus the
`MemoizeT` Functor/Applicative/Monad instances. Every memoized parser node keys a `Data.Dependent.Map` by
`(TH.Name, typeRep, arg, typeRep)`; with **O(total) parser nodes rebuilt per mutation**, these key comparisons
dominate. This is exactly the per-pair parser+introspection work being redone for *every* (source, schema)
on *every* mutation — the §5.3 context cache stores the assembled context but does not stop unchanged pairs'
parser trees from being rebuilt and re-memoized.

**Implication for the fix.** The Phase-3 win is to make the per-pair parser/introspection build incremental:
a cache hit for an unchanged (source, schema) must skip both the rebuild *and* the memoization traffic
(no `memoizeOn` / no `gcompare`). Partitioning `buildSource` or optimizing the `GCompare` instance are not the
lever — eliminating the redundant per-pair rebuilds is.

### 12.11 Root cause located — it's the deferred Relay context being force-built every mutation

§12.10's "implication" was **wrong about the remaining work**. Direct tracing + a profile of the *true pain
scenario* (a 2-table `public` mutation, which still costs ~3 s) shows the per-pair caches already work; the
floor is something else.

**Method.** Added two temporary `Debug.Trace` probes on the cache-*miss* paths (they fire only when the
`Inc.cache` actually re-executes): `PARSER-REBUILD-EXP` in `buildAllRoleParsersForSchema`
(`Schema.hs:777`) and `CONTEXT-ASSEMBLE-EXP` in `assemblePerPairContexts` (`Schema.hs:602`). Drove a single
untrack/track of `public.test1` against the 1302-table dev DB (public=2, s1=200, s2=100, s3=200, s4=200,
s5=600). Also captured a profile driving the `public` scenario specifically.

**Finding 1 — both per-pair caches already work.** A `public` mutation produced exactly **one**
`PARSER-REBUILD-EXP` (`nTables=2`) and **one** `CONTEXT-ASSEMBLE-EXP` (`nQueryFP=6`). The other 1300 tables
(s1–s5) hit both the parser cache *and* the per-pair context/introspection cache and were **not** rebuilt. So
the §12.9/§12.10 hypothesis — "unchanged pairs are rebuilt O(total) per mutation" — is **false** for the
Hasura per-pair schema. The §5.3 caching is doing its job.

**Finding 2 — yet the 2-table mutation is still ~3–4 s, with a parser/introspection-heavy profile** nearly
identical to the 200-table case (Memoize 32.7%, `gcompare` 15.7%, plus `buildIntrospectionSchema`,
`buildTable{Insert,Update,Delete}MutationFields`). So an O(total) parser+introspection build runs every
mutation **outside** both cached per-pair functions.

**Finding 3 — the call tree localizes it.** During each mutation:
`runMetadataQuery → buildSchemaCacheWithInvalidations → buildRebuildableSchemaCache → buildGQLContext`
(**33.7 % of the run**) `→ buildSchemaRoleParsers → buildMutationFields` (insert/update/delete for **all**
tables, 25.2 %) `+ buildIntrospectionSchema`. `buildGQLContext`'s body has no direct parser build — the only
routes to `buildSchemaRoleParsers` are its two `unsafeInterleaveIO`-deferred thunks: `relayContexts`
(`assembleRelayRoleContext`, `Schema.hs:825`) and `relayUnauthenticated` (`unauthenticatedContext`).
`unauthenticatedContext` is empty here (admin-only, no remote schemas ⇒ no query/mutation fields), so the cost
is **`assembleRelayRoleContext`**: it builds the *entire* Relay schema for the admin role over the full
`SourceCache` — all sources' mutation parsers via `buildMutationParser` (`Schema.hs:858–861`) and
`buildIntrospectionSchema` **twice** (frontend + backend).

**Conclusion.** The latency floor is the **full Relay context build** (`assembleRelayRoleContext`), which is
O(total) and is being **evaluated on every schema rebuild** — even though it is wrapped in `unsafeInterleaveIO`
(`Schema.hs:246`) precisely so it only runs when the dormant `/v1beta1/relay` endpoint is hit. Something forces
each rebuild's `relayContexts` thunk, defeating the deferral. The now-cached per-pair *Hasura* parser build is
negligible by comparison.

**Confirmed (trace).** A `RELAY-BUILD-EXP` probe at the top of `assembleRelayRoleContext` fires **exactly once
per mutation** — untrack→1, track→1, `role=admin nSources=1` — emitted *synchronously inside* the ~5 s request,
plus once at cold startup. So the Relay context is genuinely force-built on every schema rebuild; this is not a
GHC lazy-attribution artifact. (GHC charges a thunk's cost to its *creation* stack inside `buildGQLContext`,
which is why the profile pointed there; the trace proves the *forcing* happens once per build.)

**Demander located (`+RTS -xc` + sentinel).** Replacing the relay thunk body with `error "…"` made the server
**crash uncaught at cold startup** (an `ErrorCall` bypasses the build's `ExceptT QErr` handling), proving the
demand happens *inside the synchronous schema-cache build*, not in a request handler nor a background thread.
The `-xc` exception report named the forcer directly:
`(THUNK_2_0) … buildGQLContext111 … --> evaluated by: Hasura.GraphQL.Schema.buildGQLContext, called from
…buildRebuildableSchemaCache698 … buildRebuildableSchemaCache … initialiseAppContext`. I.e. the `relayContexts`
thunk is **evaluated by `buildGQLContext` itself** while the schema-cache build forces its output — the
`unsafeInterleaveIO` deferral (`Schema.hs:246`) is *not* effective (it is **not** the `AppStateRef` store
(`AppStateRef.hs:137` is WHNF-only `!newSC`), **not** `Inc.cache` (it stores its result lazily, no `seq`/force),
and **not** `Result{result :: !b}` which is WHNF-only). The demand is intrinsic to building/returning
`relayContexts` within `buildGQLContext` as the build consumes its output.

**Validated by stubbing.** Replacing the whole `relayContexts <- … assembleRelayRoleContext …` block with
`relayContexts <- pure mempty` (skip Relay) and rebuilding: the server **starts cleanly** and `public`
untrack/track mutations drop from **~4–5 s → ~0.7–1.1 s** (profiled; un-profiled ≈ 0.4 s) — a ~5–6× reduction —
with **no crash and queries/mutations still served**. So (a) the eager Relay build is conclusively the floor,
and (b) nothing in the build/startup path genuinely *needs* the Relay context populated.

**Fix lever (revised + validated).** The §12.10 lever (cache per-pair parsers) is **already implemented and
working** — not the remaining bottleneck. The remaining bottleneck is the eager Relay build inside
`buildGQLContext`, which is force-evaluated every schema-cache build (demander confirmed above). Options, best
first:
1. **Gate / skip Relay assembly** when the `/v1beta1/relay` endpoint isn't in use (admin-only deployments never
   use it). Validated: stubbing `relayContexts <- pure mempty` cut `public` mutations ~5–6× with the server
   fully functional. Cleanest concrete fix: build `relayContexts` only when relay is enabled, else `mempty`.
2. **Make the deferral actually hold.** The `unsafeInterleaveIO` at `Schema.hs:246` is defeated because the
   build forces `relayContexts` while consuming `buildGQLContext`'s output. If Relay must always be available,
   ensure the per-role relay `RoleContext` values are only demanded at relay-request time (`Execute.hs:92`),
   not during the build — e.g. store the *thunk* in `scRelayContext` such that the build never forces it.
3. If Relay must stay eagerly available, make `assembleRelayRoleContext` incremental/per-pair like the Hasura
   schema (harder — its global `Node` interface resists per-schema partitioning, see the `SchemaFieldParsers`
   note).

### 12.12 Benchmark — relay-fix prototype (per-schema gradient confirmed)

Ran the official `server/bench/schema-cache-bench.sh` against a running engine to quantify the relay fix.

**Configuration (important caveats):**
- **Relay-fix prototype**: `relayContexts <- pure mempty` in `buildGQLContext` (the §12.11 stub — skip the
  eager Relay build). *Not* the current committed code.
- **Profiled `-O2` binary** (`cabal.project.local` profiling still on): absolute times are **~2× inflated**
  per the script's own header; the small/medium/large *gradient* is unaffected.
- Dev DB: source `default`, **1302** tracked tables — small `public`(2), medium `s1`(200), large `s5`(600).
  5 reps each.

**Results (avg server wall-time, seconds; profiled):**

| Operation | small `public`(2) | medium `s1`(200) | large `s5`(600) | large/small |
|---|--:|--:|--:|--:|
| ALTER ADD COLUMN  | 1.63 | 2.97 | 6.32 | 3.88× |
| ALTER DROP COLUMN | 1.55 | 3.25 | 6.48 | 4.19× |
| TRACK TABLE       | 0.79 | 1.82 | 4.04 | 5.13× |
| UNTRACK TABLE     | 0.70 | 1.96 | 4.19 | 5.97× |

(TRACK/UNTRACK are the most stable; ADD/DROP COLUMN via `run_sql` showed GC-drift outliers — e.g. ADD rep 4
hit 9.9 s on large — exactly the "long-running engine drifts" effect the script warns about.)

**Interpretation.**
- With the eager Relay build removed, **cost now scales with the *changed* schema's size** (small < medium <
  large), instead of being a flat O(total) floor. This is the per-(source, schema) caching working end-to-end:
  a `public`(2-table) `track_table` is now **~0.8 s profiled (≈0.4 s un-profiled)** vs the **~3 s** floor
  before — and it no longer pays for the other 1300 tables.
- The residual cost on a *large* schema change (`s5`, 600 tables ⇒ ~4 s TRACK profiled) is the genuine per-pair
  rebuild of *that* schema's parsers — expected and proportional, not the O(total) relay floor.
- Confirms §12.11: the floor was the Relay build, and removing it restores the intended per-schema gradient.

**Caveat for absolute numbers.** A clean comparison (non-profiled OPT, and a true baseline-vs-fix A/B via
`schema-cache-bench-compare.sh` with `BENCH_TSV`) is the next step for headline figures; these profiled numbers
establish the gradient and the order-of-magnitude win, not the final absolute latency.

### 12.13 Implemented fix — Relay schema **disabled by default** (`EFEnableRelaySchema`)

Implements the §12.11 / §12.12 fix as a config gate, mirroring how Apollo Federation and the other `EF*`
toggles are already wired (zero new config plumbing — `experimentalFeatures` is already a parameter of
`buildGQLContext`). Per product decision, Relay is **off by default** (this deployment never uses it — locked
decision 5) with an explicit opt-in for the rare deployment that does.

**Change set:**
- `server/src-lib/Hasura/Server/Types.hs`: new `ExperimentalFeature` constructor `EFEnableRelaySchema`
  with key `"enable_relay_schema"`. `FromJSON`/`ToJSON` derive from `experimentalFeatureKey` over
  `[minBound..maxBound]`, so parsing needs nothing else.
- `server/src-lib/Hasura/GraphQL/Schema.hs` (`buildGQLContext`): build the per-role Relay schema **only** when
  `EFEnableRelaySchema ∈ experimentalFeatures`; otherwise `relayContexts <- pure mempty`. Comment updated to
  record that the `unsafeInterleaveIO` deferral does not hold in practice (§12.11).

**Behaviour:**
- **Default (no flag): Relay is NOT built.** The O(total) Relay schema build is skipped on every schema-cache
  rebuild. `scRelayContext` is empty; a `/v1beta1/relay` request falls back to the (empty, cheap)
  unauthenticated relay context via `Execute.hs:92` — HTTP 200, introspection of an empty `query_root`, and
  relay-specific fields (`node`) return a clean `validation-failed` GraphQL error. No crash; regular
  `/v1/graphql` is entirely unaffected. (Verified empirically.)
- **Opt-in (`HASURA_GRAPHQL_EXPERIMENTAL_FEATURES=...,enable_relay_schema`):** restores the full Relay schema
  (and its per-rebuild O(total) cost).
- `relayUnauthenticated` is left as-is: for this deployment `unauthenticatedContext` is empty (no remote
  schemas; sources aren't exposed to the unauth role), so it is not a measurable cost.

**Scope note:** this gates/skips Relay rather than fixing the underlying defeated-`unsafeInterleaveIO`
deferral. Making Relay genuinely lazy (forced only at `/v1beta1/relay` request time) or incremental remains
§12.11 options 2–3 for deployments that need Relay always-on without the per-rebuild cost.

**Verified (non-profiled OPT binary, A/B on the same build, dev DB 1302 tables):**

| Operation | Relay ON (`enable_relay_schema`) | Relay OFF (default) | speedup |
|---|--:|--:|--:|
| `public`(2) `track_table`  | ~1.9–2.4 s | **~0.28–0.39 s** | ~6–7× |
| `s5`(600) `track_table`    | ~3.1–3.4 s | **~1.6 s**        | ~2× |

The default (Relay off) eliminates the O(total) Relay floor: the 2-table `public` mutation drops to ~0.3 s, and
the residual `s5` cost (~1.6 s) is the genuine per-pair rebuild of *that* schema's 600 tables — i.e. cost now
scales with what changed, exactly as the per-(source, schema) design intends. (Real, un-profiled figures —
contrast the ~2× inflated §12.12 prototype numbers. A full 4-operation A/B via `schema-cache-bench-compare.sh`
follows in §12.14.)

### 12.14 Full A/B benchmark — Relay ON vs Relay OFF (default)

Ran `server/bench/schema-cache-bench.sh` twice against the **same** dev DB (1302 tables; small `public`(2),
medium `s1`(200), large `s5`(600)), each on a **fresh non-profiled OPT engine**, and diffed with
`schema-cache-bench-compare.sh`:
- **baseline** = Relay ON (`enable_relay_schema`)
- **current**  = Relay OFF (new default)

| Operation | size | Relay ON (s) | Relay OFF (s) | speedup |
|---|---|--:|--:|--:|
| ALTER ADD COLUMN  | small  | 2.331 | 0.620 | **3.76×** |
|                   | medium | 2.724 | 0.971 | 2.81× |
|                   | large  | 3.520 | 1.735 | 2.03× |
| ALTER DROP COLUMN | small  | 2.473 | 0.603 | **4.10×** |
|                   | medium | 2.762 | 1.022 | 2.70× |
|                   | large  | 3.605 | 1.755 | 2.05× |
| TRACK TABLE       | small  | 2.135 | 0.356 | **6.00×** |
|                   | medium | 2.439 | 0.693 | 3.52× |
|                   | large  | 3.193 | 1.470 | 2.17× |
| UNTRACK TABLE     | small  | 2.067 | 0.295 | **7.01×** |
|                   | medium | 2.489 | 0.691 | 3.60× |
|                   | large  | 3.134 | 1.430 | 2.19× |

**Reading it.** Relay ON adds a roughly **flat ~1.7–1.8 s floor** to *every* operation regardless of the
changed schema's size (that's the O(total) Relay rebuild). Removing it (the new default):
- **Small-schema changes** (the common case — a 2-table schema) drop **~6–7×**, from ~2.1 s to **~0.3 s**.
- **Large-schema changes** drop **~2×**; the ~1.5–1.8 s that remains is the genuine, proportional per-pair
  rebuild of that schema's 200/600 tables — exactly what the per-(source, schema) design intends to be the
  *only* cost.
- The medium/large-vs-small *gradient* is now clean (e.g. UNTRACK small→large 4.8×), confirming cost tracks
  the changed schema rather than total metadata size.

This is the headline, trustworthy figure for Phase 3: **the per-(source, schema) work was already correct; the
remaining floor was the eager Relay build, and disabling it by default removes it.**

# RFC — Phase 8: Persistent Memoization Cache (per-table parser granularity)

## 1. Problem

After Phase 3 disabled the eager Relay build (`per-schema-gql-context.md` §12.13), metadata-mutation
latency scales cleanly with the **changed** schema's size — which is exactly what the per-`(source, schema)`
design intended. But the resulting per-schema cost is now the floor, and on a large schema it is large.

Measured (`per-schema-gql-context.md` §12.14, non-profiled OPT, dev DB 1302 tables, Relay OFF):

| changed schema | tables | `TRACK TABLE` |
|---|--:|--:|
| `public` | 2 | 0.356 s |
| `s1` | 200 | 0.693 s |
| `s5` | 600 | **1.470 s** |

Fitting the two larger points:

```
slope     = (1.470 - 0.693) / (600 - 200) = 1.94 ms/table
intercept = 0.693 - 200 x 0.00194         = ~0.31 s
```

i.e. **`T ≈ 0.31 s (flat) + 1.94 ms x tables_in_changed_schema`**.
(Check against small: `0.31 + 2 x 0.00194 ≈ 0.31 s` vs 0.356 s measured — slightly superlinear, close enough.)

**The waste:** tracking *one* table in `s5` rebuilds **all 600** tables' parsers. 599 of them did not change.
That is ~1.11 s of the 1.47 s spent rebuilding work that was already correct.

**Goal:** reuse unchanged tables' parsers across builds, so a single-table mutation costs one table's
parser build (~2 ms) instead of the whole schema's (~1.11 s).

## 2. Locked decisions (from product owner)

1. **Admin-only, forever.** `roles = [admin]`; permissions will never be used. Confirmed 2026-07-15.
   The memo cache therefore needs **no role dimension** — one memo table per `(source, schema)`.
   (Empirically confirmed roles=1 via `export_metadata` on the loaded `app_test`: 654 tables, zero
   permission entries.)
2. **Relay is never used.** Confirmed 2026-07-15. Already off by default via `EFEnableRelaySchema`
   (§12.13); the Relay code path may be deleted outright (see §11.1). This is hygiene, **not** a perf
   change — §12.14's numbers are already Relay-free.
3. **Transitive invalidation is acceptable.** Untracking a table that 50 others reference may rebuild
   all 51. The product owner has accepted that some mutations will not get the full benefit.

## 3. Current flow (grounded in code)

```
buildSchemaCacheRule                                     (Cache.hs)
  └─ Inc.keyed over sources
       └─ Inc.keyed over (source, schema) pairs
            ├─ buildSchemaParsersForSchema  -< KeyedBy effectiveKey (...)
            │     └─ buildAllRoleParsersForSchema        (Schema.hs:781)
            │           └─ for roles $ \role ->
            │                 runMemoizeT $ buildSchemaRoleParsers ...   (Schema.hs:800)
            └─ assembleSchemaContextForSchema -< KeyedBy effectiveKey (...)
```

Two facts do all the damage:

- **`runMemoizeT = flip evalStateT mempty . unMemoizeT`** (`Memoize.hs:141`). Every build starts with an
  **empty** memo table. Nothing survives to the next build.
- The `Inc.cache` node's granularity is the `(source, schema)` **pair**. `effectiveKey` includes
  `schemaContentKey` (`Cache.hs:612-628`), a content fingerprint over *all* tables in the pair. Change one
  table and the key moves, the whole pair misses, and all 600 tables rebuild.

## 4. Key insight

**A per-table parser cache already exists. It is discarded every build.**

`MemoizeT` is `StateT (DMap MemoizationKey Identity) m` (`Memoize.hs:129-131`), and the memoized nodes are
already keyed per table:

| call site | key |
|---|---|
| `Select.hs:582` | `memoizeOn 'defaultTableSelectionSet (sourceName, tableName)` |
| `Select.hs:126` | `memoizeOn 'defaultSelectTable (sourceName, tableName, fieldName)` |
| `Mutation.hs:198` | `memoizeOn 'tableFieldsInput (sourceName, tableName)` |
| `Postgres/Instances/Schema.hs:426` | `memoizeOn 'columnParser (scalarType, nullability)` |

`'defaultTableSelectionSet (sourceName, tableName)` **is** a per-table cache entry. It works — for the
duration of one build. This RFC does not propose building a new cache; it proposes **not throwing away the
one that already exists.**

## 5. Success criteria

1. A single-table mutation in schema *X* rebuilds only that table's parser subtree plus its transitive
   dependents — not all of *X*.
2. **Byte-identical** served schema + introspection SDL vs a from-`mempty` build (regression-tested on the
   1302-table fixture **and** a relationship-heavy fixture). This is the primary correctness gate; see §8.
3. No `Unique` duplication (`"conflicting definitions for GraphQL type"` must never appear).
4. `s5`(600) `TRACK` drops from ~1.47 s toward ~0.35 s.

## 6. Design

### 6.1 Make `MemoizeT` seedable and its table returnable — `Memoize.hs`

```haskell
type MemoTable = DMap MemoizationKey Identity

-- retained unchanged for callers that want a cold build
runMemoizeT :: (Monad m) => MemoizeT m a -> m a

-- new
runMemoizeTWith :: (Monad m) => MemoTable -> MemoizeT m a -> m (a, MemoTable)
runMemoizeTWith seed = flip runStateT seed . unMemoizeT
```

Seeded entries have their `IORef` cells **already filled** (`Memoize.hs:191`), so forcing them is safe and
does not interact with the eager-blackholing scheme (`Memoize.hs:166-192`). A seeded entry is
indistinguishable from one built earlier in the same pass.

### 6.2 Record the dependency graph — `Memoize.hs`

> **REVISED during Stage 1 implementation (2026-07-15).** The original design below the line proved wrong;
> what was implemented is better. Recorded because the reasoning matters.
>
> **Original proposal:** key the graph by an existential `SomeMemoKey` wrapping `MemoizationKey`, with
> `DepGraph = HashMap SomeMemoKey (HashSet SomeMemoKey)`. Two problems:
> 1. **It doesn't typecheck as specified.** `Hashable SomeMemoKey` is unobtainable — `MemoizationKey` carries
>    only `Ord a, Typeable a` (`Memoize.hs:206-207`), no `Hashable a`. It would have to be `Map`/`Set` via
>    `gcompare`, not `HashMap`/`HashSet`.
> 2. **It would roughly double the hottest cost in the build.** Every edge insert is `O(log n)` *key*
>    comparisons, and a `MemoizationKey` comparison walks a `TH.Name` — ~199 ns, §11.2. On top of the
>    `DM.lookup` that already happens, that is ~2x the `gcompare` traffic that is *already* 15.8% of runtime.
>    This is what drove the (now withdrawn) claim that interning was a prerequisite.
>
> **What was implemented instead:** tag each memo entry with an `Int` identity *inside the DMap value*, so
> the single lookup memoization already performs yields both the value and its graph identity. The graph is
> then keyed by `Int`. **Dependency recording adds zero additional key comparisons**, and §11.2 interning is
> no longer a prerequisite — it reverts to an independent optimisation.

> **⚠ StrictData trap — cost ~2h of Stage 1; read this before touching `MemoEntry`.**
> This package enables **`StrictData`** (`graphql-engine.cabal:239`, default-extensions). Writing the
> obvious `data MemoEntry f t = MemoEntry !Int (f t)` therefore makes the **second field strict**, and that
> silently destroys knot-tying: `f` is instantiated to the `Identity` *newtype*, which has no runtime
> representation, so forcing the field **is** forcing the `unsafeInterleaveIO` placeholder → `readIORef` on
> a still-`Nothing` cell → *"parser was forced before being fully constructed"*. Every mutually recursive
> parser breaks. The `~` is mandatory.
>
> **Why it was hard to find:** the pre-Phase-8 code stored a bare `Identity` and was immune **by accident**
> — newtypes cannot have strict fields, so `StrictData` never applied. Wrapping the value in a `data`
> constructor is what exposes it. Three standalone repros (lazy `Map`, real `DMap`, `+recordEdge +parent
> stack`) all **passed**, because a scratch file does not enable `StrictData`. Do not trust a repro of this
> module that omits the project's default-extensions.
>
> **Why the symptom lies:** `runWithTimeLimit` (`Control/Monad/TimeLimit.hs`) runs the action under
> `async`; a thrown `error` just kills that thread, `var` never fills, and hspec reports
> *"failed to compute in reasonable time"*. Four of the five failures looked like **hangs** and were
> actually this exception. Only a test that bypasses the time limit shows the real message.

```haskell
-- Int strict; the `f t` field MUST stay lazy — memoizeOn installs the
-- unsafeInterleaveIO placeholder here before building the real value.
-- The `~` opts out of the package-wide StrictData (see the trap above).
data MemoEntry f t = MemoEntry {-# UNPACK #-} !Int ~(f t)

type MemoTable = DMap MemoizationKey (MemoEntry Identity)
type DepGraph  = IntMap IntSet                 -- child -> parents (REVERSE edges)

data MemoState = MemoState
  { msTable   :: !MemoTable
  , msNextId  :: !Int
  , msParents :: [Int]                          -- stack; head = node being built
  , msDeps    :: !DepGraph
  }

data MemoCache = MemoCache { mcTable :: !MemoTable, mcDeps :: !DepGraph, mcNextId :: !Int }

runMemoizeTWith :: (Monad m) => MemoCache -> MemoizeT m a -> m (a, MemoCache)
runMemoizeT     :: (Monad m) => MemoizeT m a -> m a       -- = fmap fst . runMemoizeTWith emptyMemoCache
```

In `memoizeOn`: on a **hit**, `recordEdge` the entry's existing id; on a **miss**, allocate an id, install
the placeholder under it, `recordEdge`, then push the id as parent for the builder and restore the saved
stack afterwards.

`recordEdge` fires on **every** call, including cache hits — a hit still means "the parent depends on this
child", and that edge must exist even though the child was not rebuilt. **Graph completeness is the one
invariant eviction correctness rests on (§8), and this is its single enforcement point.**

**Stale-edge accumulation.** A rebuilt node gets a *fresh* id, so edges recorded against its old id linger in
`mcDeps`. Stale edges can only cause over-eviction (safe, just slower), never under-eviction — but they
accumulate, so the Stage 2 evictor must drop graph entries for ids no longer present in `mcTable`.

**On error handling.** A `QErr` thrown from a builder aborts the entire schema-cache build and the
`MemoState` is discarded, so the parent stack needs no exception unwinding. Restoring the *saved* stack
(rather than popping one frame) keeps the invariant even if a builder leaves frames behind.

### 6.3 Eviction — ✅ landed in `Control/Monad/Memoize.hs` (Stage 2a, 2026-07-15)

Kept in `Memoize.hs` rather than a separate `Invalidate.hs`: the `MemoizationKey` constructor is not
exported, and an evictor must pattern-match it. Rather than widen the export, `Memoize.hs` exposes a narrow
inspection API and takes the classifier as a callback:

```haskell
memoKeyName :: MemoizationKey t -> TH.Name
memoKeyArg  :: forall a t. Typeable a => MemoizationKey t -> Maybe a   -- cast; existential arg
evictWith   :: (forall t. MemoizationKey t -> Bool) -> MemoCache -> (MemoCache, EvictionStats)
data EvictionStats = EvictionStats { esDirect, esEvicted, esSurvived :: !Int }
```

`evictWith` computes the direct set, takes the reverse-reachability closure, filters the table, and prunes
dead edges (both entries keyed on an evicted id and evicted ids inside surviving parent sets). Node ids are
never reused, so a stale edge can never alias a rebuilt node.

**Refinement found by auditing the real call sites — keys that embed content are self-invalidating.**
The ~30 `memoizeOn` sites use three classes of argument:

| class | examples | eviction treatment |
|---|---|---|
| **Names a table** — `(SourceName, TableName b)`, `(SourceName, TableName b, G.Name)` | `Select.hs:582`, `Select.hs:126`, `Mutation.hs:198`, `OnConflict.hs:154` | **must be evicted explicitly** — the key carries no content, so a changed table hits its own stale entry |
| **Embeds content** — `(scalarType, nullability)`, `columnType`, `(Text, columnInfo)` | `Postgres/Instances/Schema.hs:426`, `:585`, `Select.hs:1176` | **self-invalidating** — changed content ⇒ different key ⇒ miss ⇒ rebuild. Safe to retain; evicting them is pure waste |
| **Anything else** | — | **evict (conservative default)** |

Note the third row is what makes this safe: a node like `mkNumericAggFields (Text, columnInfo)` is a *child*
of a table node, so reverse-reachability never reaches it from a table change — but it does not need to,
because its key changes when its column does.

**Stage 2b — the backend-aware classifier. ✅ DONE 2026-07-15.**
`Hasura/GraphQL/Schema/MemoInvalidate.hs`:

```haskell
invalidatedByTables :: (Backend b, Typeable (ScalarType b)) => SourceName -> HashSet (TableName b) -> MemoizationKey t -> Bool
evictTables         :: (Backend b, Typeable (ScalarType b)) => SourceName -> HashSet (TableName b) -> MemoCache -> (MemoCache, EvictionStats)
```

It lives outside `Control.Monad.Memoize` because it needs the concrete `b` to cast to `TableName b`. That is
available at the wiring site: `buildSchemaParsersForSchema` runs inside
`AB.dispatchAnyBackendArrow @BackendSchema @BackendMetadata` (`Cache.hs`).

**Audit outcome (all 39 `memoizeOn` sites):**

| shape | class | sites |
|---|---|---|
| `(SourceName, TableName b)` | evict-if-changed | `Select.hs:582,691,1060`; `Mutation.hs:198,302,339,503`; `OnConflict.hs:154`; `OrderBy.hs:246`; `SubscriptionStream.hs:197`; **`BoolExp.hs:103`**, **`OrderBy.hs:114`** |
| `(SourceName, TableName b, G.Name)` | evict-if-changed | `Select.hs:126,184,236,299`; `SubscriptionStream.hs:269` |
| `(ScalarType b, G.Nullability)` | reuse | `Postgres:426`, `MSSQL:176`, `DataConnector:493` |
| `(ColumnType b, G.Nullability)` | reuse | `BigQuery:110` |
| `ColumnType b` | reuse | `Postgres:585`, `MSSQL:309`, `BigQuery:247` |
| `(Text, ColumnInfo b)` | reuse | `Select.hs:1176` |
| everything else | **evict (conservative)** | logical models, native queries, actions, remote schemas, `nodeInterface ()`, `streamColumnValueParser` |

Two findings worth recording:

1. **`boolExpInternal` / `orderByExpInternal` are polymorphic in their key** (`forall name. (Ord name,
   Typeable name, ...)`), so the shape is decided by callers. `tableBoolExp` and `tableOrderByExp` pass
   `tableInfoName tableInfo` ⇒ `(SourceName, TableName b)` — caught. The *logical model* wrappers pass a
   `G.Name` ⇒ a different shape ⇒ class 3 (conservatively evicted). Correct either way, and `app_test` has
   no logical models.
2. **Reusing the content-keyed class is not an optimisation, it is load-bearing.** `columnParser` and
   `comparisonExps` are shared by *every* table. Evicting them would make reverse-reachability sweep every
   parent — i.e. the whole schema — and the Phase 8 win would evaporate. The conservative default is only
   safe *because* these are classified explicitly.

**Typeable subtlety:** `Backend b` supplies `Typeable b`, `Typeable (TableName b)`, `Typeable (ColumnType
b)` and `Typeable (ColumnInfo b)`, but **not** `Typeable (ScalarType b)` — `ScalarType` is a type family, so
it does not follow from `Typeable b` and must be requested explicitly.

**Tests** (`src-test/Hasura/GraphQL/Schema/MemoInvalidateSpec.hs`, 4 examples): one node per shape, asserted
shape by shape rather than inferred from an end-to-end build. The reuse cases use `error` builders, so a
wrongly-evicted content node *fails loudly* instead of merely showing up in a survivor count. Also pins that
a same-named table in a different source is untouched. Suite: **1279 examples, 0 failures**.

1. **Direct set `D`** — entries whose key arg mentions a changed table. The `MemoizationKey` GADT already
   carries `Ord a, Typeable a` (`Memoize.hs:206-207`), so `Data.Typeable.cast` can test the known arg
   shapes:
   - `(SourceName, TableName b)` — `Select.hs:582`, `Mutation.hs:198`, `OrderBy.hs:246`, …
   - `(SourceName, TableName b, G.Name)` — `Select.hs:126`, `Select.hs:236`, …
2. **Provably-unaffected entries survive.** Scalar-keyed nodes — `columnParser (scalarType, nullability)`
   (`Postgres/Instances/Schema.hs:426`), `comparisonExps columnType` (`Postgres/Instances/Schema.hs:585`) —
   are table-independent by construction and are never evicted directly.
3. **Conservative default: an arg shape that is neither recognised nor provably table-independent is
   EVICTED.** This makes under-eviction structurally impossible for shapes someone forgets to enumerate.
   Over-eviction only costs time.
4. **Transitive closure `E`** — reverse-BFS from `D` over `DepGraph`. Cycles (`author → article → author`)
   terminate normally under BFS.
5. Return `MemoTable \\ E`.

### 6.4 Storage and threading — `Cache.hs` / app state

Persist `HashMap (SourceName, SchemaName) (MemoTable, DepGraph)` in an `IORef` in app state.

**On concurrency:** rebuilds are already serialised. `withSchemaCacheReadUpdate` runs the whole build under
`withMVarMasked lock` — *"An internal lock ensures that at most one update to the 'AppStateRef' may proceed
at a time"* (`AppStateRef.hs:126-136`). No additional locking is required, and the schema-sync path
(`SchemaUpdate.hs:294`) goes through the same lock.

**On the Inc framework:** this is a deliberate side-channel. `Inc.cache`'s contract is explicit —
*"only direct inputs and outputs of the given arrow are cached. If an arrow provides access to values
through a side-channel, they will not participate in caching"*
(`lib/incremental/src/Hasura/Incremental/Internal/Cache.hs:29-31`). We are knowingly stepping outside it.
That is normally a smell; here the MVar makes it sound, and the alternative (teaching `Inc.cache` to hand a
rule its previous output) is a much larger change to a load-bearing abstraction.

**Deriving `ChangedTable`:** the eviction set must be computed *before* seeding. Cheapest correct source is
a diff of the pair's `schemaContentKey` inputs — i.e. per-table content fingerprints rather than the current
whole-pair `Value` (see §10.2, which may make this cheaper *and* fix an existing O(total) cost).

## 7. Performance expectation

With perfect per-table granularity, a one-table track in `s5`:

```
T = 0.31 s (flat floor) + 1.94 ms x 1 table  ≈  0.31 s      (vs 1.470 s today)
                                             =  ~4.7x
```

and — more importantly — **the size gradient collapses**: `s5` costs what `public` costs. Mutation latency
becomes independent of the changed schema's size.

**This 4.7x is an upper bound. Three things pull it down:**

1. **The 0.31 s flat floor becomes the wall, and it is unattributed.** §12.9's probes account for only
   ~0.08 s of it (metadata write 0.02 + `fetchMetadata` 0.03 + GQL finalization 0.03). The remainder is
   unmeasured — likely DB re-introspection plus `schemaContentKey`. Once parser work goes to ~zero, that
   floor *is* the latency. See §10.2.
2. ~~**Transitive invalidation.**~~ **RESOLVED by Stage 0 (§9): a non-issue.** Measured 99.82% average
   survival on real metadata; the relationship graph is nearly empty (28 rels / 612 tables). Worst case in
   the whole DB evicts 9/602. This hedge does not materialise.
3. **The fixture understates per-table cost — but in our favour.** §12.8 is explicit that the bench tables
   have **no relationships or permissions**. Stage 0 shows real `app_test` is *also* relationship-poor, so
   transitive fan-out is **not** larger as feared. What remains is that real `sys` tables are likely wider
   (more columns) than `tbl_N`, so the 1.94 ms/table slope is probably **understated** ⇒ the absolute win is
   **larger**, not smaller. Needs one timed `track_table` on `sys` to calibrate.

**Revised expectation after Stage 0: ~4.5–4.7x on `sys` mutations (~1.47 s → ~0.31 s), bounded by the
0.31 s flat floor (§10.2).** Since `sys` is 98.4% of the metadata (§9 Stage 0b), this applies to
essentially every mutation in production, not just a "large schema" subset.

## 8. Correctness

**The single risk is under-eviction: silently serving a stale GraphQL schema.** This is a bug class that
ships — it produces no crash and no log line, just a wrong schema.

It has two faces:

1. **Stale parser reuse.** Memo args are `(sourceName, tableName)` with **no content component**. A changed
   table's key is unchanged, so without eviction it would hit its own stale entry.
2. **`Unique` duplication.** Reused parsers keep their old `Unique`; rebuilt ones get fresh ones. If one
   GraphQL type ends up with two `Unique`s, introspection fails with *"conflicting definitions for GraphQL
   type"* — the same failure documented at `Schema.hs:801-807` for the Relay `Node` interface. Prevented by
   the same invariant.

Both reduce to one invariant:

> **The dependency graph must be complete: every edge from a parser to a parser it embeds must be recorded.**

Because every such edge is created by a `memoizeOn` call, and `recordEdge` fires unconditionally in
`memoizeOn`, completeness follows from that one instrumentation point. The conservative default (§6.3.3)
covers arg shapes we fail to classify.

**Primary gate (success criterion 2):** build twice — once incrementally from the persisted table, once from
`mempty` — and assert the introspection SDL is **byte-identical**. Run in CI over:
- the 1302-table fixture (breadth), and
- a **relationship-heavy** fixture (the current bench has none — §12.8 — so it exercises no transitive
  invalidation at all and would pass a broken implementation).

A debug flag that runs both builds and diffs them on every mutation is worth having during Stage 2.

## 9. Staging

**Stage 0 — prove the ceiling before building anything. ✅ DONE 2026-07-15 — PASSED.**

Method was cheaper than planned: **no engine instrumentation and no rebuild were needed.** The eviction set is
determined by *relationship reachability*, which is computable from metadata alone. (Graph: edge `A → B` iff
A's selection set embeds B's, i.e. A has an object/array relationship targeting B. Eviction set for a changed
table T = `{T} ∪ reverse-reachable(T)`.)

**Data source:** the real **`app_test`** database, read from the local Phase 2 partition store —
`SELECT source_name, schema_name, partition FROM hdb_catalog.hdb_metadata_partition`
(`postgres://postgres:postgres@127.0.0.1:25432/app_test`, catalog version 49).
**Do NOT read `hdb_catalog.hdb_metadata`** — that legacy blob is stale under Phase 2 partition storage.

`app_test` tracked metadata — **653 tables, 3 sources, 4 partitions, 28 relationships, 0 permissions**:

| source | schema | tracked | obj rels | arr rels | perms |
|---|---|--:|--:|--:|--:|
| `default` | **`sys`** | **601** | 7 | 19 | 0 |
| `testmuskan` | `public` | 40 | 0 | 0 | 0 |
| `default` | `platform` | 10 | 0 | 2 | 0 |
| `test` | `public` | 2 | 0 | 0 | 0 |

**Result — in-partition eviction for `default/sys` (601 tables):**

| tables evicted | # of tables | share |
|--:|--:|--:|
| 1 (itself only) | 589 | **98.0%** |
| 2 | 2 | 0.3% |
| 3 | 1 | 0.2% |
| 4 | 1 | 0.2% |
| 8 | 7 | 1.2% |
| 9 | 1 | 0.2% |

- **Average tables evicted per `sys` mutation: 1.11 / 601 ⇒ 99.82% survival.**
- Worst case in the DB: `sys.sys_project_workflows` evicts 9/601 ⇒ 98.5% survival.
- Graph is nearly empty: **28 relationships across 653 tables; only 17 tables have any outgoing edge.**
- Predicted: `0.31 + 601 x 0.00194 = 1.48 s` today ⇒ `0.31 + 1.11 x 0.00194 = 0.312 s` ⇒ **4.7x**.

**Corroborated by three independent sources** (all agree the app is relationship-poor):

| source | tables | relationships |
|---|--:|--:|
| remote dev `export_metadata` | 612 tracked, `sys`=602 | 28 |
| local `app_test` DDL dump (`app_test-20260707-070709.sql`) | 637 `CREATE TABLE` | 11 `FOREIGN KEY` |
| local `app_test` Phase 2 partition store *(authoritative)* | 653 tracked, `sys`=601 | 28 |

**Verdict: proceed.** The ~4.7x is real. Locked decision 3 (accepting transitive invalidation) turns out to
cost essentially nothing here — the hazard it guards against barely exists.

*Caveat:* 1 object relationship keys on an FK column whose target is not in the metadata (it needs a DB FK
lookup). At one edge it cannot move a 99.82% result.

**Stage 0b — the finding that matters more than the survival rate.**

**601 of 653 tracked tables (92%) live in ONE partition: `default/sys`.** The other three partitions hold
40 / 10 / 2 tables. Consequences:

1. **The per-`(source, schema)` work (Phases 1–3) buys almost nothing on real metadata.** Essentially every
   mutation touches `sys`, so essentially every mutation is permanently in the *large-schema worst case*. The
   small/medium/large gradient celebrated in `per-schema-gql-context.md` §12.14 is a property of the
   synthetic `s1`–`s5` bench fixture, **not** of production. There is no gradient to ride.
2. **The arithmetic corroborates the model.** `sys` at 601 tables predicts
   `0.31 + 601 x 0.00194 ≈ 1.48 s`; §12.14 measured `s5` (600 tables) at **1.470 s**. So a `sys` mutation
   costs ~1.47 s today, and per-table granularity takes it to ~0.31 s — the full 4.7x, on the only path that
   is actually used.
3. **§11.3's "split the schema" alternative is now the direct competitor to this RFC**, not a footnote — but
   it means restructuring the app's real 602-table `sys` schema, not a bench fixture. See §11.3.
4. **The bench fixture is unrepresentative and should be replaced.** `server/bench/schema-cache-bench.sh`
   auto-picks small/medium/large tracked schemas — a shape production does not have. Benchmarks should track
   a table in a ~600-table single schema.

*Note:* the 1.94 ms/table slope derives from the fixture, whose tables have **no relationships** (§12.8) and
are presumably narrow. Real `sys` tables likely have more columns, so actual `sys` latency may **exceed**
1.47 s — which makes the absolute win larger, not smaller. Worth one timed `track_table` against `sys` to
calibrate (this mutates dev metadata; `track_test_table.sh` already does exactly this).

**Stage 1 — plumbing, behaviourally identical. ✅ DONE 2026-07-15.**
Landed `runMemoizeTWith` + `MemoCache` + `DepGraph` recording in `Control/Monad/Memoize.hs`. `runMemoizeT`
keeps its signature (`= fmap fst . runMemoizeTWith emptyMemoCache`), so **all existing callers are untouched
and behaviour is identical** — eviction is still "evict everything" because nothing seeds a cache yet.

Verified: `cabal build all --enable-tests --enable-benchmarks` clean; **`graphql-engine-tests`: 1268
examples, 0 failures**, including the pre-existing knot-tying suite (circular graphs, infinite lists, fibo).

New tests in `src-test/Control/Monad/MemoizeSpec.hs`:
- cold run builds every node and records the dependency edge;
- **seeding from a previous cache rebuilds nothing** (the Phase 8 premise, asserted as `buildersRun == 0`);
- `runMemoizeT` ≡ cold `runMemoizeTWith`;
- edges recorded through a cycle (`a → b → a`) — the back-edge resolves via the in-progress placeholder, so
  this is the case where a missing `recordEdge`-on-hit would silently leave the graph incomplete.

Not yet done (Stage 2 owns them): nothing calls `runMemoizeTWith` in the engine; no eviction; no persistence
in `Cache.hs`; the SDL-equality gate is not built.

**Stage 2 — real eviction.** 🟡 IN PROGRESS.

- ✅ **2a — the evictor (`evictWith`) + key inspection + unit tests.** `graphql-engine-tests`: **18 examples,
  0 failures**. Covers: transitive eviction (evicting a leaf takes its embedder with it); *selective reuse*
  (evicting the root re-runs **exactly one** builder, leaf reused); `const False` ⇒ nothing rebuilds;
  `const True` ⇒ degrades to a cold build; cycle termination; id non-reuse; dangling-edge pruning.
- ✅ **2b — backend-aware classifier** (§6.3). `Hasura/GraphQL/Schema/MemoInvalidate.hs` + 4 tests; all 39
  `memoizeOn` sites audited and classified. Suite: **1279 examples, 0 failures**.
- ⬜ **2c — persistence + wiring** (§6.4): per-`(source, schema)` `IORef` store; derive the changed-table set
  (per-table fingerprints, cf. §10.2); call `runMemoizeTWith` from `buildAllRoleParsersForSchema`
  (`Schema.hs:801`) instead of `runMemoizeT`. **Nothing in the engine seeds a cache until this lands** — the
  build is still cold every time, i.e. behaviour is unchanged.
- ⬜ **2d — the SDL-equality gate** (§8). Land *before* 2c is enabled by default.
- ⬜ **2e — relationship-heavy fixture** (§12 note) + bench.

**Order matters: 2d before 2c ships.** 2a's unit tests prove `evictWith`'s *mechanics*; they say nothing
about whether the 2b classifier is complete. Only the SDL diff can catch a missed key shape, and only on a
fixture that actually has relationships — which production does not (§9 Stage 0).

**Stage 3 — `TH.Name` interning (§11.2).**
A genuinely independent ~10–13% win. (Earlier drafts called it a *prerequisite* for the dependency graph;
the Stage 1 `Int`-tagged design in §6.2 removed that coupling — the graph adds no key comparisons.)

## 10. Follow-ons / adjacent

### 10.1 Memory

The persisted `MemoTable` + `DepGraph` are retained for the process lifetime. The parsers themselves are
already retained (the schema cache holds them), so the marginal cost is the `DMap` spine plus the graph:
~60k nodes and a few hundred thousand edges for 1302 tables — expected to be modest, but **measure it**
(the codebase has prior art on space leaks here; cf. the `NOTE!` comments around the schema-registry queue
in `Schema.hs`).

### 10.2 `schemaContentKey` is an unmeasured O(total) cost — and this RFC interacts with it

`Cache.hs:612-628`:

```haskell
fingerprintCache = toJSON . sortOn encode . map toJSON . HashMap.elems
schemaContentKey = toJSON [ fingerprintCache (_siTables filteredSi), ... ]
effectiveKey     = (schemaContentKey, effectiveInvalidationKey, allRoles', dynamicConfig')
```

This is forced on **every build for every pair, including cache hits**, because `Inc.cache`'s `unchanged`
(`lib/incremental/.../Cache.hs:70-74`) compares the key via `KeyedBy k1 _ == KeyedBy k2 _ = k1 == k2`
(`Cache.hs:2220`). Per build, summed across pairs, that is a full `Value` tree + `ByteString` encode + sort
+ deep `Eq` over **all** tracked tables, plus retention of both old and new trees.

It landed in `14e049d08` (2026-06-24, *"fix:adding column was not appearing"*) — **before** the Relay fix
(`14da254fe`, 06-30) — so it **is** inside the 0.356 s / 1.470 s figures, and it **postdates every probe in
§12.9**. Nothing has ever measured it.

Two interactions with this RFC:
- It is a prime suspect for the unexplained ~0.31 s floor, which becomes the wall once §7 lands.
- Per-table eviction needs per-table change detection, which may mean *more* fingerprinting, not less —
  partly cancelling the win unless addressed.

**Possible resolution:** `buildSchemaCacheForDbSchema` (`PartialRebuild.hs:187`) already fires
`ciSourceSchemas` for a single pair, but its only caller is `RunSQL.hs:50` — its own docstring says it is
also for *"untrack_table when qSchema is available"*. Routing track/untrack through it would let the
fingerprint be dropped entirely. Worth a probe before Stage 2.

### 10.3 Not on the critical path

- **Threading.** Ruled out; see Appendix A.
- **`buildSource` partitioning.** Prototyped and falsified (§12.8).

## 11. Cleanup enabled by locked decisions

### 11.1 Delete the Relay path (locked decision 2)

`assembleRelayRoleContext`, `buildSchemaRelayParsers`, `nodeInterface`, `relayUnauthenticated`, the
`EFEnableRelaySchema` flag, and the connection-field builders (gated at `Select.hs:1651` by
`RelaySchema _ <- retrieve scSchemaKind`, and `Postgres/Instances/Schema.hs:377`).

**Expect ~0 ms.** Relay is already not built (§12.13) and the §12.14 numbers are already Relay-free. The
value is (a) maintenance surface and (b) removing the possibility of someone enabling
`enable_relay_schema` and silently reintroducing the ~1.7–1.8 s flat floor.

### 11.2 `TH.Name` interning in `MemoizationKey` (independent, ~10–13%)

**Measured 2026-07-15** (ghc 9.6.7, `-O2`):

- `Ord TH.Name` compares **`NameFlavour` first**, then `OccName`. Proved with `'map` (`GHC.Base`, occ
  `"map"`) vs `'head` (`GHC.List`, occ `"head"`), where module order (LT) and occ order (GT) **disagree**:
  `compare` returned **LT**.
- `Name = Name OccName (NameG NameSpace (PkgName String) (ModName String))` — package and module are
  **`String`s**. Two parsers in the same module (`'defaultSelectTable` and `'defaultTableSelectionSet`, both
  `Schema.Select`) walk ~56 chars of pkg+module cons-list **to prove they are equal** before reaching the
  `OccName` that differs.
- **~199 ns per `TH.Name` compare vs ~5 ns per `Int` compare (~40x).**
- Consistent with §12.10's `gcompare` = 15.8%: ~175 ms of `s5`'s 1.11 s ⇒ ~900k compares ⇒ ~115
  `memoizeOn` lookups/table at DMap depth ~13. Plausible.

**Fix:** add a precomputed `!Int` hash to the key; `gcompare` compares it first and falls back to the full
`Name` compare on collision. Still a valid total order (lexicographic on `(hash, name)`) — `DMap` requires
only *a* total order, not a specific one. The hash costs O(len) once per `memoizeOn` but saves ~13 string
walks per lookup (~25x favourable). `Memoize.hs:104-105` states the `TH.Name` is only ever *"a convenient
source for a static, unique identifier"*, so nothing depends on its structure.

**Honest sizing: ~10–13% of runtime, NOT the 24% implied by summing the `Memoize` module.** Interning
touches only the name portion of `gcompare`; the two `TypeRep` compares are fingerprint-cheap and MemoizeT's
~8.3% bind overhead is untouched. `s5`: 1.47 s → ~1.30–1.35 s.

> **Benchmark trap (for whoever re-measures):** a first attempt reported 7 ns because the two `Name`s were
> top-level CAFs and GHC floated the comparison out of the loop as loop-invariant. Names must be built at
> runtime behind `NOINLINE`, indexed from an `Array`, and diffed against a structurally identical `Int` loop.

### 11.3 Zero-code alternative worth ~3x

Per §1's model, splitting `s5` (600 tables) into six 100-table schemas gives
`0.31 + 100 x 0.00194 ≈ 0.5 s` vs 1.47 s — **~3x for no code**. Requires a DB reorganisation and changes
GraphQL root-field names, so likely a non-starter on a live app; recorded because it dominates this RFC on
effort-per-unit-win if the schema layout is negotiable.

## 12. Effort

| Stage | Scope | Est. | Status |
|---|---|--:|---|
| 0 | Survival-rate gate | ~0.5 day | ✅ **DONE 2026-07-15 — PASSED** (99.82% survival; took minutes, not a day — metadata-only, no engine changes) |
| 1 | `runMemoizeTWith` + `DepGraph` + evict-all + SDL test | ~3–5 days | not started |
| 2 | `evict` + relationship-heavy fixture + bench | ~5–8 days | not started |
| 3 | `TH.Name` interning | ~1–2 days | not started |

Stage 2 is the correctness-critical one and should not be compressed.

**Note on the Stage 2 fixture.** Stage 0 showed real metadata is relationship-*poor* (28 rels / 612 tables),
which is good for performance but bad for testing: the production data exercises almost no transitive
invalidation, so it **would pass a broken `evict`**. A *synthetic* relationship-heavy fixture is therefore
still mandatory for the SDL-equality gate (§8) — it is now purely a correctness instrument, no longer needed
to validate the perf model.

---

## Appendix A — Rejected: multi-threading the parser build

Recorded because it is the intuitive first idea and was investigated in depth (2026-07-15).

The runtime is **not** the constraint: the executable is built `-threaded` with `-with-rtsopts=-N`
(`graphql-engine.cabal:247,258`) on a 22-core host. There is simply no parallelism to exploit.

**1. Every fan-out axis has width 1.** `buildAllRoleParsersForSchema` (`Schema.hs:781`) loops over `roles`,
and its iterations *are* independent — each gets a fresh memo table via `runMemoizeT`, so `mapConcurrently`
would be correct. But `roles = [admin]` (locked decision 1), `nSources = 1`, and on a steady-state mutation
only the changed pair rebuilds. A one-item list on 22 cores is one busy thread and 21 idle.

**2. The one job that exists cannot be split.** The ~1.11 s is inside a single `runMemoizeT`
(`Schema.hs:800`) — one `StateT (DMap ...)` threaded linearly.
- *Separate tables per thread:* each mints its own `Int_comparison_exp` with a different `Unique`; merging
  fails with *"conflicting definitions for GraphQL type"* (`Schema.hs:801-807`).
- *One shared concurrent table:* types are mutually recursive, and the memo table is the mechanism that
  breaks the cycles (`Note [Tying the knot]`, `Memoize.hs:25-86`). Thread A holds `author` and needs
  `article` while B holds `article` and needs `author` — block and deadlock; don't block and hit
  *"parser was forced before being fully constructed"* (`Memoize.hs:183-187`). Two threads racing an absent
  key both build it ⇒ duplicate `Unique`s ⇒ the same conflict.

**3. It is the wrong target regardless.** Threading makes the *same wasted work* finish sooner. Perfect 22x
scaling turns 1.11 s into 50 ms while still rebuilding 599 unchanged tables. This RFC turns it into ~2 ms.

> Note: `Inc.keyed` is also a strictly sequential CPS fold threading `Accesses`
> (`lib/incremental/.../Rule.hs:310-345`). This is *not* a fundamental barrier — `Accesses` is a `Monoid`
> whose `Semigroup` is a least upper bound (`Dependency.hs:81-86`), so a parallel `keyed` is semantically
> sound. It is simply pointless given (1).

## Appendix B — Superseded documents

`rfcs/phase7-incremental-gql-context-assembly.md` was **stale and has been deleted** (2026-07-15, product
owner instruction). Its measured table (~0.6–0.8 s assembly, ~150 ms introspection, 13 ms parser build)
predates the Phase 3 findings and **must not be cited**. The live, implemented RFC for the per-schema work
is `rfcs/per-schema-gql-context.md`; the engine's code comments reference its §5.3 / §12.11 / §12.13-14.

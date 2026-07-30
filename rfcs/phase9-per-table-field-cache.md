# RFC — Phase 9: Per-Table Field-Parser Cache (replaces Phase 8)

## 1. Problem

Phase 8 (`phase8-persistent-memo-cache.md`) predicted 4.7x and **measured 1.30x**. The cache works
perfectly — probes show `changedTables=1, seededNodes=8495, direct=0, evicted=0, survived=8495` and zero
unclassified key shapes. 1.30x is its **ceiling**, not a tuning gap.

**Why: `memoizeOn` caches only the tail.** Every call site computes its key *first* and only then checks the
memo table. `tableSelectColumnsEnum` (`Schema/Table.hs:98-127`) is representative:

```haskell
tableGQLName          <- getTableIdentifierName @b tableInfo     -- work
columnsWithRedactionExps <- tableSelectColumns tableInfo         -- work
let columnDefinitions = columnsWithRedactionExps <&> (...)       -- work
...
  Just <$> P.memoizeOn 'tableSelectColumnsEnum (enumName, description, columns) (pure $ P.enum ...)
```

A cache hit skips `P.enum` and nothing else. The O(total) walk over 601 tables — computing keys, probing the
DMap — happens on every build regardless. **Node-level memoization cannot skip its own setup.**

## 2. Evidence (measured, ablation)

Ablation, not timing: §12.9 of `per-schema-gql-context.md` warns lazy-`evaluate` timing cannot attribute
across thunks (timing a builder returns a cheap thunk; the work lands on whoever forces it). Ablation found
the Relay floor (§12.11) and is what produced every number here.

| config (s5 = 600 tables, probe) | track | untrack |
|---|--:|--:|
| Phase 8 node-level memo cache, all intact | 1.651s | 0.983s |
| `buildIntrospectionSchema` ablated | 1.560s | — |
| **per-table walk skipped (return prev parsers wholesale)** | **0.976s** | **0.449s** |
| `buildAllRoleParsersForSchema` ablated (no parsers at all) | 0.527s | 0.317s |

**Decomposition of a ~1.65s `s5` track:**

| component | cost | Phase 8 recovers? |
|---|--:|---|
| non-GraphQL (metadata write, DB re-introspection, `buildTableCache`) | 0.527s | no |
| assembly on real parsers (type walk is only 0.09s of it) | 0.449s | no |
| **per-table walk** (key computation + `memoizeOn` probes) | **0.675s** | **no — structurally cannot** |
| parser construction | ~0.36s | **yes** |

Phase 8 targets the smallest slice. **Skipping the walk is worth ~0.675s — 41% of the mutation — on top of
a 100%-cached parser build.**

*Also measured and refuted:* `assembleSchemaContextForSchema` is **not** the bottleneck. Ablating
`buildIntrospectionSchema` entirely moves track only 1.651 → 1.560s; the whole O(total) type walk is ~6%.
Do not spend effort there.

*Caveat:* the table above is single probes on a fresh boot; probe absolutes run ~0.5s above the 5-rep A/B
averages. **The ratios are the trustworthy part.** Phase 9 must be judged by the A/B harness, not probes.

## 3. Proposal

Cache each table's **field-parser contribution** and skip its builders entirely when the table is unchanged.
This skips the walk, not just the tails.

Two loops own the entire 0.675s:

- `buildQueryAndSubscriptionFields` (`Schema.hs:1151-1155`) → `buildTableQueryAndSubscriptionFields` per table
- `buildMutationFields` (`Schema.hs:1289-1297`) → `buildTableInsert/Update/DeleteMutationFields` per table

## 4. Locked decisions (inherited)

1. **Admin-only forever** — `roles = [admin]`. The role dimension is kept in the cache key defensively (it is
   inert at `roles=1`, but seeding one role from another's cache would reuse parsers built under different
   permissions — invisible today, latent the day a role is added). Costs one tuple field.
2. **Relay unused** — not built by default (`EFEnableRelaySchema`).
3. **Transitive invalidation accepted** — measured at 99.82% survival on real metadata (§9 of Phase 8's RFC).

## 5. Design

### 5.1 What gets cached

Per `(source, schema, role, slot, table)`, the builder's output:

| slot | builder | type |
|---|---|---|
| `query` | `buildTableQueryAndSubscriptionFields` | `([FieldParser n (QueryDB b ..)], [FieldParser n (QueryDB b ..)], Maybe (G.Name, Parser 'Output n (ApolloFederationParserFunction n)))` |
| `mutation-frontend` / `mutation-backend` | insert+update+delete | `[FieldParser n (MutationDB b ..)]` |

**Storage is `Dynamic`.** The store spans backends, so entries are heterogeneous; `Typeable` on
`[FieldParser P.Parse (QueryDB PG ..)]` was **verified to hold** by compiling a `toDyn`/`fromDynamic`
round-trip probe. A `fromDynamic` failure is treated as a miss (rebuild), so a type mismatch degrades to
slow, never to wrong.

### 5.2 Invalidation — table-level, from relationships

A cached table's parsers embed the parsers of tables it has relationships to. So:

```
invalidated = changed ∪ { A | A reaches some changed table via relationships }
```

`changed` comes from the **per-table content fingerprints Phase 8 already computes** (§2c). The table→table
graph is exactly the graph Stage 0 computed from metadata (99.82% survival), now built in-engine from
`_tciFieldInfoMap`'s `FIRelationship` targets.

**This is dramatically simpler than Phase 8's invalidation** — a relationship graph over tables, not a
node-level `DepGraph` over an existentially-keyed DMap.

### 5.3 Consistency: are reused and rebuilt parsers compatible?

Yes, and this is the load-bearing subtlety. A rebuilt table's parsers will mint *fresh* shared types (e.g.
`Int_comparison_exp`) while reused tables hold the previous build's. Two objects, same name.

`collectTypeDefinitions` (`Collect.hs:182-202`) keys by **name** and, on a repeat, compares
**structurally** — `unless (someOld == someNew) $ throwError ConflictingDefinitions`. It does *not* use
`Unique` (the code notes: *"formerly it had Uniques; see #3685"*). Structurally identical duplicates
therefore pass. **Phase 9 does not require the memo table to persist.**

⚠ This leans on `Eq` instances the parser library itself calls "dodgy" (`Collect.hs:126-131`). The §8 SDL
gate is what verifies it, and it must pass before the flag defaults on.

## 6. What this replaces

**Delete from Phase 8** once Phase 9 measures faster:

- `DepGraph`, `evictWith`, `EvictionStats`, `memoKeyName`/`memoKeyArg`, `MemoEntry` (and its `~` StrictData trap)
- `invalidatedByTables` + the whole memo-key classifier and its `Note [Memo key classification]`
- `Typeable (ScalarType b)` as a `Backend` superclass
- `runMemoizeTWith` / `MemoCache` — `runMemoizeT` reverts to its original one-liner

**Keep from Phase 8** (the parts that were right):

- Per-table content fingerprints + `getTableIdentifierName` threading (2c)
- `MemoCacheGateSpec` — the differential SDL gate (2d), retargeted at Phase 9
- The store scaffolding: `MemoStore`, `newMemoStore`, its `buildSchemaCacheRule` wiring, and the
  serialisation argument (rebuilds are serialised by `withMVarMasked`, `AppStateRef.hs:126-136`)

Net: **less code than today**, and no existential key casting.

## 7. Result — MEASURED 2026-07-15 (Stage 9d): **3.21x**

Full A/B, fresh non-profiled engines, 5 reps, same fixture and harness Phase 8 was measured on:

| operation | size | baseline | **Phase 9** | speedup | (Phase 8 was) |
|---|---|--:|--:|--:|--:|
| **TRACK** | large (600) | 1.493 | **0.465** | **3.21x** | 1.31x |
| **UNTRACK** | large | 1.412 | **0.483** | **2.92x** | 1.30x |
| ALTER ADD | large | 1.658 | **0.724** | 2.29x | 1.29x |
| ALTER DROP | large | 1.676 | **0.764** | 2.19x | 1.27x |
| TRACK | medium (200) | 0.712 | 0.347 | 2.05x | 1.21x |
| UNTRACK | medium | 0.682 | 0.377 | 1.81x | 1.14x |
| TRACK | small (2) | 0.360 | 0.376 | 0.96x | 1.15x |
| UNTRACK | small | 0.320 | 0.321 | 1.00x | 0.98x |

**~2.5x better than Phase 8, from less code.**

**The §2 ablation was accurate.** It put the walk-free build at 0.976s on the probe; probe absolutes run ~0.5s
above A/B averages, which lands at ~0.47s — measured **0.465s**. (§7.1's "~2x" below was arithmetically
sloppy: it compared a probe absolute against an A/B baseline. The *ratio* prediction held exactly.) This is
the first prediction in this project to survive the harness, and the only one that came from measuring the
intervention rather than reading the code.

**Small schemas: neutral (0.96x–1.07x).** ⚠ An earlier draft called this "regression resolved" versus Phase
8's 0.89x. That was **over-reading noise**: across three runs small ops sit at 0.96x–1.07x both before and
after the §10.2 fix, and 5 reps of a ~0.3s operation cannot resolve a 4% effect. There was never a
small-schema regression to resolve; Phase 8's 0.89x was most likely the same noise.

**⚠ Read the flag-ON time, not the speedup.** Across three A/B runs the baseline for large TRACK has been
1.480 / 1.493 / 1.313 (±15%), while the flag-ON time has been 0.465 / 0.468. **The stable measured fact is
"large TRACK costs ~0.46s with the cache on"**; the ratio inherits the baseline's drift. Phase 9 is ~2.8–3.2x
depending on which baseline you draw against. Quoting "3.21x" as *the* number is over-precise.

**§10.2 (double fingerprint) — FIXED, and it changed nothing measurable.** `schemaContentKey` now computes
the per-table `toJSON` once and shares it with the per-table cache instead of each computing its own.
Flag-ON times before/after: TRACK large 0.465 → 0.468, UNTRACK 0.483 → 0.455, ALTER ADD 0.724 → 0.743 — all
noise. The duplicated work was real but cheap *on this fixture*, whose tables are `tbl_N` with a handful of
columns. Real `app_test` (`sys`) tables are wider and it may matter more there, but that is unmeasured and
should not be claimed. The fix is kept because it removes genuine duplicated work, not because it bought
anything here.

Still not done: the fingerprint's `sortOn encode` — serialising every table's `Value` to a `ByteString` only
to get a deterministic order — is plausibly the more expensive half. It could be dropped by keying an
`Object` on `toTxt tableName` (aeson's `KeyMap` `Eq` is order-independent). **Deliberately not done:** in
`TableFieldCache` a `toTxt` collision causes over-invalidation (safe), but in `schemaContentKey` it would
merge two tables under one key, last-write-wins, and a change to the shadowed table would **not move the
key** — under-detection, i.e. a silently stale schema. Within a partition all tables share a schema and
names are unique, so it cannot collide; but that invariant should be established rather than assumed before
trading it for an unmeasured gain.

**§5.3 confirmed under load:** no "conflicting definitions" errors in the engine log across the full A/B, so
rebuilt tables minting fresh shared types do coexist with reused ones. `collectTypeDefinitions` comparing
structurally rather than by `Unique` holds in practice, not just in the unit gate.

### 7.1 Original (pre-measurement) expectation — retained for the record

Projected from §2: skipping the walk removes ~0.675s of a ~1.65s track ⇒ **~2x**, versus Phase 8's 1.31x.
A real cache skips 600 of 601 tables, so ~99.8% of that.

**Do not trust this number.** The last two predictions in this project were wrong (4.7x; "assembly is the
rest"), both from inference rather than measurement. §2's ablation *is* a measurement of this exact
intervention, which is the only reason to believe it — but it must be confirmed by the A/B harness before
any claim is made.

The small-schema regression (Phase 8: 0.89x-0.98x) should also disappear, since the per-table `toJSON`
fingerprint replaces rather than adds to the walk. §10.2 of Phase 8's RFC (collapsing `schemaContentKey`
with the per-table fingerprints) remains open and would help here.

## 7.2 Shipped ON by default (2026-07-16)

The flag is now an **opt-out**: `EFDisablePerTableSchemaCache` (key `disable_per_table_schema_cache`),
following the existing `EFHideStreamFields` / `EFDisablePostgresArrays` precedent rather than
`EFEnableRelaySchema`'s opt-in. Defaulting on required the opt-out form anyway, which also retires the old
name — `persistent_memo_cache` described Phase 8's design, which no longer exists.

**Verified by the startup log, not by inference** — inverting a boolean is exactly the change that compiles,
passes 1281 tests (nothing in the suite exercises flag plumbing), and is silently wrong:

| arm | `experimental_features` | large TRACK |
|---|---|--:|
| default | `[]` | **0.467s** |
| opt-out | `["disable_per_table_schema_cache"]` | 1.300s |

Large TRACK with the cache on, across four independent A/B runs: **0.465 / 0.468 / 0.468 / 0.467**. Stable to
a millisecond, while the baseline it divides drifts ±15% — which is why §7 says to quote the flag-ON time,
not the ratio.

## 8. Correctness gate

Unchanged from Phase 8 §8, and non-negotiable: **build twice — incrementally and cold — and assert
byte-identical SDL.** `MemoCacheGateSpec` already does this, on a fixture with a relationship (`album` 1—*
`track`) because production metadata has almost none and would pass a broken evictor.

**The gate was verified to fail** when the classifier was sabotaged. Re-verify the same way for Phase 9:
break the invalidation deliberately and confirm the SDL diverges. A differential test that cannot fail is
theatre.

Risk is unchanged in kind: under-invalidation ⇒ silently stale schema, no crash, no log line. The bias stays
asymmetric — when in doubt, rebuild.

## 9. Staging

| stage | scope | gate |
|---|---|---|
| **9a** | Table→table relationship graph + `invalidatedTables`, with unit tests | reverse reachability, cycles terminate |
| **9b** | `Dynamic` per-table store + `withTableFieldsCache` wrapper | round-trip; `fromDynamic` failure ⇒ miss |
| **9c** | Thread the wrapper into both loops, behind a flag, OFF by default | SDL gate green + **sabotage check** |
| **9d** | A/B vs baseline **and** vs Phase 8 | is it actually ~2x? |
| **9e** | Delete Phase 8's machinery (§6) | tests green, A/B unchanged |

**9d before 9e.** Do not delete Phase 8 until Phase 9 is measured faster — otherwise a regression leaves
nothing to fall back to.

## 10. Ops notes (learned the hard way)

- The engine takes **~276s to boot** on the 2104-table fixture. Readiness timeouts must exceed 300s; 90s
  silently kills it mid-boot and looks like a hang.
- `pkill -f <pattern>` / `pgrep -f <pattern>` from an inline shell command **match the caller's own cmdline**
  and self-kill (exit 144) or spin forever. Use `pkill -x` (process name) or put the pattern in a script.
- Each A/B arm needs a **fresh engine** — `schema-cache-bench.sh` warns a long-running one drifts several x
  slower as heap/GC accumulate.
- Bench fixture = the `postgres` DB (s1..s5, ~2104 tables, **zero relationships**). Representative for
  *performance* (real `app_test` is also relationship-poor: 28 across 653) but **useless for correctness** —
  that is what the SDL gate's synthetic fixture is for.

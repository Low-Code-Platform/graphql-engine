# RFC — Order-preserving JSON on the input path

## 1. Summary

Today the key order of a JSON object sent through a GraphQL mutation is **not** the key order
stored in Postgres. Keys come back sorted alphabetically. This RFC describes what it would take
to preserve the client's key order end-to-end, why it is not a configuration switch, and a phased
design scoped to the only case that can actually benefit.

**Status: implemented and ON by default**, with `disable_ordered_json_input` as an escape hatch.
See §11 for what shipped, and §7 for the two risks that were open when this was written and have
now been measured. It first shipped opt-in as `ordered_json_input`; §11.4 records the flip and what
had to change to make it a sane default. §8 remains a valid zero-engine-change alternative for
anyone on a released build.

## 2. Observed behaviour (measured)

One payload, `{"zebra":1,"apple":2,"b":3,"aardvark":4}`, written to a Postgres source and read back:

| Path | `json` column | `jsonb` column |
| --- | --- | --- |
| Insert via GraphQL mutation (variable) | `aardvark, apple, b, zebra` — alphabetical | `b, apple, zebra, aardvark` |
| Insert via GraphQL mutation (inline literal) | alphabetical | normalized |
| Insert via `run_sql` | **preserved** | normalized |
| Read back via GraphQL | matches disk exactly — **preserved** | — |

Two independent mechanisms are at work, and they must not be conflated:

1. **`jsonb` normalization (Postgres).** `jsonb` is a decomposed binary format: keys sort by
   *length first*, then bytewise; duplicate keys collapse to the last; whitespace is dropped.
   This is inherent to the type and outside the engine's control.
2. **Alphabetical sorting (the engine).** This one is ours, and it is the subject of this RFC.
   It applies even to `json` columns, which Postgres otherwise stores verbatim.

The read path is already order-faithful: the engine has Postgres build the response JSON and
streams those bytes without reparsing. **Only writes lose ordering.**

## 3. Why it is not a switch

The engine's JSON currency is `Data.Aeson.Value`, whose `Object` is a `KeyMap`. In aeson 2.x the
`ordered-keymap` cabal flag **defaults to `True`** (`aeson-2.2.3.0/aeson.cabal:49-52`; not
overridden in `cabal.project.freeze`), so `KeyMap` is backed by `Data.Map.Strict` and iterates in
sorted key order.

Flipping that flag off does **not** help: the `#else` branch
(`aeson-2.2.3.0/src/Data/Aeson/KeyMap.hs:346-357`) is `HashMap Key v`, which iterates in *hash*
order. Neither backing store records insertion order, because `Object` is a map by construction.
Turning the flag off would replace deterministic-alphabetical with arbitrary-and-unstable, change
key order in every JSON the engine emits (metadata API, logs, error payloads), and force a rebuild
of aeson and everything downstream. It is strictly worse.

The information is destroyed at parse time, upstream of anything JSON-column-specific. There is no
"stop sorting JSON fields" knob to add, because by the time any JSON-column code runs, the order
is already gone.

## 4. Where the order is lost

Four distinct points, all of which a fix must address:

| # | Location | Type | Effect |
| --- | --- | --- | --- |
| L1 | `server/src-lib/Hasura/GraphQL/Transport/HTTP/Protocol.hs:63` | `type VariableValues = HashMap G.Name J.Value` | Variable values are aeson `Value`; objects inside are already `KeyMap` after `parseBody` (`server/src-lib/Hasura/Server/App.hs:245-247`, `eitherDecode'`). |
| L2 | `server/lib/graphql-parser/src/Language/GraphQL/Draft/Syntax.hs:319` | `VObject (HashMap Name (Value var))` | Inline object literals lose order in the GraphQL parser AST. |
| L3 | `server/lib/schema-parsers/src/Hasura/GraphQL/Parser/Internal/Convert.hs:41-50` | `graphQLToJSON`, `G.VObject o -> J.toJSON (... <$> o)` | Converts the AST to aeson, re-imposing alphabetical order — this is why L2's arbitrary hash order surfaces as *alphabetical*. |
| L4 | `server/src-lib/Hasura/Backends/Postgres/SQL/Value.hs:97-98, 217-218` | `PGValJSON PG.JSON` / `parsePGValue` | `PG.JSON` (pg-client) wraps an aeson `Value`; by here the value is already sorted. Serialized via `AE.encodeToLazyText` (`:257-264`) or `PG.toPrepVal` (`:296-297`). |

The funnel is `server/src-lib/Hasura/Backends/Postgres/Instances/Schema.hs:478-482`:

```haskell
P.valueToJSON (P.toGraphQLType schemaType) >=> \case
  J.Null -> P.parseError ...
  value  -> runAesonParser (parsePGValue scalarType) value
```

Every column value — of every scalar type, for every backend — passes through `valueToJSON` into
an aeson `Value`. That is the chokepoint, and also why a narrow fix is awkward: the type is shared
by everything.

## 5. Scope: only `json` columns can benefit

**This is the decisive constraint on the whole effort.** `jsonb` re-normalizes on storage no matter
what arrives, so preserving order upstream of a `jsonb` column buys exactly nothing. The work is
only meaningful for `PGJSON` columns.

Consequences:

- The feature would apply to `json` columns on Postgres-family backends only.
- Most users are on `jsonb` (it is the default recommendation, and the only one supporting
  `_contains` and GIN indexes). The addressable audience is small.
- Anyone who takes this feature gives up `jsonb`'s operators — so they are trading query power for
  byte fidelity, which is usually the wrong trade unless they are verifying signatures.

## 6. Design

### 6.1 The available building block

`server/lib/aeson-ordered/` already defines an insertion-ordered JSON value:

- `newtype Object = Object_ (InsOrdHashMap Text Value)` (`:84`)
- a working attoparsec decoder: `value`, `decode`, `eitherDecode` (`:221-225`)
- `fromOrdered :: Value -> J.Value` (`:195-202`) — a ready-made adapter back to aeson
- an order-preserving serializer already exists at
  `server/lib/hasura-json-encoding/src/Hasura/EncJSON.hs:199-208` (`encJFromOrderedValue`, via `JO.toList`)

It is currently used only on the response path. Both directions we need therefore already exist and
are exercised in production code.

### 6.2 Phase 1 — variables (covers the reported use case)

1. **L1.** `type VariableValues = HashMap G.Name JO.Value`. Decode the `variables` field of the
   request body with `JO.eitherDecode` rather than aeson. `parseBody` keeps returning an aeson
   `Value` for logging/telemetry; only the variables map changes representation.
2. **L4a.** `InputValue v = GraphQLValue (Value v) | JSONValue JO.Value`
   (`server/lib/schema-parsers/src/Hasura/GraphQL/Parser/Variable.hs:75-77`).
3. **L3.** Keep `valueToJSON :: ... -> m J.Value` for every existing caller by defining it as
   `fmap JO.fromOrdered . valueToOrderedJSON`. Add `valueToOrderedJSON` and use it **only** from
   the `PGJSON` branch of `columnParser`. This is what keeps the blast radius survivable: no other
   scalar parser changes behaviour or type.
4. **L4b.** Add `PGValJSONRaw !Text` to `PGScalarValue`, carrying pre-serialized JSON text produced
   by `encJFromOrderedValue`. Encode it as:
   - `txtEncodedVal`: `TELit rawText`
   - `binEncoder`: `(PTI.json, Just (TE.encodeUtf8 rawText, PQ.Text))` — precedent at
     `server/src-lib/Hasura/Backends/Postgres/SQL/Value.hs:304` (`PGValUnknown`), and the OID mapping already exists at
     `server/src-lib/Hasura/Backends/Postgres/SQL/Types.hs:877` (`PGJSON -> PTI.json`).
   Only `parsePGValue`'s `PGJSON` branch constructs it; `PGJSONB` keeps using `PGValJSONB`.

Inline literals still sort after Phase 1 (L2 untouched) — acceptable, since clients hitting this
send documents as variables.

### 6.3 Phase 2 — inline literals (optional)

Change `VObject` in `server/lib/graphql-parser` from `HashMap Name (Value var)` to
`InsOrdHashMap Name (Value var)`, and make `graphQLToJSON`'s ordered counterpart preserve it.
This is a separate published library with its own test suite and a wide reverse-dependency surface
inside the repo. Only do this if a customer demonstrably needs inline-literal ordering.

### 6.4 Feature gating

Ship behind an experimental feature (`EFOrderedJsonInput`), defaulting **off**, in the style of
`EFEnableRelaySchema`. When off, the `PGJSON` branch behaves exactly as today. This keeps the
change reversible and keeps the risk in §7 opt-in.

## 7. Risks

1. ~~**Missing instances (concrete blocker).**~~ **Resolved.** `Ord` and `TH.Lift` were written for
   `JO.Value` and `JO.Object` in `server/lib/aeson-ordered/src/Data/Aeson/Ordered.hs`. `Ord Object`
   compares the **key-sorted** association list, not `toList`: `InsOrdHashMap`'s `Eq` is
   order-insensitive (see risk 2), so comparing `toList` would give `a == b` alongside
   `compare a b /= EQ` and silently corrupt any `Data.Map`/`Data.Set` keyed on a type containing an
   `Object`. `TH.Lift` follows aeson's own instance, routing arrays through a list because `Vector`
   has no `Lift`.
2. ~~**Cache-key semantics (must verify before building).**~~ **Resolved — no mitigation needed.**
   `InsOrdHashMap`'s `Eq` and `Hashable` are both order-**insensitive**, and deliberately so:
   the type is `InsOrdHashMap !Int !(HashMap k (P v))`, both instances ignore the leading index, and
   `P`'s own instances discard the insertion index (`P _ a == P _ b = a == b`,
   `hashWithSalt salt (P _ x) = hashWithSalt salt x`) —
   `insert-ordered-containers-0.2.5.3:src/Data/HashMap/Strict/InsOrd.hs:157-163,192-193,236-238`.
   So `{"a":1,"b":2}` and `{"b":2,"a":1}` remain equal and equal-hashing, and cohort sharing is
   untouched. The separate worry this raises — that an order-insensitive `Eq` might cause two
   differently-ordered documents to be *conflated* and stored identically — was tested directly:
   two rows inserted by a **single** mutation whose only difference is key order are stored with
   their own distinct orders (§11, case 5).
3. **Hot-path performance.** `InsOrdHashMap` is slower than `Map` for lookup and carries more
   allocation. Variables are typically small, so the effect should be modest, but it lands on the
   per-request path and needs measurement, not assumption.
4. **Duplicate keys (confirmed limitation, with a behaviour change).** `json` permits duplicates;
   `InsOrdHashMap` does not, so repeated keys still collapse. Measured: `{"zz":1,"a":2,"a":3}`
   stores as `{"zz":1,"a":3}` with the feature on versus `{"a":2,"zz":1}` with it off. Note that the
   surviving *value* differs too — the ordered parser keeps the **last** duplicate (matching
   `jsonb`, which gives `{"a": 3, "zz": 1}`), whereas aeson kept the **first**. Postgres `json`
   itself would have preserved both. Fidelity for duplicate keys is therefore not total either way.
5. **Fidelity is bounded by the client anyway.** A browser client calling `JSON.stringify` has
   already fixed key order at that point. "Preserved" means "as the client serialized it", which is
   sufficient for signing/ETag use cases but is not a round-trip guarantee of an author's ordering.

## 8. Workaround (no engine change) — what we should ship first

A JSON *string* passes through aeson untouched, since it is an opaque scalar with no keys to sort.
Send the document as a string and unwrap it in Postgres, where `::json` preserves the text verbatim.
This keeps **one column name** for both read and write:

```sql
CREATE FUNCTION unwrap_json() RETURNS trigger AS $$
DECLARE inner_text text;
BEGIN
  IF NEW.payload IS NOT NULL AND json_typeof(NEW.payload) = 'string' THEN
    inner_text := NEW.payload #>> '{}';
    BEGIN
      NEW.payload := inner_text::json;
    EXCEPTION WHEN others THEN
      NULL;   -- not valid JSON: leave the string value untouched
    END;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER t_unwrap BEFORE INSERT OR UPDATE ON t
FOR EACH ROW EXECUTE FUNCTION unwrap_json();
```

The client's only change is sending `JSON.stringify(doc)` instead of `doc`. Verified: insert,
update, order preservation, and backward compatibility with clients still sending plain objects.
The `EXCEPTION` block is required — without it a legitimate non-JSON string value fails with
`invalid input syntax for type json`.

Note this is the same "JSON in disguise" heuristic the engine already applies to array elements at
`server/src-lib/Hasura/Backends/Postgres/SQL/Value.hs:335-347`, so the ambiguity it introduces (a client that genuinely wants to store the
*string* `'{"a":1}'` gets an object instead) is a shape of ambiguity already present in the codebase.

## 9. Testing

- Unit: `valueToOrderedJSON` preserves order for nested objects/arrays; `PGValJSONRaw` encodes
  identically under both `txtEncoder` and `binEncoder`.
- api-tests: a Postgres spec inserting a known-out-of-order document into a `json` column via
  mutation (variable **and** inline literal) and asserting the exact serialization on read, plus a
  `jsonb` control asserting normalization still occurs. Mirror
  `Test.Databases.Postgres.JsonbSpec`.
- Regression: subscription cohort sharing across two clients whose variables differ only in key
  order must remain a single cohort (risk 2).
- Benchmark: request throughput with a large variable payload, flag on vs off.

## 10. Decision

Implemented as Phase 1 and made the default, with `disable_ordered_json_input` to turn it off. §5
still holds — only `json`-column users are affected — but the conclusion drawn from it changed: a
`json` column stores its document verbatim, so sorting its keys was the engine imposing itself on
data it was asked to store as-is, and the users affected are exactly the ones who would want it.
Phase 2 (inline literals, §6.3) was **not** taken — it requires changing `VObject` in the separately
published `graphql-parser` library, and clients that care about byte fidelity send documents as
variables.

## 11. What shipped

On by default. Turn it off with
`HASURA_GRAPHQL_EXPERIMENTAL_FEATURES=disable_ordered_json_input`. Only Postgres `json` columns
change behaviour; everything else — including `jsonb` — is byte-identical either way.

### 11.1 Code

| Loss point | What changed |
| --- | --- |
| L1 | `VariableValues` is now `HashMap G.Name JO.Value` (`Transport/HTTP/Protocol.hs`). The body is parsed **once**, with the order-preserving decoder, and the aeson `Value` the rest of the pipeline wants is derived via `JO.fromOrdered`; `withOrderedVariables` / `withOrderedVariablesInReqs` then substitute the ordered values. Structural decoding still goes through `decodeValue` on that derived value, so its validation and error messages are unchanged — only the message for a body that is not valid JSON at all now comes from the ordered decoder. Wired at `Server/App.hs` (`parseBodyWithOrderedVariables`, for `/v1/graphql` and persisted queries) and `Transport/WebSocket.hs` (`withOrderedStartMsgVariables`, for `start`/`subscribe`). Setting `disable_ordered_json_input` falls back to `parseBody` verbatim, so the escape hatch is a true revert. REST custom endpoints decode their body params with `JO.decode` instead of aeson. |
| L2 | Untouched (Phase 2 not taken). Inline object literals are still stored alphabetically. |
| L3 | `valueToOrderedJSON` added alongside `valueToJSON`, which is now defined as `fmap JO.fromOrdered . valueToOrderedJSON` so there is one conversion to keep correct. `graphQLToOrderedJSON` sorts inline-literal keys explicitly, preserving today's alphabetical output rather than leaking an arbitrary hash order. |
| L4 | `PGValJSONRaw !Text` added to `PGScalarValue`, carrying pre-serialized bytes; `txtEncodedVal` emits them verbatim and `binEncoder` sends them as `(PTI.json, Text)`. Constructed only by the `(PGJSON, PreserveJsonInputOrder)` branch of `columnParser` (`Backends/Postgres/Instances/Schema.hs`). |

Every other consumer of `InputValue`'s JSON payload calls `JO.fromOrdered` and behaves exactly as
before: remote-schema forwarding (order is not preserved across that hop anyway), the parameterized
query hash, and the BigQuery/MSSQL scalar parsers.

**Known gap: `json[]` columns.** The branch is keyed on `scalarType` being exactly `PGJSON`, so an
array-of-json column (`PGArray PGJSON`) takes the old path and is still sorted. Covering it means
mapping the ordered array to `PGValArray [PGValJSONRaw …]` inside the column parser, including the
nested-null cases — real extra logic for a rare column type, so it was left out deliberately rather
than overlooked. `buildArrayLiteral`'s `encodeElement` does already handle `PGValJSONRaw` correctly
(escaping it as an array element, as `fromJson` does); that case is unreachable today and is there
so the fallback branch cannot silently emit an unescaped document if the array path is ever added.

### 11.2 Measured, against Postgres 16.13

Each case run twice against the same engine build, with the behaviour on (default) and off
(`disable_ordered_json_input`). `json` values are
read back as text via `run_sql`, because any assertion that parses the value cannot see key order.
Document sent: `{"zebra":1,"apple":2,"b":3,"aardvark":4}`.

| # | Case | Feature on | Feature off |
| --- | --- | --- | --- |
| 1 | variable → `json` | `{"zebra":1,"apple":2,"b":3,"aardvark":4}` | `{"aardvark":4,"apple":2,"b":3,"zebra":1}` |
| 1 | variable → `jsonb` | `{"b": 3, "apple": 2, "zebra": 1, "aardvark": 4}` | identical |
| 2 | nested objects, and objects inside arrays | `{"outer":{"zebra":1,"apple":2},"list":[{"z":1,"a":2}]}` | `{"list":[{"a":2,"z":1}],"outer":{"apple":2,"zebra":1}}` |
| 3 | inline literal (L2, unchanged) | `{"aardvark":4,...,"zebra":1}` | identical |
| 4 | whole `objects:` array as one variable | preserved | sorted |
| 5 | two rows in **one** mutation differing only in key order | `{"a":1,"b":2}` and `{"b":2,"a":1}` — **not conflated** | both `{"a":1,"b":2}` |
| 6 | a JSON *string* variable | `"hello"` | identical |
| 7 | duplicate keys | `{"zz":1,"a":3}` | `{"a":2,"zz":1}` |
| 8 | read path | returns the stored order | identical |

Case 5 is the one that matters for risk 2, and case 1's `jsonb` row for §5.

### 11.3 Tests

- `server/lib/api-tests/src/Test/Databases/Postgres/OrderedJsonInputSpec.hs` — covers cases 1, 2, 3
  and a feature-off control. Needed a new harness helper, `postGraphqlRaw` /
  `Harness.Http.postRawValueWithStatus`, which posts an already-serialized body: aeson's `encode`
  re-sorts object keys, so a test that builds its body through aeson cannot send an out-of-order
  document in the first place. That is risk 5 in miniature — fidelity is bounded by the client.
- `graphql-engine-tests`: 1281 examples, 0 failures.

### 11.4 Flipping the default

It shipped opt-in as `ordered_json_input`, then was made the default with
`disable_ordered_json_input` as the escape hatch, following the shape of
`EFDisablePerTableSchemaCache`. Two things had to change for that to be defensible.

**The double parse had to go.** While the behaviour was opt-in, the implementation deliberately left
`parseBody` alone and parsed the body a *second* time with the ordered decoder, purely to recover
the key order. That was the right trade then — a deployment that had not asked for the feature paid
nothing, and the aeson parse kept every error message identical. As the default it is indefensible:
it puts a full extra JSON parse of every GraphQL request body on the hot path for everyone. So the
default path now parses once, with the ordered decoder, and derives the aeson `Value` via
`JO.fromOrdered`. This is risk 3 in §7, resolved by removing the cost rather than measuring it.

The cost of that: the error message for a body that is not valid JSON at all now comes from the
ordered decoder's attoparsec parser rather than aeson's. Structural errors are unaffected —
`decodeValue` still runs on an aeson `Value` identical to what aeson's own parser would have built.
Setting `disable_ordered_json_input` restores `parseBody` verbatim, so the hatch is a true revert
and not an approximation.

**What a deployment can notice.** Stored key order in `json` columns changes from alphabetical to
whatever the client sent. That is the point, but it is a change to bytes on disk, so anything
derived from those bytes changes with it: a checksum or ETag computed over the stored text, a diff
against a golden file, a test asserting the sorted form. Duplicate keys also now keep the last
value rather than the first (§7 risk 4). `jsonb` columns, inline literals, and every non-`json`
scalar are untouched. The escape hatch exists for exactly these cases.

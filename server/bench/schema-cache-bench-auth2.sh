#!/usr/bin/env bash
#
# Wall-time benchmark for the per-(DB schema) GraphQL schema-cache rebuild.
#
# TWO-SCHEMA variant of schema-cache-bench-auth.sh. Instead of small/medium/large
# it compares just SMALL vs LARGE — for deployments that only have TWO tracked
# schemas of distinct size (e.g. the 'default' source here: platform=10 vs
# sys=369 tables). Same Authorization/admin-secret auth handling as the auth
# variant: an "Authorization: Bearer <token>" header (token re-minted per request
# via AUTH_TOKEN_CMD, so a rotating/expiring token survives the run) PLUS an
# "X-Hasura-Admin-Secret" header.
#
# IMPORTANT (timing correctness): the token is fetched into a shell variable
# BEFORE each curl call, so minting the token is NOT counted in curl's
# %{time_total}. The reported numbers still measure only the server round-trip.
#
# Runs against an ALREADY-RUNNING graphql-engine. For each of four
# metadata-affecting operations it compares the two schemas:
#
#   1. ALTER ADD COLUMN   - time adding a column (pure DB DDL + rebuild)
#   2. ALTER DROP COLUMN  - time dropping that column (pure DB DDL + rebuild)
#   3. TRACK TABLE        - create a table, then time pg_track_table (adds metadata write)
#   4. UNTRACK TABLE      - time pg_untrack_table (remove the table from the GraphQL schema)
#
# With the Phase 6 per-schema partitioning, each operation only rebuilds the
# CHANGED schema's GraphQL parsers, so cost scales with that schema's size:
# small < large. This benchmark confirms (and quantifies) the gradient.
#
# SCHEMA SELECTION: by default it auto-picks the smallest and largest tracked
# schema (by table count) in the source. Override with SMALL_SCHEMA / LARGE_SCHEMA.
#
# Usage:
#   HASURA_URL=https://dev-graphql-45c8e7.platform.creatingly.com \
#   HASURA_ADMIN_SECRET='...' AUTH_TOKEN='...current token...' \
#     server/bench/schema-cache-bench-auth2.sh
#
#   # rotating token:
#   AUTH_TOKEN_CMD='curl -s https://auth.example/token | jq -r .access_token' ...
#
# Environment overrides:
#   HASURA_URL                    default http://localhost:8181
#   AUTH_TOKEN_CMD                shell command that PRINTS a fresh token (re-run per request)
#   AUTH_TOKEN                    static token, used if AUTH_TOKEN_CMD unset
#   AUTH_SCHEME                   default "Bearer" (prefix before the token)
#   HASURA_ADMIN_SECRET           default "admin-secret" (X-Hasura-Admin-Secret header)
#   SOURCE                        default: first source WITH >=2 tracked schemas
#   SMALL_SCHEMA / LARGE_SCHEMA   explicit schema choices (optional)
#   REPS                          default 5
#   BENCH_TSV                     if set, append machine-readable averages here

set -euo pipefail

HASURA_URL="${HASURA_URL:-http://localhost:8181}"
AUTH_SCHEME="${AUTH_SCHEME:-Bearer}"
ADMIN_SECRET="${HASURA_ADMIN_SECRET:-admin-secret}"
REPS="${REPS:-5}"

if [ -z "${AUTH_TOKEN_CMD:-}" ] && [ -z "${AUTH_TOKEN:-}" ]; then
  echo "ERROR: set AUTH_TOKEN_CMD (a command that prints a fresh token) or AUTH_TOKEN (a static token)." >&2
  exit 1
fi

# Return the CURRENT token, re-minting via AUTH_TOKEN_CMD if provided.
get_token() {
  if [ -n "${AUTH_TOKEN_CMD:-}" ]; then
    local tok
    if ! tok="$(eval "$AUTH_TOKEN_CMD")" || [ -z "$tok" ]; then
      echo "ERROR: AUTH_TOKEN_CMD produced no token" >&2
      exit 1
    fi
    printf '%s' "$tok"
  else
    printf '%s' "$AUTH_TOKEN"
  fi
}

# (Re)build the request headers with a fresh Authorization token, BEFORE each
# curl so minting stays outside the curl %{time_total} timing window.
build_hdr() {
  HDR=(-H 'Content-Type: application/json'
       -H "X-Hasura-Admin-Secret: ${ADMIN_SECRET}"
       -H "Authorization: ${AUTH_SCHEME} $(get_token)")
}

meta()   { build_hdr; curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" -d "$1"; }
runsql() { build_hdr; curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" -d "$1" -o /dev/null; }

CREATED_COLS=()
CREATED_TBLS=()

# --- timed operations (print server wall-time in seconds) -------------------
add_col_timed() { # schema table col
  build_hdr
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" \
    -d "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" ADD COLUMN $3 int;\"}}" \
    -o /dev/null -w "%{time_total}"
}
drop_col_timed() { # schema table col
  build_hdr
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" \
    -d "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" DROP COLUMN IF EXISTS $3;\"}}" \
    -o /dev/null -w "%{time_total}"
}
track_timed() { # schema table
  build_hdr
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" \
    -d "{\"type\":\"pg_track_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" \
    -o /dev/null -w "%{time_total}"
}
untrack_timed() { # schema table
  build_hdr
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" \
    -d "{\"type\":\"pg_untrack_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" \
    -o /dev/null -w "%{time_total}"
}

# --- untimed helpers (setup / teardown) -------------------------------------
drop_col()   { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" DROP COLUMN IF EXISTS $3;\"}}"; }
create_tbl() { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"CREATE TABLE IF NOT EXISTS \\\"$1\\\".\\\"$2\\\" (id serial primary key);\"}}"; }
drop_tbl()   { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"cascade\":true,\"sql\":\"DROP TABLE IF EXISTS \\\"$1\\\".\\\"$2\\\";\"}}"; }
track_q()    { meta "{\"type\":\"pg_track_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" >/dev/null; }
untrack_q()  { meta "{\"type\":\"pg_untrack_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" >/dev/null; }

# print a per-rep table + averages for one operation across the 2 sizes.
report() { # title  small_csv  large_csv
  TITLE="$1" A0="$2" A1="$3" L0="$SMALL_LABEL" L1="$LARGE_LABEL" BENCH_TSV="${BENCH_TSV:-}" python3 -c '
import os
title = os.environ["TITLE"]
labels = [os.environ["L0"], os.environ["L1"]]
data = [[float(x) for x in os.environ[k].split()] for k in ("A0", "A1")]
print()
print("### " + title)
hdr = "  rep   | " + " | ".join("%-24s" % lab for lab in labels)
print(hdr)
print("  " + "-" * (len(hdr) - 2))
for i in range(len(data[0])):
    print("  %-5d | " % (i + 1) + " | ".join("%-24.3f" % data[c][i] for c in range(2)))
avgs = [sum(c) / len(c) for c in data]
print("  " + "-" * (len(hdr) - 2))
print("  %-5s | " % "avg" + " | ".join("%-24.3f" % a for a in avgs))
print("  -> large/small = %.2fx" % (avgs[1] / avgs[0]))
tsv = os.environ.get("BENCH_TSV")
if tsv:
    with open(tsv, "a") as f:
        f.write("\t".join([title] + ["%.3f" % a for a in avgs]) + "\n")
'
}

# --- 1. Sanity-check the engine is reachable and has metadata ----------------
if ! meta '{"type":"export_metadata","args":{}}' 2>/dev/null | grep -q '"sources"'; then
  echo "ERROR: no graphql-engine with metadata at $HASURA_URL"
  echo "  Check HASURA_URL and your auth (HASURA_ADMIN_SECRET / AUTH_TOKEN[_CMD])."
  exit 1
fi

# --- 2. Discover small + large tracked schema + a table in each --------------
read -r SOURCE \
  SMALL_SCHEMA SMALL_TABLE SMALL_N \
  LARGE_SCHEMA LARGE_TABLE LARGE_N \
  TOTAL_N < <(
  meta '{"type":"export_metadata","args":{}}' \
    | SOURCE="${SOURCE:-}" SMALL_SCHEMA="${SMALL_SCHEMA:-}" LARGE_SCHEMA="${LARGE_SCHEMA:-}" python3 -c '
import sys, json, os, collections
m = json.load(sys.stdin)
sources = m.get("sources", [])
if not sources:
    sys.exit("no sources in metadata")

def schemas_of(src):
    by = collections.defaultdict(list)
    for t in src.get("tables", []):
        by[t["table"]["schema"]].append(t["table"]["name"])
    return by

want = os.environ.get("SOURCE")
if want:
    src = next((s for s in sources if s["name"] == want), None)
    if src is None:
        sys.exit("source %r not found" % want)
else:
    # first source that has >=2 tracked schemas
    src = next((s for s in sources if len(schemas_of(s)) >= 2), None)
    if src is None:
        sys.exit("no source has >=2 tracked schemas; found: %r"
                 % {s["name"]: list(schemas_of(s)) for s in sources})

by = schemas_of(src)
counts = {s: len(v) for s, v in by.items()}

ov = [os.environ.get(k, "") for k in ("SMALL_SCHEMA", "LARGE_SCHEMA")]
if all(ov):
    chosen = ov
    for s in chosen:
        if s not in by:
            sys.exit("schema %r has no tracked tables in source %r (have: %r)" % (s, src["name"], counts))
else:
    if len(by) < 2:
        sys.exit("source %r needs tables tracked in >=2 schemas; found: %r" % (src["name"], counts))
    ordered = sorted(counts, key=counts.get)
    chosen = [ordered[0], ordered[-1]]

out = [src["name"]]
for s in chosen:
    out += [s, by[s][0], str(counts[s])]
out.append(str(sum(counts.values())))
print(*out)
'
)

SMALL_LABEL="small ${SMALL_SCHEMA}(${SMALL_N})"
LARGE_LABEL="large ${LARGE_SCHEMA}(${LARGE_N})"
SCHEMAS=("$SMALL_SCHEMA" "$LARGE_SCHEMA")
# ALTER ADD/DROP COLUMN operates on a table WE create in each schema (see setup
# below), so EXISTING tracked tables are never modified. $SMALL_TABLE/$LARGE_TABLE
# (a representative existing table) are only used to report the discovered schema.
COLTBL="bench_cols"

echo
echo "================ schema-cache rebuild benchmark (2-schema) ============="
echo "engine:  $HASURA_URL"
echo "auth:    Authorization: ${AUTH_SCHEME} <token>  ($([ -n "${AUTH_TOKEN_CMD:-}" ] && echo 're-minted via AUTH_TOKEN_CMD each request' || echo 'static AUTH_TOKEN'))"
echo "         X-Hasura-Admin-Secret: <set>"
echo "source:  $SOURCE  ($TOTAL_N tracked tables across all schemas)"
echo "SMALL :  $SMALL_SCHEMA  ($SMALL_N tables)  -> col ops on created $SMALL_SCHEMA.$COLTBL"
echo "LARGE :  $LARGE_SCHEMA  ($LARGE_N tables)  -> col ops on created $LARGE_SCHEMA.$COLTBL"
echo "note:    existing tracked tables are NEVER altered (column ops use a created table)"
echo "reps:    $REPS"
echo "======================================================================="

if [ -n "${BENCH_TSV:-}" ]; then
  : > "$BENCH_TSV"
  printf '#meta\tsource=%s\tsmall=%s(%s)\tlarge=%s(%s)\ttotal=%s\n' \
    "$SOURCE" "$SMALL_SCHEMA" "$SMALL_N" "$LARGE_SCHEMA" "$LARGE_N" "$TOTAL_N" >> "$BENCH_TSV"
  echo "(writing machine-readable averages to $BENCH_TSV)"
fi

# --- 3. Setup: create + track a dedicated bench table in each schema ----------
# All ALTER ADD/DROP COLUMN timing happens on THIS table, so existing tracked
# tables are never altered. It still lives in the target schema, so a column
# change still rebuilds that schema's parsers (cost scales with schema size).
for i in 0 1; do
  create_tbl "${SCHEMAS[$i]}" "$COLTBL"; CREATED_TBLS+=("${SCHEMAS[$i]}.$COLTBL")
  track_q "${SCHEMAS[$i]}" "$COLTBL"
done

# Warmup (settle parser caches for both schemas + both code paths) -------------
for i in 0 1; do
  add_col_timed "${SCHEMAS[$i]}" "$COLTBL" bench_warm >/dev/null
  CREATED_COLS+=("${SCHEMAS[$i]}.$COLTBL.bench_warm")
  drop_col "${SCHEMAS[$i]}" "$COLTBL" bench_warm
  create_tbl "${SCHEMAS[$i]}" bench_warm; CREATED_TBLS+=("${SCHEMAS[$i]}.bench_warm")
  track_q "${SCHEMAS[$i]}" bench_warm; untrack_q "${SCHEMAS[$i]}" bench_warm; drop_tbl "${SCHEMAS[$i]}" bench_warm
done

# --- 4a/4b. ALTER ADD COLUMN + ALTER DROP COLUMN ------------------------------
add0=(); add1=(); drp0=(); drp1=()
for rep in $(seq 1 "$REPS"); do
  col="bench_c${rep}"
  for i in 0 1; do
    sch="${SCHEMAS[$i]}"; tbl="$COLTBL"
    at=$(add_col_timed "$sch" "$tbl" "$col");  CREATED_COLS+=("$sch.$tbl.$col")
    dt=$(drop_col_timed "$sch" "$tbl" "$col")
    case $i in
      0) add0+=("$at"); drp0+=("$dt");;
      1) add1+=("$at"); drp1+=("$dt");;
    esac
  done
done
report "ALTER ADD COLUMN"  "${add0[*]}" "${add1[*]}"
report "ALTER DROP COLUMN" "${drp0[*]}" "${drp1[*]}"

# --- 4c/4d. TRACK + UNTRACK TABLE ---------------------------------------------
trk0=(); trk1=(); unt0=(); unt1=()
for rep in $(seq 1 "$REPS"); do
  n="bench_trk_${rep}"
  for i in 0 1; do
    sch="${SCHEMAS[$i]}"
    create_tbl "$sch" "$n"; CREATED_TBLS+=("$sch.$n")
    tt=$(track_timed "$sch" "$n")
    ut=$(untrack_timed "$sch" "$n")
    drop_tbl "$sch" "$n"
    case $i in
      0) trk0+=("$tt"); unt0+=("$ut");;
      1) trk1+=("$tt"); unt1+=("$ut");;
    esac
  done
done
report "TRACK TABLE"   "${trk0[*]}" "${trk1[*]}"
report "UNTRACK TABLE" "${unt0[*]}" "${unt1[*]}"

# --- teardown: untrack + drop the per-schema bench column tables --------------
for i in 0 1; do
  untrack_q "${SCHEMAS[$i]}" "$COLTBL"
  drop_tbl "${SCHEMAS[$i]}" "$COLTBL"
done

# --- 5. List the temporary objects this run created (all already dropped) -----
echo
echo "### temporary objects created during this run (all dropped afterwards)"
echo "columns added (${#CREATED_COLS[@]}):"
printf '  %s\n' "${CREATED_COLS[@]}"
echo "tables created (${#CREATED_TBLS[@]}):"
printf '  %s\n' "${CREATED_TBLS[@]}"

echo
echo "======================================================================="
echo "Done. Expect cost to grow small < large in each section,"
echo "tracking the rebuilt schema's table count."
echo "======================================================================="

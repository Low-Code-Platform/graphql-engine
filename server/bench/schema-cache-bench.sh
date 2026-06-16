#!/usr/bin/env bash
#
# Wall-time benchmark for the per-(DB schema) GraphQL schema-cache rebuild.
#
# Runs against an ALREADY-RUNNING graphql-engine (you start it yourself). For
# each of three metadata-affecting operations it compares THREE tracked schemas
# of increasing size — SMALL vs MEDIUM vs LARGE:
#
#   1. ALTER ADD COLUMN   - time adding a column (pure DB DDL + rebuild)
#   2. ALTER DROP COLUMN  - time dropping that column (pure DB DDL + rebuild)
#   3. TRACK TABLE        - create a table, then time pg_track_table (adds metadata write)
#   4. UNTRACK TABLE      - time pg_untrack_table (remove the table from the GraphQL schema)
#
# With the Phase 6 per-schema partitioning, each operation only rebuilds the
# CHANGED schema's GraphQL parsers, so cost scales with that schema's size:
# small < medium < large. This benchmark confirms (and quantifies) the gradient.
#
# SCHEMA SELECTION: by default it auto-picks the smallest / a middle / the largest
# tracked schema (by table count) and prints the chosen sizes. To get a meaningful
# gradient your DB must have schemas of DISTINCT sizes; otherwise medium and large
# will measure the same. Override explicitly with SMALL_SCHEMA / MEDIUM_SCHEMA /
# LARGE_SCHEMA (a representative table in each is auto-selected).
#
# WHY A curl/shell BENCHMARK (and not tasty-bench):
#   The rebuild happens entirely server-side, in another process.
#   server/bench/SchemaCacheRebench.hs is a tasty-bench HTTP *client*, so it only
#   measures client CPU and is blind to the rebuild cost. curl's %{time_total}
#   measures the real end-to-end server wall-time.
#
# FOR TRUSTWORTHY NUMBERS, run the engine you point this at like so:
#   1. OPT binary, not the hpc-coverage dev.sh build (coverage inflates ~2-3x):
#        cabal run -v0 exe:graphql-engine -- serve
#   2. A FRESH engine. A long-running engine drifts ~5x slower as heap/GC
#      accumulates after many rebuilds; restart it before a measurement session.
#      (This script does many rebuilds, so absolute numbers in later sections may
#      drift upward; the size comparison within each section stays valid.)
#
# Usage:
#   HASURA_URL=http://localhost:8181 HASURA_ADMIN_SECRET="" \
#     server/bench/schema-cache-bench.sh
#
# Environment overrides:
#   HASURA_URL                                   default http://localhost:8181
#   HASURA_ADMIN_SECRET                          default "" (X-Hasura-Admin-Secret)
#   SOURCE                                       default: first source in metadata
#   SMALL_SCHEMA / MEDIUM_SCHEMA / LARGE_SCHEMA  explicit schema choices (optional)
#   REPS                                         default 5

set -euo pipefail

HASURA_URL="${HASURA_URL:-http://localhost:8181}"
ADMIN_SECRET="${HASURA_ADMIN_SECRET:-}"
REPS="${REPS:-5}"

HDR=(-H 'Content-Type: application/json' -H "X-Hasura-Admin-Secret: $ADMIN_SECRET")

meta()   { curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" -d "$1"; }
runsql() { curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" -d "$1" -o /dev/null; }

# Track every temporary object we create, to print at the end.
CREATED_COLS=()
CREATED_TBLS=()

# --- timed operations (print server wall-time in seconds) -------------------
add_col_timed() { # schema table col
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" \
    -d "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" ADD COLUMN $3 int;\"}}" \
    -o /dev/null -w "%{time_total}"
}
drop_col_timed() { # schema table col
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v2/query" \
    -d "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" DROP COLUMN IF EXISTS $3;\"}}" \
    -o /dev/null -w "%{time_total}"
}
track_timed() { # schema table
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" \
    -d "{\"type\":\"pg_track_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" \
    -o /dev/null -w "%{time_total}"
}
untrack_timed() { # schema table
  curl -s "${HDR[@]}" -X POST "$HASURA_URL/v1/metadata" \
    -d "{\"type\":\"pg_untrack_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" \
    -o /dev/null -w "%{time_total}"
}

# --- untimed helpers (setup / teardown) -------------------------------------
drop_col()   { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"ALTER TABLE \\\"$1\\\".\\\"$2\\\" DROP COLUMN IF EXISTS $3;\"}}"; }
create_tbl() { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"sql\":\"CREATE TABLE IF NOT EXISTS \\\"$1\\\".\\\"$2\\\" (id serial primary key);\"}}"; }
drop_tbl()   { runsql "{\"type\":\"run_sql\",\"args\":{\"source\":\"$SOURCE\",\"cascade\":true,\"sql\":\"DROP TABLE IF EXISTS \\\"$1\\\".\\\"$2\\\";\"}}"; }
track_q()    { meta "{\"type\":\"pg_track_table\",\"args\":{\"source\":\"$SOURCE\",\"table\":{\"name\":\"$2\",\"schema\":\"$1\"}}}" >/dev/null; }

# print a per-rep table + averages for one operation across the 3 sizes.
# If BENCH_TSV is set, also append "title<TAB>small_avg<TAB>medium_avg<TAB>large_avg"
# to that file, for machine-readable A/B comparison (see schema-cache-bench-compare.sh).
report() { # title  small_csv  medium_csv  large_csv
  TITLE="$1" A0="$2" A1="$3" A2="$4" L0="$SMALL_LABEL" L1="$MEDIUM_LABEL" L2="$LARGE_LABEL" BENCH_TSV="${BENCH_TSV:-}" python3 -c '
import os
title = os.environ["TITLE"]
labels = [os.environ["L0"], os.environ["L1"], os.environ["L2"]]
data = [[float(x) for x in os.environ[k].split()] for k in ("A0", "A1", "A2")]
print()
print("### " + title)
hdr = "  rep   | " + " | ".join("%-20s" % lab for lab in labels)
print(hdr)
print("  " + "-" * (len(hdr) - 2))
for i in range(len(data[0])):
    print("  %-5d | " % (i + 1) + " | ".join("%-20.3f" % data[c][i] for c in range(3)))
avgs = [sum(c) / len(c) for c in data]
print("  " + "-" * (len(hdr) - 2))
print("  %-5s | " % "avg" + " | ".join("%-20.3f" % a for a in avgs))
print("  -> medium/small = %.2fx , large/small = %.2fx" % (avgs[1] / avgs[0], avgs[2] / avgs[0]))
tsv = os.environ.get("BENCH_TSV")
if tsv:
    with open(tsv, "a") as f:
        f.write("\t".join([title] + ["%.3f" % a for a in avgs]) + "\n")
'
}

# --- 1. Sanity-check the engine is reachable and has metadata ----------------
if ! meta '{"type":"export_metadata","args":{}}' 2>/dev/null | grep -q '"sources"'; then
  echo "ERROR: no graphql-engine with metadata at $HASURA_URL"
  echo "  Start it first, e.g.:"
  echo "    HASURA_GRAPHQL_DATABASE_URL=... cabal run -v0 exe:graphql-engine -- serve"
  echo "  (and set HASURA_ADMIN_SECRET if your engine uses one)"
  exit 1
fi

# --- 2. Discover small/medium/large tracked schema + a table in each ---------
read -r SOURCE \
  SMALL_SCHEMA SMALL_TABLE SMALL_N \
  MEDIUM_SCHEMA MEDIUM_TABLE MEDIUM_N \
  LARGE_SCHEMA LARGE_TABLE LARGE_N \
  TOTAL_N < <(
  meta '{"type":"export_metadata","args":{}}' \
    | SOURCE="${SOURCE:-}" SMALL_SCHEMA="${SMALL_SCHEMA:-}" MEDIUM_SCHEMA="${MEDIUM_SCHEMA:-}" LARGE_SCHEMA="${LARGE_SCHEMA:-}" python3 -c '
import sys, json, os, collections
m = json.load(sys.stdin)
sources = m.get("sources", [])
if not sources:
    sys.exit("no sources in metadata")
want = os.environ.get("SOURCE") or sources[0]["name"]
src = next((s for s in sources if s["name"] == want), sources[0])
by = collections.defaultdict(list)
for t in src.get("tables", []):
    by[t["table"]["schema"]].append(t["table"]["name"])
counts = {s: len(v) for s, v in by.items()}

ov = [os.environ.get(k, "") for k in ("SMALL_SCHEMA", "MEDIUM_SCHEMA", "LARGE_SCHEMA")]
if all(ov):
    chosen = ov
    for s in chosen:
        if s not in by:
            sys.exit("schema %r has no tracked tables (have: %r)" % (s, counts))
else:
    if len(by) < 3:
        sys.exit("need tables tracked in >=3 schemas for small/medium/large; found: %r" % counts)
    ordered = sorted(counts, key=counts.get)
    small, large = ordered[0], ordered[-1]
    target = (counts[small] + counts[large]) / 2
    cand = [s for s in ordered if s not in (small, large)]
    medium = min(cand, key=lambda s: abs(counts[s] - target))
    chosen = [small, medium, large]

out = [src["name"]]
for s in chosen:
    out += [s, by[s][0], str(counts[s])]
out.append(str(sum(counts.values())))  # total tracked tables across all schemas
print(*out)
'
)

SMALL_LABEL="small ${SMALL_SCHEMA}(${SMALL_N})"
MEDIUM_LABEL="medium ${MEDIUM_SCHEMA}(${MEDIUM_N})"
LARGE_LABEL="large ${LARGE_SCHEMA}(${LARGE_N})"
SCHEMAS=("$SMALL_SCHEMA" "$MEDIUM_SCHEMA" "$LARGE_SCHEMA")
TABLES=("$SMALL_TABLE" "$MEDIUM_TABLE" "$LARGE_TABLE")

echo
echo "================ schema-cache rebuild benchmark ================"
echo "engine:  $HASURA_URL"
echo "source:  $SOURCE  ($TOTAL_N tracked tables across all schemas)"
echo "SMALL :  $SMALL_SCHEMA  ($SMALL_N tables)  -> $SMALL_SCHEMA.$SMALL_TABLE"
echo "MEDIUM:  $MEDIUM_SCHEMA  ($MEDIUM_N tables)  -> $MEDIUM_SCHEMA.$MEDIUM_TABLE"
echo "LARGE :  $LARGE_SCHEMA  ($LARGE_N tables)  -> $LARGE_SCHEMA.$LARGE_TABLE"
echo "reps:    $REPS"
[ "$MEDIUM_N" = "$LARGE_N" ] && echo "NOTE: medium and large have the SAME table count — no real gradient (see header)."
echo "==============================================================="

# Start a fresh machine-readable TSV (when requested), seeded with a #meta line.
if [ -n "${BENCH_TSV:-}" ]; then
  : > "$BENCH_TSV"
  printf '#meta\tsource=%s\tsmall=%s(%s)\tmedium=%s(%s)\tlarge=%s(%s)\ttotal=%s\n' \
    "$SOURCE" "$SMALL_SCHEMA" "$SMALL_N" "$MEDIUM_SCHEMA" "$MEDIUM_N" "$LARGE_SCHEMA" "$LARGE_N" "$TOTAL_N" >> "$BENCH_TSV"
  echo "(writing machine-readable averages to $BENCH_TSV)"
fi

# --- 3. Warmup (settle parser caches for all 3 schemas + both code paths) -----
for i in 0 1 2; do
  add_col_timed "${SCHEMAS[$i]}" "${TABLES[$i]}" bench_warm >/dev/null
  CREATED_COLS+=("${SCHEMAS[$i]}.${TABLES[$i]}.bench_warm")
  drop_col "${SCHEMAS[$i]}" "${TABLES[$i]}" bench_warm
  create_tbl "${SCHEMAS[$i]}" bench_warm; CREATED_TBLS+=("${SCHEMAS[$i]}.bench_warm")
  track_q "${SCHEMAS[$i]}" bench_warm; drop_tbl "${SCHEMAS[$i]}" bench_warm
done

# --- 4a/4b. ALTER ADD COLUMN + ALTER DROP COLUMN (one add/drop cycle per rep) -
add0=(); add1=(); add2=(); drp0=(); drp1=(); drp2=()
for rep in $(seq 1 "$REPS"); do
  col="bench_c${rep}"
  for i in 0 1 2; do
    sch="${SCHEMAS[$i]}"; tbl="${TABLES[$i]}"
    at=$(add_col_timed "$sch" "$tbl" "$col");  CREATED_COLS+=("$sch.$tbl.$col")
    dt=$(drop_col_timed "$sch" "$tbl" "$col")
    case $i in
      0) add0+=("$at"); drp0+=("$dt");;
      1) add1+=("$at"); drp1+=("$dt");;
      2) add2+=("$at"); drp2+=("$dt");;
    esac
  done
done
report "ALTER ADD COLUMN"  "${add0[*]}" "${add1[*]}" "${add2[*]}"
report "ALTER DROP COLUMN" "${drp0[*]}" "${drp1[*]}" "${drp2[*]}"

# --- 4c/4d. TRACK + UNTRACK TABLE (one table lifecycle per rep) ----------------
trk0=(); trk1=(); trk2=(); unt0=(); unt1=(); unt2=()
for rep in $(seq 1 "$REPS"); do
  n="bench_trk_${rep}"
  for i in 0 1 2; do
    sch="${SCHEMAS[$i]}"
    create_tbl "$sch" "$n"; CREATED_TBLS+=("$sch.$n")
    tt=$(track_timed "$sch" "$n")     # time TRACK
    ut=$(untrack_timed "$sch" "$n")   # time UNTRACK
    drop_tbl "$sch" "$n"              # drop the physical table
    case $i in
      0) trk0+=("$tt"); unt0+=("$ut");;
      1) trk1+=("$tt"); unt1+=("$ut");;
      2) trk2+=("$tt"); unt2+=("$ut");;
    esac
  done
done
report "TRACK TABLE"   "${trk0[*]}" "${trk1[*]}" "${trk2[*]}"
report "UNTRACK TABLE" "${unt0[*]}" "${unt1[*]}" "${unt2[*]}"

# --- 5. List the temporary objects this run created (all already dropped) -----
echo
echo "### temporary objects created during this run (all dropped afterwards)"
echo "columns added (${#CREATED_COLS[@]}):"
printf '  %s\n' "${CREATED_COLS[@]}"
echo "tables created (${#CREATED_TBLS[@]}):"
printf '  %s\n' "${CREATED_TBLS[@]}"

echo
echo "==============================================================="
echo "Done. Expect cost to grow small < medium < large in each section,"
echo "tracking the rebuilt schema's table count."
echo "==============================================================="

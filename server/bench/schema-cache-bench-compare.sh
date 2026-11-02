#!/usr/bin/env bash
#
# Compare two schema-cache-bench.sh runs (e.g. a baseline engine vs the current
# engine) side by side. Each input is a TSV produced by running:
#
#   BENCH_TSV=baseline.tsv  bash server/bench/schema-cache-bench.sh   # baseline engine up
#   BENCH_TSV=current.tsv   bash server/bench/schema-cache-bench.sh   # current engine up
#
# then:
#
#   bash server/bench/schema-cache-bench-compare.sh baseline.tsv current.tsv
#
# Each TSV has a "#meta ..." header line plus one line per operation:
#   <operation>\t<small_avg>\t<medium_avg>\t<large_avg>
#
# The report prints, per operation and per schema size, baseline vs current and
# the speedup (baseline/current). Run both against the SAME database/fixture.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <baseline.tsv> <current.tsv>" >&2
  exit 2
fi
[ -f "$1" ] || { echo "no such file: $1" >&2; exit 1; }
[ -f "$2" ] || { echo "no such file: $2" >&2; exit 1; }

BASE="$1" CUR="$2" python3 -c '
import os, sys

def load(path):
    meta, rows = "", {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#meta"):
                meta = line[len("#meta"):].strip()
                continue
            parts = line.split("\t")
            op, vals = parts[0], [float(x) for x in parts[1:4]]
            rows[op] = vals
    return meta, rows

bmeta, b = load(os.environ["BASE"])
cmeta, c = load(os.environ["CUR"])

print("================ baseline vs current ================")
print("baseline (%s): %s" % (os.environ["BASE"], bmeta))
print("current  (%s): %s" % (os.environ["CUR"], cmeta))
if bmeta != cmeta:
    print("WARNING: the two runs used DIFFERENT fixtures (meta lines differ) — comparison may be apples-to-oranges.")
print("=====================================================")

sizes = ["small", "medium", "large"]
ops = list(b.keys()) + [o for o in c.keys() if o not in b]
for op in ops:
    print("\n### %s" % op)
    if op not in b or op not in c:
        print("  (only present in %s)" % ("baseline" if op in b else "current"))
        continue
    print("  %-7s | %-12s | %-12s | %s" % ("size", "baseline s", "current s", "speedup (base/cur)"))
    print("  " + "-" * 56)
    for i, sz in enumerate(sizes):
        bv, cv = b[op][i], c[op][i]
        sp = ("%.2fx" % (bv / cv)) if cv > 0 else "n/a"
        print("  %-7s | %-12.3f | %-12.3f | %s" % (sz, bv, cv, sp))
print("\n=====================================================")
print("speedup > 1.00x means the current engine is faster than baseline.")
'

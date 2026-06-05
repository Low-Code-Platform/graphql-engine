#!/usr/bin/env bash
# Track all 1 000 benchmark tables (5 schemas × 200 tables) via the Hasura
# Metadata API.  Must be run once against a live Hasura instance after the SQL
# fixture has been applied.
#
# Usage:
#   HASURA_URL=http://localhost:8181 \
#   HASURA_ADMIN_SECRET=secret      \
#     bash track_tables.sh

set -euo pipefail

URL="${HASURA_URL:-http://localhost:8181}"
SECRET="${HASURA_ADMIN_SECRET:-}"
HEADERS=(-H "X-Hasura-Admin-Secret: $SECRET" -H "Content-Type: application/json")

for schema in s1 s2 s3 s4 s5; do
  echo "Tracking schema $schema ..."
  for i in $(seq 1 200); do
    http_code=$(
      curl -s -o /dev/null -w "%{http_code}" \
        "${HEADERS[@]}" \
        --data-raw "{
          \"type\": \"pg_track_table\",
          \"args\": {
            \"source\": \"default\",
            \"table\": { \"schema\": \"$schema\", \"name\": \"tbl_$i\" }
          }
        }" \
        "$URL/v1/metadata"
    )
    if [[ "$http_code" != "200" ]]; then
      echo "  WARNING: $schema.tbl_$i returned HTTP $http_code" >&2
    fi
  done
  echo "  done ($schema)"
done

echo "All tables tracked."

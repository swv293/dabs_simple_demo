#!/usr/bin/env bash
# teardown.sh — wipe a deployment so the demo can re-run from scratch.
#
# Required env vars (same as demo_deploy.sh):
#   DATABRICKS_CONFIG_PROFILE  your ~/.databrickscfg profile name
#   BUNDLE_VAR_catalog         UC catalog (used for belt-and-suspenders DROP SCHEMA)
#   DATABRICKS_TF_EXEC_PATH    path to system terraform binary
#   DATABRICKS_TF_VERSION      matching terraform version string
#
# `databricks bundle destroy` removes all bundle-managed resources (job,
# dashboard, schema + tables + volume). The schema DROP below is only a
# belt-and-suspenders step for data written outside the bundle; it is
# skipped if catalog/schema info can't be resolved.
#
# Usage:  ./scripts/teardown.sh [target]
# Default target is "dev".

set -euo pipefail

TARGET="${1:-dev}"
TF_ARGS=(
  DATABRICKS_TF_EXEC_PATH="$(which terraform)"
  DATABRICKS_TF_VERSION="1.15.5"
)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# Capture schema info BEFORE destroy (state is gone after).
echo "==> reading deployment state (target=$TARGET)"
SUMMARY="$(env "${TF_ARGS[@]}" databricks bundle summary -t "$TARGET" -o json 2>/dev/null || echo '{}')"
CATALOG="$(echo "$SUMMARY"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('variables',{}).get('catalog',{}).get('value',''))" 2>/dev/null || true)"
SCHEMA="$(echo  "$SUMMARY"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('schemas',{}).get('demo',{}).get('name',''))" 2>/dev/null || true)"
WAREHOUSE="$(echo "$SUMMARY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('variables',{}).get('warehouse_id',{}).get('value',''))" 2>/dev/null || true)"
HOST="$(echo    "$SUMMARY"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('workspace',{}).get('host',''))" 2>/dev/null || true)"

echo "==> bundle destroy (target=$TARGET)"
env "${TF_ARGS[@]}" databricks bundle destroy -t "$TARGET" --auto-approve

# Belt-and-suspenders: drop any data that bundle destroy may have left behind.
# bundle destroy already removes the managed schema, so this is a no-op in
# normal usage — it only matters if extra tables were written outside the bundle.
if [[ -n "$CATALOG" && -n "$SCHEMA" && -n "$WAREHOUSE" && -n "$HOST" ]]; then
  echo "==> belt-and-suspenders DROP SCHEMA IF EXISTS ${CATALOG}.${SCHEMA}"
  TMP_JSON="$(mktemp /tmp/teardown_sql_XXXXXX.json)"
  python3 - "$WAREHOUSE" "$CATALOG" "$SCHEMA" >"$TMP_JSON" <<'PYEOF'
import sys, json
wh, cat, sch = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "warehouse_id": wh,
    "statement": f"DROP SCHEMA IF EXISTS `{cat}`.`{sch}` CASCADE",
    "wait_timeout": "30s"
}))
PYEOF
  DATABRICKS_HOST="$HOST" databricks api post /api/2.0/sql/statements/ \
    --json @"$TMP_JSON" > /dev/null \
    && echo "  Done (already dropped by bundle destroy — no-op)." \
    || echo "  Skipped (already gone)."
  rm -f "$TMP_JSON"
fi

echo
echo "Teardown complete for target=$TARGET."

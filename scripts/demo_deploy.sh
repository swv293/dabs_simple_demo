#!/usr/bin/env bash
# demo_deploy.sh — one-shot wrapper for the live demo.
#   validate -> deploy -> run the daily_etl job
#
# Required env vars (set in your shell profile or a gitignored .env file):
#   DATABRICKS_CONFIG_PROFILE  your ~/.databrickscfg profile name
#                              (create with: databricks auth login --profile my-workspace)
#   BUNDLE_VAR_catalog         UC catalog to deploy into (e.g. "workspace" on Free Edition)
#   DATABRICKS_TF_EXEC_PATH    path to system terraform binary
#   DATABRICKS_TF_VERSION      matching terraform version string
#
# Usage:  ./scripts/demo_deploy.sh [target]
# Default target is "dev".

set -euo pipefail

TARGET="${1:-dev}"
TF_ARGS=(
  DATABRICKS_TF_EXEC_PATH="$(which terraform)"
  DATABRICKS_TF_VERSION="1.15.5"
)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "==> validating bundle (target=$TARGET)"
env "${TF_ARGS[@]}" databricks bundle validate -t "$TARGET"

echo
echo "==> deploying bundle (target=$TARGET)"
env "${TF_ARGS[@]}" databricks bundle deploy -t "$TARGET"

echo
echo "==> running daily_etl (target=$TARGET) — waits for completion"
env "${TF_ARGS[@]}" databricks bundle run daily_etl -t "$TARGET"

echo
echo "Done. Open the workspace UI to see the job, schema, and dashboard."

#!/usr/bin/env bash
# Validate the bundle against every target. Useful locally and from CI.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# prod is intentionally excluded — its workspace host is a placeholder for
# the talk-track and requires real prod credentials to authenticate. In a
# real org, CI runs `bundle validate -t prod` with the prod auth context.
for target in dev staging; do
  echo "==> bundle validate -t $target"
  databricks bundle validate -t "$target"
done

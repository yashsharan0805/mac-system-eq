#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle_dir="$root_dir/.dev-app/MacSystemEQ.app"
app_exec="$app_bundle_dir/Contents/MacOS/MacSystemEQ"

"$root_dir/scripts/run-dev-app.sh" --prepare-only >/dev/null

if [[ ! -x "$app_exec" ]]; then
  echo "Expected app executable not found at: $app_exec"
  exit 1
fi

echo "Running $app_exec in debug log mode (Ctrl+C to stop)"
EQ_ENABLE_VERBOSE_LOGGING=1 EQ_LOG_TO_STDERR=1 "$app_exec"

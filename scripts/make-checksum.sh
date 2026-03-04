#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <artifact-path>"
  exit 1
fi

artifact="$1"
shasum -a 256 "$artifact" | tee "$artifact.sha256"

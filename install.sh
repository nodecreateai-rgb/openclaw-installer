#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ ! -f "$ROOT/install-native.sh" ]]; then
  echo "install-native.sh not found" >&2
  exit 1
fi

echo "Starting native installer on host..."
echo

exec bash "$ROOT/install-native.sh"

#!/usr/bin/env bash
set -euo pipefail

TEST_REPO_ROOT() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  [[ -f "$path/install-native.sh" ]] || return 1
  [[ -d "$path/app-proxy" ]] || return 1
  [[ -d "$path/tenant-mode" ]] || return 1
  [[ -d "$path/scripts" ]] || return 1
  return 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""

if TEST_REPO_ROOT "$ROOT"; then
  REPO_ROOT="$ROOT"
else
  ARCHIVE_URL="${OPENCLAW_INSTALLER_ARCHIVE_URL:-https://github.com/nodecreateai-rgb/openclaw-installer/archive/refs/heads/main.tar.gz}"
  TEMP_ROOT="$(mktemp -d)"
  ARCHIVE_PATH="$TEMP_ROOT/installer.tar.gz"
  trap 'rm -rf "$TEMP_ROOT"' EXIT

  echo "Downloading installer bundle from $ARCHIVE_URL ..."
  curl -fsSL "$ARCHIVE_URL" -o "$ARCHIVE_PATH"
  tar -xzf "$ARCHIVE_PATH" -C "$TEMP_ROOT"

  while IFS= read -r candidate; do
    if TEST_REPO_ROOT "$candidate"; then
      REPO_ROOT="$candidate"
      break
    fi
  done < <(find "$TEMP_ROOT" -mindepth 1 -maxdepth 2 -type d | sort)

  if [[ -z "$REPO_ROOT" ]]; then
    echo "failed to locate install-native.sh in downloaded archive: $ARCHIVE_URL" >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"

echo "Starting native installer on host..."
echo

exec bash "$REPO_ROOT/install-native.sh"

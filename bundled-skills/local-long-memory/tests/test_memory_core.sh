#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-memory-core.XXXXXX")"
TEST_ROOT="$WORK_DIR/skill"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/scripts"
cp "$ROOT_DIR/scripts/memory_core.py" "$TEST_ROOT/scripts/memory_core.py"
cd "$TEST_ROOT"

python3 scripts/memory_core.py put-fact --key repo.installer.url --value https://github.com/nodecreateai-rgb/openclaw-installer --source test --task-id tenant-mode-release >/dev/null
python3 scripts/memory_core.py put-task --task-id tenant-mode-release --status completed --value "linux proxy tenant create passed" --source test >/dev/null
python3 scripts/memory_core.py put-event --task-id tenant-mode-release --event-type test_passed --value "multi tenant isolation passed" --source test --session-key s1 >/dev/null
python3 scripts/memory_core.py put-summary --task-id tenant-mode-release --value "windows still needs real smoke" --source test >/dev/null
python3 scripts/memory_core.py search --query tenant --limit 5 > "$WORK_DIR/local-memory-search.json"
python3 scripts/memory_core.py search --query passed --task-id tenant-mode-release --limit 10 > "$WORK_DIR/local-memory-search-scoped.json"
python3 scripts/memory_core.py context --task-id tenant-mode-release --limit 10 > "$WORK_DIR/local-memory-context.json"
python3 scripts/memory_core.py finalize-task --task-id tenant-mode-release --source test --session-key s1 >"$WORK_DIR/local-memory-finalize.json"

python3 scripts/memory_core.py put-fact --key preference.default --value global-v1 --source test >/dev/null
python3 scripts/memory_core.py put-fact --key preference.default --value task-alpha-v1 --task-id task-alpha --source test >/dev/null
python3 scripts/memory_core.py put-fact --key preference.default --value session-alpha-v1 --task-id task-alpha --session-key session-alpha --source test >/dev/null
python3 scripts/memory_core.py get-current-fact --key preference.default --scope-mode exact > "$WORK_DIR/local-memory-global.json"
python3 scripts/memory_core.py get-current-fact --key preference.default --task-id task-alpha --scope-mode exact > "$WORK_DIR/local-memory-task.json"
python3 scripts/memory_core.py get-current-fact --key preference.default --task-id task-alpha --session-key session-alpha --scope-mode exact > "$WORK_DIR/local-memory-session.json"
python3 scripts/memory_core.py get-current-fact --key preference.default --task-id task-beta --scope-mode fallback > "$WORK_DIR/local-memory-fallback.json"
python3 scripts/memory_core.py put-fact --key preference.default --value session-alpha-v2 --task-id task-alpha --session-key session-alpha --source test --supersedes 7 >/dev/null
python3 scripts/memory_core.py get-current-fact --key preference.default --task-id task-alpha --scope-mode exact > "$WORK_DIR/local-memory-task-after.json"
python3 scripts/memory_core.py get-current-fact --key preference.default --task-id task-alpha --session-key session-alpha --scope-mode exact > "$WORK_DIR/local-memory-session-after.json"

python3 - <<'PY' "$WORK_DIR"
import json
import sys
from pathlib import Path

work_dir = Path(sys.argv[1])
s=json.load(open(work_dir / 'local-memory-search.json'))
ss=json.load(open(work_dir / 'local-memory-search-scoped.json'))
c=json.load(open(work_dir / 'local-memory-context.json'))
f=json.load(open(work_dir / 'local-memory-finalize.json'))
g=json.load(open(work_dir / 'local-memory-global.json'))
t=json.load(open(work_dir / 'local-memory-task.json'))
se=json.load(open(work_dir / 'local-memory-session.json'))
fb=json.load(open(work_dir / 'local-memory-fallback.json'))
ta=json.load(open(work_dir / 'local-memory-task-after.json'))
sea=json.load(open(work_dir / 'local-memory-session-after.json'))
assert any('tenant' in (row.get('value','') + row.get('title','')) for row in s)
assert any(row.get('task_id') == 'tenant-mode-release' for row in ss)
assert any(row.get('kind') == 'event' for row in c)
assert f['task_id'] == 'tenant-mode-release'
assert 'passed' in f['value']
assert g['value'] == 'global-v1'
assert t['value'] == 'task-alpha-v1'
assert se['value'] == 'session-alpha-v1'
assert fb['value'] == 'global-v1'
assert ta['value'] == 'task-alpha-v1'
assert sea['value'] == 'session-alpha-v2'
print('local-long-memory-test=PASS')
PY

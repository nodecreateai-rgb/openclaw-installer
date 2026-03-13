#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_SCRIPT="$ROOT_DIR/bundled-skills/agile-codex/scripts/agile_codex_backend.py"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agile-codex-backend-validate.XXXXXX")"

log() {
  printf '[agile-codex-backend-validate] %s\n' "$*"
}

fail() {
  printf '[agile-codex-backend-validate] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "${KEEP_VALIDATION_WORKDIR:-0}" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    log "keeping workdir: $WORK_DIR"
  fi
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || fail 'missing required binary: python3'

run_completed_case() {
  log 'running completed-session status check'
  local logdir="$WORK_DIR/completed"
  mkdir -p "$logdir"
  printf '{"session":"demo","backend":"process","started_at_epoch":1710000000,"started_at":"2024-03-09T16:00:00Z","pid":999999}\n' > "$logdir/demo.meta.json"
  python3 - <<'PY' "$logdir/demo.jsonl"
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
objects = [{"type": "event_msg", "payload": {"type": "task_complete"}}]
objects.extend({"type": "event_msg", "payload": {"type": "token"}, "i": i} for i in range(40))
path.write_text("\n".join(json.dumps(obj) for obj in objects) + "\n", encoding='utf-8')
PY
  python3 "$BACKEND_SCRIPT" status demo "$logdir" > "$logdir/status.json"

  python3 - <<'PY' "$logdir/status.json"
import json
import sys

payload = json.loads(open(sys.argv[1], 'r', encoding='utf-8').read())
assert payload['state'] == 'completed', payload
assert payload['completed'] is True, payload
assert payload['abrupt_exit'] is False, payload
assert payload['task_complete_event'] is True, payload
assert payload['report_reason'] == 'completed', payload
PY
}

run_missing_case() {
  log 'running interrupted-session status check'
  local logdir="$WORK_DIR/missing"
  mkdir -p "$logdir"
  printf '{"session":"demo","backend":"process","started_at_epoch":1710000000,"started_at":"2024-03-09T16:00:00Z","pid":999999}\n' > "$logdir/demo.meta.json"
  python3 - <<'PY' "$logdir/demo.jsonl"
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
objects = [{"type": "event_msg", "payload": {"type": "token"}, "i": i} for i in range(4)]
path.write_text("\n".join(json.dumps(obj) for obj in objects) + "\n", encoding='utf-8')
PY
  python3 "$BACKEND_SCRIPT" status demo "$logdir" > "$logdir/status.json"

  python3 - <<'PY' "$logdir/status.json"
import json
import sys

payload = json.loads(open(sys.argv[1], 'r', encoding='utf-8').read())
assert payload['state'] == 'missing', payload
assert payload['completed'] is False, payload
assert payload['abrupt_exit'] is True, payload
assert payload['task_complete_event'] is False, payload
assert payload['report_reason'] == 'missing', payload
PY
}

main() {
  run_completed_case
  run_missing_case
  log 'all checks passed'
}

main "$@"

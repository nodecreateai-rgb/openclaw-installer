#!/usr/bin/env bash
set -euo pipefail

container_name="$1"
sleep_seconds="$2"
state_dir="$3"
tenant_manifest="$state_dir/tenant.json"

mkdir -p "$state_dir"
if [[ "$sleep_seconds" =~ ^[0-9]+$ ]] && (( sleep_seconds > 0 )); then
  sleep "$sleep_seconds"
fi

tenant_data_dir=""
if [[ -f "$tenant_manifest" ]]; then
  tenant_data_dir="$(python3 - "$tenant_manifest" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
except Exception:
    payload = {}

print(payload.get('dataDir', ''))
PY
)"
fi

if [[ -n "$tenant_data_dir" ]]; then
  mkdir -p "$tenant_data_dir"
  touch "$tenant_data_dir/TENANT_DISABLED"
else
  echo "tenant data dir missing in $tenant_manifest" >> "$state_dir/expiry.log"
fi

container_running="$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)"
if [[ "$container_running" == "true" ]]; then
  docker exec "$container_name" bash -lc '
    touch /root/.openclaw/TENANT_DISABLED
    pkill -x openclaw-gateway >/dev/null 2>&1 || true
    pkill -x openclaw >/dev/null 2>&1 || true
    pkill -f "openclaw gateway run" >/dev/null 2>&1 || true
    pkill -f "node .*openclaw.*gateway" >/dev/null 2>&1 || true
  ' || true
elif docker inspect "$container_name" >/dev/null 2>&1; then
  echo "container not running during expiry: $container_name" >> "$state_dir/expiry.log"
else
  echo "container not found during expiry: $container_name" >> "$state_dir/expiry.log"
fi

if [[ -f "$state_dir/proxy.pid" ]]; then
  proxy_pid="$(cat "$state_dir/proxy.pid" 2>/dev/null || true)"
  if [[ -n "${proxy_pid:-}" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
    kill "$proxy_pid" 2>/dev/null || true
  fi
  rm -f "$state_dir/proxy.pid"
fi

date -u +%FT%TZ > "$state_dir/disabled-at"
echo "disabled at $(cat "$state_dir/disabled-at")" >> "$state_dir/expiry.log"

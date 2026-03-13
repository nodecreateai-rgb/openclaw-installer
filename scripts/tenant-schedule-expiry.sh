#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

stop_pid_file() {
  local pid_file="$1"
  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pid_file"
}

have_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] || return 1
  [[ -S "$XDG_RUNTIME_DIR/systemd/private" ]]
}

spawn_detached() {
  local command_string="$1"
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "exec $command_string" </dev/null >/dev/null 2>&1 &
  else
    nohup sh -c "exec $command_string" >/dev/null 2>&1 &
  fi
  echo $!
}

systemd_unit_key() {
  python3 - "$1" <<'PY'
import re
import sys

value = re.sub(r'[^A-Za-z0-9]+', '-', sys.argv[1]).strip('-').lower()
print(value or 'tenant')
PY
}

container_name="${1:-}"
seconds="${2:-}"
state_dir="${3:-}"

if [[ -z "$container_name" || -z "$seconds" || -z "$state_dir" ]]; then
  echo "usage: $0 <container-name> <seconds> <state-dir>" >&2
  exit 1
fi

if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
  echo "seconds must be an integer: $seconds" >&2
  exit 1
fi

expiry_log="$state_dir/expiry.log"
expiry_mode_file="$state_dir/expiry.mode"
expiry_unit_file="$state_dir/expiry.unit"
mkdir -p "$state_dir"
chmod 700 "$state_dir" 2>/dev/null || true
printf 'scheduled disable in %ss for %s\n' "$seconds" "$container_name" > "$expiry_log"
stop_pid_file "$state_dir/expiry.pid"

if [[ -f "$expiry_unit_file" && -n "$(cat "$expiry_unit_file" 2>/dev/null || true)" ]]; then
  old_unit="$(cat "$expiry_unit_file" 2>/dev/null || true)"
  if have_systemd_user; then
    systemctl --user stop "${old_unit}.timer" >/dev/null 2>&1 || true
    systemctl --user stop "${old_unit}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${old_unit}.timer" "${old_unit}.service" >/dev/null 2>&1 || true
  fi
fi
rm -f "$expiry_unit_file" "$expiry_mode_file"

if have_systemd_user && command -v systemd-run >/dev/null 2>&1; then
  systemd_unit="openclaw-tenant-expire-$(systemd_unit_key "$container_name")"
  if systemd-run --user \
    --unit "$systemd_unit" \
    --on-active "${seconds}s" \
    --timer-property=AccuracySec=1s \
    --collect \
    bash \
    "$SCRIPT_DIR/tenant-expire.sh" \
    "$container_name" \
    "0" \
    "$state_dir" >"$state_dir/expiry-schedule.log" 2>&1; then
    printf 'systemd-user\n' > "$expiry_mode_file"
    printf '%s\n' "$systemd_unit" > "$expiry_unit_file"
    exit 0
  fi
  printf 'systemd-run failed, fallback to detached sleep\n' >> "$expiry_log"
fi

printf -v expiry_cmd '%q %q %q %q %q > %q 2>&1' \
  "bash" \
  "$SCRIPT_DIR/tenant-expire.sh" \
  "$container_name" \
  "$seconds" \
  "$state_dir" \
  "$state_dir/expiry-run.log"
expiry_pid="$(spawn_detached "$expiry_cmd")"
echo "$expiry_pid" > "$state_dir/expiry.pid"
printf 'sleep-fallback\n' > "$expiry_mode_file"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_NPM_PACKAGE="${OPENCLAW_NPM_PACKAGE:-openclaw@latest}"
CODEX_NPM_PACKAGE="${CODEX_NPM_PACKAGE:-@openai/codex@latest}"
PROVIDER="default"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw}"
SKILLS_DIR="$HOME/.openclaw/skills"
HOOKS_DIR="$HOME/.openclaw/hooks"
BUNDLED_SKILLS_DIR="${BUNDLED_SKILLS_DIR:-$SCRIPT_DIR/bundled-skills}"
AGILE_CODEX_RUNTIME_DIR="${AGILE_CODEX_RUNTIME_DIR:-$SKILLS_DIR/agile-codex/runtime}"
AGILE_CODEX_MONITOR_NAME="${AGILE_CODEX_MONITOR_NAME:-Agile Codex progress monitor}"
AGILE_CODEX_MONITOR_CHANNEL="${AGILE_CODEX_MONITOR_CHANNEL:-}"
AGILE_CODEX_MONITOR_TO="${AGILE_CODEX_MONITOR_TO:-}"
AGILE_CODEX_MONITOR_ACCOUNT="${AGILE_CODEX_MONITOR_ACCOUNT:-}"
FEISHU_PLUGIN_SPEC="${FEISHU_PLUGIN_SPEC:-@m1heng-clawd/feishu}"
INSTALL_MODE="${INSTALL_MODE:-}"
TENANT_NONINTERACTIVE="${TENANT_NONINTERACTIVE:-0}"
TENANT_PROXY_MODE="${TENANT_PROXY_MODE:-}"
TENANT_DURATION_LABEL="${TENANT_DURATION_LABEL:-}"
TENANT_DURATION_SECONDS="${TENANT_DURATION_SECONDS:-}"
TENANT_SHORT_UUID="${TENANT_SHORT_UUID:-}"
TENANT_BASE_URL="${TENANT_BASE_URL:-}"
TENANT_API_KEY="${TENANT_API_KEY:-}"
TENANT_MODEL="${TENANT_MODEL:-}"
TENANT_FEISHU_APP_ID="${TENANT_FEISHU_APP_ID:-}"
TENANT_FEISHU_APP_SECRET="${TENANT_FEISHU_APP_SECRET:-}"
TENANT_VNC_PASSWORD="${TENANT_VNC_PASSWORD:-}"
TENANT_HOST_BASE_URL="${TENANT_HOST_BASE_URL:-}"
TENANT_HOST_API_KEY="${TENANT_HOST_API_KEY:-}"
TENANT_HOST_MODEL="${TENANT_HOST_MODEL:-}"
TENANT_READY_TIMEOUT_SECONDS="${TENANT_READY_TIMEOUT_SECONDS:-1800}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-}"
OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON="${OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON:-}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}

prompt() {
  local label="$1"
  local default="${2-}"
  local value
  if [[ "$TENANT_NONINTERACTIVE" == "1" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || true
    printf '%s' "${value:-$default}"
  else
    read -r -p "$label: " value || true
    printf '%s' "$value"
  fi
}

choose_install_mode() {
  if [[ -n "$INSTALL_MODE" ]]; then
    printf '%s' "$INSTALL_MODE"
    return 0
  fi
  local mode
  mode="$(prompt '选择模式：网管(admin) / 租户(tenant)' 'admin')"
  case "$mode" in
    admin|网管|guanli) printf 'admin' ;;
    tenant|租户) printf 'tenant' ;;
    *) printf 'admin' ;;
  esac
}

choose_tenant_duration() {
  if [[ -n "$TENANT_DURATION_LABEL" ]]; then
    printf '%s' "$TENANT_DURATION_LABEL"
    return 0
  fi
  prompt '租户时长，例如 1h / 2h / 3h / 1d / 1m' '1h'
}

tenant_duration_seconds() {
  if [[ -n "$TENANT_DURATION_SECONDS" ]]; then
    if [[ "$TENANT_DURATION_SECONDS" =~ ^[0-9]+$ ]] && (( TENANT_DURATION_SECONDS > 0 )); then
      echo "$TENANT_DURATION_SECONDS"
      return 0
    fi
    echo "invalid TENANT_DURATION_SECONDS: $TENANT_DURATION_SECONDS" >&2
    return 1
  fi
  python3 - "$1" <<'PY'
import re
import sys

raw = (sys.argv[1] or "").strip().lower()
if not raw:
    raise SystemExit("duration is required")

for src, dst in (
    ("个月", "mo"),
    ("月", "mo"),
    ("小时", "h"),
    ("分钟", "min"),
    ("分", "min"),
    ("秒钟", "s"),
    ("秒", "s"),
    ("天", "d"),
    ("周", "w"),
):
    raw = raw.replace(src, dst)
normalized = re.sub(r"[\s,]+", "", raw)

legacy = {
    "1h": 3600,
    "2h": 7200,
    "5h": 18000,
    "1m": 2592000,
}
if normalized in legacy:
    print(legacy[normalized])
    raise SystemExit(0)

units = {
    "s": 1,
    "sec": 1,
    "secs": 1,
    "second": 1,
    "seconds": 1,
    "m": 60,
    "min": 60,
    "mins": 60,
    "minute": 60,
    "minutes": 60,
    "h": 3600,
    "hr": 3600,
    "hrs": 3600,
    "hour": 3600,
    "hours": 3600,
    "d": 86400,
    "day": 86400,
    "days": 86400,
    "w": 604800,
    "week": 604800,
    "weeks": 604800,
    "mo": 2592000,
    "mon": 2592000,
    "month": 2592000,
    "months": 2592000,
}
matches = list(re.finditer(r"(\d+)([a-z]+)", normalized))
if not matches or "".join(match.group(0) for match in matches) != normalized:
    raise SystemExit(f"unsupported duration: {sys.argv[1]}")
total = 0
for match in matches:
    amount = int(match.group(1))
    unit = match.group(2)
    if amount <= 0:
        raise SystemExit(f"duration must be > 0: {sys.argv[1]}")
    if unit not in units:
        raise SystemExit(f"unsupported duration unit in: {sys.argv[1]}")
    total += amount * units[unit]
if total <= 0:
    raise SystemExit(f"duration must be > 0: {sys.argv[1]}")
print(total)
PY
}

choose_tenant_model_mode() {
  if [[ "$TENANT_PROXY_MODE" == "proxy" || "$TENANT_PROXY_MODE" == "custom" ]]; then
    printf '%s' "$TENANT_PROXY_MODE"
    return 0
  fi
  local mode
  mode="$(prompt '租户模型来源：代理(proxy) / 自定义(custom)' 'proxy')"
  case "$mode" in
    proxy|代理) printf 'proxy' ;;
    custom|自定义) printf 'custom' ;;
    *) printf 'proxy' ;;
  esac
}

is_linux() { [[ "$(uname -s)" == "Linux" ]]; }
is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_container_like() {
  [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]]
}

have_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] || return 1
  [[ -S "$XDG_RUNTIME_DIR/systemd/private" ]]
}

start_gateway_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'exec openclaw gateway run >/tmp/openclaw-gateway-run.log 2>&1' </dev/null >/dev/null 2>&1 &
  else
    nohup openclaw gateway run </dev/null >/tmp/openclaw-gateway-run.log 2>&1 &
  fi
  echo $! >/tmp/openclaw-gateway-run.pid
}

have_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

pkg_install_linux() {
  local packages=("$@")
  [[ ${#packages[@]} -eq 0 ]] && return 0
  if command -v apt-get >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} apt-get update
      ${SUDO:-sudo} apt-get install -y "${packages[@]}"
      return 0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} dnf install -y "${packages[@]}"
      return 0
    fi
  elif command -v yum >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} yum install -y "${packages[@]}"
      return 0
    fi
  elif command -v zypper >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} zypper --non-interactive install "${packages[@]}"
      return 0
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} pacman -Sy --noconfirm "${packages[@]}"
      return 0
    fi
  elif command -v apk >/dev/null 2>&1; then
    if have_sudo; then
      ${SUDO:-sudo} apk add --no-cache "${packages[@]}"
      return 0
    fi
  fi
  return 1
}

pkg_install_macos() {
  local packages=("$@")
  [[ ${#packages[@]} -eq 0 ]] && return 0
  if command -v brew >/dev/null 2>&1; then
    brew install "${packages[@]}"
    return 0
  fi
  return 1
}

ensure_optional_bin() {
  local bin="$1"
  shift
  if command -v "$bin" >/dev/null 2>&1; then
    echo "$bin already installed: $(command -v "$bin")"
    return 0
  fi
  if is_linux; then
    if pkg_install_linux "$@"; then
      echo "installed $bin"
      return 0
    fi
  elif is_macos; then
    if pkg_install_macos "$@"; then
      echo "installed $bin"
      return 0
    fi
  fi
  echo "warning: could not auto-install $bin; fallback behavior may be used if supported" >&2
  return 1
}

extract_jobs_json() {
  python3 -c 'import json, sys
text = sys.stdin.read()
start = text.find("{")
end = text.rfind("}")
if start == -1 or end == -1 or end < start:
    raise SystemExit(0)
chunk = text[start:end+1]
json.loads(chunk)
print(chunk)
'
}

cron_job_id_by_name() {
  local job_name="$1"
  local raw=""
  raw="$(openclaw cron list --json 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  JOB_NAME="$job_name" RAW_JSON="$raw" python3 - <<'PY'
import json, os
name = os.environ.get('JOB_NAME', '')
text = os.environ.get('RAW_JSON', '')
start = text.find('{')
end = text.rfind('}')
if start == -1 or end == -1 or end < start:
    raise SystemExit(0)
chunk = text[start:end+1]
try:
    data = json.loads(chunk)
except Exception:
    raise SystemExit(0)
for job in data.get('jobs', []):
    if job.get('name') == name:
        print(job.get('id', ''))
        break
PY
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return 0
  fi
  return 1
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

systemd_unit_key() {
  python3 - "$1" <<'PY'
import re
import sys

value = re.sub(r'[^A-Za-z0-9]+', '-', sys.argv[1]).strip('-').lower()
print(value or 'tenant')
PY
}

json_array() {
  python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:], ensure_ascii=False))
PY
}

find_free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(('', 0))
print(sock.getsockname()[1])
sock.close()
PY
}

wait_for_tcp_port() {
  local host="$1"
  local port="$2"
  local attempts="${3:-30}"
  local delay_sec="${4:-1}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if python3 - <<PY >/dev/null 2>&1
import socket
sock = socket.socket()
sock.settimeout(1)
sock.connect((${host@Q}, int(${port@Q})))
sock.close()
PY
    then
      return 0
    fi
    sleep "$delay_sec"
  done
  return 1
}

wait_for_tenant_ready() {
  local container_name="$1"
  local timeout_seconds="$2"
  local poll_interval=5
  local waited=0
  while (( waited < timeout_seconds )); do
    local status
    status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
    case "$status" in
      running|created|restarting|"")
        ;;
      *)
        echo "tenant container entered unexpected state: ${status:-missing}" >&2
        docker logs --tail 200 "$container_name" >&2 || true
        return 1
        ;;
    esac
    if docker exec "$container_name" test -f /tmp/tenant-ready >/dev/null 2>&1 \
      && docker exec "$container_name" openclaw gateway health >/tmp/tenant-gateway-health.log 2>&1; then
      return 0
    fi
    sleep "$poll_interval"
    waited=$((waited + poll_interval))
  done
  echo "timed out waiting for tenant container to finish installation" >&2
  docker logs --tail 200 "$container_name" >&2 || true
  return 1
}

write_tenant_state() {
  local state_file="$1"
  local tenant_name="$2"
  local container_name="$3"
  local short_uuid="$4"
  local duration_label="$5"
  local duration_seconds="$6"
  local model_mode="$7"
  local gateway_port="$8"
  local vnc_port="$9"
  local data_dir="${10}"
  local proxy_port="${11}"
  local created_at="${12}"
  local expires_at="${13}"
  local vnc_password="${14}"
  local expiry_mode="${15}"
  local expiry_unit="${16}"
  local public_base_url="${17}"
  local public_model="${18}"
  local feishu_app_id="${19}"
  python3 - <<PY
import json
from pathlib import Path

payload = {
  'tenant': ${tenant_name@Q},
  'container': ${container_name@Q},
  'shortUuid': ${short_uuid@Q},
  'durationLabel': ${duration_label@Q},
  'durationSeconds': int(${duration_seconds@Q}),
  'modelMode': ${model_mode@Q},
  'gatewayPort': int(${gateway_port@Q}),
  'vncPort': int(${vnc_port@Q}),
  'dataDir': ${data_dir@Q},
  'createdAt': ${created_at@Q},
  'expiresAt': ${expires_at@Q},
  'vncPassword': ${vnc_password@Q},
  'baseUrl': ${public_base_url@Q},
  'model': ${public_model@Q},
  'feishuAppId': ${feishu_app_id@Q},
}
proxy_port = ${proxy_port@Q}
if proxy_port:
  payload['proxyPort'] = int(proxy_port)
expiry_mode = ${expiry_mode@Q}
if expiry_mode:
  payload['expiryMode'] = expiry_mode
expiry_unit = ${expiry_unit@Q}
if expiry_unit:
  payload['expiryUnit'] = expiry_unit
path = Path(${state_file@Q})
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
print(path)
PY
}

install_openclaw() {
  if command -v openclaw >/dev/null 2>&1; then
    echo "openclaw already installed: $(openclaw --version | head -n 1)"
    return
  fi
  echo "installing ${OPENCLAW_NPM_PACKAGE} ..."
  npm install -g "$OPENCLAW_NPM_PACKAGE"
  echo "installed: $(openclaw --version | head -n 1)"
}

install_codex() {
  if command -v codex >/dev/null 2>&1; then
    echo "codex already installed: $(codex --version | head -n 1)"
    return
  fi
  echo "installing ${CODEX_NPM_PACKAGE} ..."
  npm install -g "$CODEX_NPM_PACKAGE"
  echo "installed: $(codex --version | head -n 1)"
}

bootstrap_if_missing() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
  mkdir -p "$WORKSPACE"
  mkdir -p "$SKILLS_DIR"
  mkdir -p "$HOOKS_DIR"
  mkdir -p "$WORKSPACE/memory"
  if [[ ! -f "$WORKSPACE/MEMORY.md" ]]; then
    printf '# MEMORY.md\n\n## Long-term Memory\n\n' > "$WORKSPACE/MEMORY.md"
  fi
  local today yesterday
  today="$(date -u +%F 2>/dev/null || true)"
  yesterday="$(date -u -d 'yesterday' +%F 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat())
PY
)"
  if [[ -n "$today" && ! -f "$WORKSPACE/memory/$today.md" ]]; then
    printf '# %s\n\n' "$today" > "$WORKSPACE/memory/$today.md"
  fi
  if [[ -n "$yesterday" && ! -f "$WORKSPACE/memory/$yesterday.md" ]]; then
    printf '# %s\n\n' "$yesterday" > "$WORKSPACE/memory/$yesterday.md"
  fi
  if [[ ! -f "$CONFIG_PATH" ]]; then
    cat > "$CONFIG_PATH" <<'JSON'
{
  "models": {
    "mode": "merge",
    "providers": {
      "default": {
        "baseUrl": "",
        "apiKey": "",
        "auth": "api-key",
        "api": "openai-completions",
        "authHeader": true,
        "models": [
          {
            "id": "gpt-5.4",
            "name": "gpt-5.4",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192,
            "compat": {"maxTokensField": "max_tokens"}
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "default/gpt-5.4"
      },
      "models": {
        "default/gpt-5.4": {}
      },
      "workspace": "__WORKSPACE__",
      "compaction": {
        "mode": "safeguard"
      },
      "timeoutSeconds": 900,
      "maxConcurrent": 16,
      "subagents": {
        "maxConcurrent": 32
      }
    }
  },
  "tools": {
    "profile": "full"
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true,
    "ownerDisplay": "raw"
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "boot-md": {"enabled": true},
        "bootstrap-extra-files": {"enabled": true},
        "command-logger": {"enabled": true},
        "session-memory": {"enabled": true}
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ]
    },
    "auth": {
      "mode": "token",
      "token": "openclaw-local-token"
    },
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    },
    "nodes": {
      "denyCommands": [
        "camera.snap",
        "camera.clip",
        "screen.record",
        "contacts.add",
        "calendar.add",
        "reminders.add",
        "sms.send"
      ]
    }
  }
}
JSON
    python3 - <<PY
from pathlib import Path
p = Path(${CONFIG_PATH@Q})
text = p.read_text()
text = text.replace('__WORKSPACE__', ${WORKSPACE@Q})
p.write_text(text)
PY
    echo "created default config: $CONFIG_PATH"
  fi
}

current_values() {
  python3 - <<PY
import json
from pathlib import Path
cfg_path = Path(${CONFIG_PATH@Q})
provider = ${PROVIDER@Q}
cfg = json.loads(cfg_path.read_text())
provider_cfg = cfg.setdefault('models', {}).setdefault('providers', {}).setdefault(provider, {})
current_base = provider_cfg.get('baseUrl', '')
current_key = provider_cfg.get('apiKey', '')
models_list = provider_cfg.get('models') or []
current_model = models_list[0].get('id', '') if models_list and isinstance(models_list[0], dict) else ''
print(current_base)
print(current_key)
print(current_model or 'gpt-5.4')
PY
}

write_openclaw_config() {
  local gateway_bind="${OPENCLAW_GATEWAY_BIND:-loopback}"
  local gateway_allowed_origins_json="${OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON:-}"
  local gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
  python3 - <<PY
import json
from pathlib import Path
cfg_path = Path(${CONFIG_PATH@Q})
provider = ${PROVIDER@Q}
workspace = ${WORKSPACE@Q}
base_url = ${BASE_URL@Q}
api_key = ${API_KEY@Q}
model_name = ${MODEL_NAME@Q}
gateway_bind = ${gateway_bind@Q}
gateway_allowed_origins_json = ${gateway_allowed_origins_json@Q}
gateway_port = int(${gateway_port@Q})
cfg = json.loads(cfg_path.read_text())
provider_cfg = cfg.setdefault('models', {}).setdefault('providers', {}).setdefault(provider, {})
cfg['models']['mode'] = 'merge'
cfg['models']['providers'] = {provider: provider_cfg}
provider_cfg['baseUrl'] = base_url
provider_cfg['apiKey'] = api_key
provider_cfg['auth'] = 'api-key'
provider_cfg['api'] = 'openai-completions'
provider_cfg['authHeader'] = True
provider_cfg['models'] = [{
  'id': model_name,
  'name': model_name,
  'reasoning': False,
  'input': ['text'],
  'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
  'contextWindow': 200000,
  'maxTokens': 8192,
  'compat': {'maxTokensField': 'max_tokens'},
}]
agents = cfg.setdefault('agents', {}).setdefault('defaults', {})
agents.setdefault('model', {})['primary'] = f'{provider}/{model_name}'
agents['models'] = {f'{provider}/{model_name}': {}}
agents['workspace'] = workspace
cfg.setdefault('tools', {})['profile'] = 'full'
cfg.setdefault('messages', {})['ackReactionScope'] = 'group-mentions'
cfg.setdefault('commands', {}).update({
  'native': 'auto',
  'nativeSkills': 'auto',
  'restart': True,
  'ownerDisplay': 'raw',
})
cfg.setdefault('session', {})['dmScope'] = 'per-channel-peer'
hooks = cfg.setdefault('hooks', {}).setdefault('internal', {})
hooks['enabled'] = True
hook_entries = hooks.setdefault('entries', {})
for name in ('boot-md', 'bootstrap-extra-files', 'command-logger', 'session-memory'):
  hook_entries.setdefault(name, {})['enabled'] = True
hook_entries.setdefault('memory-preload-bundle', {})['enabled'] = True
hook_entries['memory-preload-bundle'].setdefault('memoryDbPath', str(Path(workspace) / 'skills' / 'local-long-memory' / 'data' / 'memory.db'))
hook_entries['memory-preload-bundle'].setdefault('recentMessages', 4)
hook_entries['memory-preload-bundle'].setdefault('sessionItems', 6)
hook_entries['memory-preload-bundle'].setdefault('taskItems', 8)
hook_entries['memory-preload-bundle'].setdefault('searchItems', 6)
hook_entries['memory-preload-bundle'].setdefault('maxTaskIds', 3)
hook_entries['memory-preload-bundle'].setdefault('maxChars', 4000)
hook_entries['memory-preload-bundle'].setdefault('dmOnly', True)
hook_entries.setdefault('memory-auto-capture', {})['enabled'] = True
hook_entries['memory-auto-capture'].setdefault('memoryDbPath', str(Path(workspace) / 'skills' / 'local-long-memory' / 'data' / 'memory.db'))
hook_entries['memory-auto-capture'].setdefault('memoryScriptPath', str(Path(workspace) / 'skills' / 'local-long-memory' / 'scripts' / 'memory_core.py'))
hook_entries['memory-auto-capture'].setdefault('dmOnly', True)
hook_entries['memory-auto-capture'].setdefault('maxTextLength', 1200)
hook_entries['memory-auto-capture'].setdefault('allowSummaryOnCompact', True)
hook_entries['memory-auto-capture'].setdefault('dedupeWindowSec', 21600)
hook_entries['memory-auto-capture'].setdefault('maxTaskCandidates', 5)
skills = cfg.setdefault('skills', {}).setdefault('entries', {})
skills.setdefault('using-superpowers', {})['enabled'] = True
skills.setdefault('agile-codex', {})['enabled'] = True
skills.setdefault('browser-use', {})['enabled'] = True
skills.setdefault('local-long-memory', {})['enabled'] = True
gateway = cfg.setdefault('gateway', {})
gateway['port'] = gateway_port
gateway['mode'] = 'local'
gateway['bind'] = gateway_bind
try:
  allowed_origins = json.loads(gateway_allowed_origins_json) if gateway_allowed_origins_json else []
except Exception:
  allowed_origins = []
if not isinstance(allowed_origins, list) or not allowed_origins:
  allowed_origins = [
    f'http://localhost:{gateway_port}',
    f'http://127.0.0.1:{gateway_port}',
  ]
gateway.setdefault('controlUi', {})['allowedOrigins'] = allowed_origins
gateway.setdefault('auth', {})['mode'] = 'token'
gateway['auth'].setdefault('token', 'openclaw-local-token')
gateway.setdefault('tailscale', {})['mode'] = 'off'
gateway['tailscale'].setdefault('resetOnExit', False)
gateway.setdefault('nodes', {})['denyCommands'] = [
  'camera.snap', 'camera.clip', 'screen.record', 'contacts.add', 'calendar.add', 'reminders.add', 'sms.send'
]
plugins = cfg.setdefault('plugins', {})
entries = plugins.setdefault('entries', {})
entries.pop('paco-global-skills', None)
load = plugins.get('load')
if isinstance(load, dict):
  load.pop('paths', None)
allow = plugins.get('allow')
allow_list = [x for x in allow if x != 'paco-global-skills'] if isinstance(allow, list) else []
if 'feishu' not in allow_list:
  allow_list.append('feishu')
plugins['allow'] = allow_list
cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n')
print('updated', cfg_path)
print(json.dumps({
  'provider': provider,
  'baseUrl': base_url,
  'model': model_name,
  'primary': f'{provider}/{model_name}',
  'workspace': workspace,
}, ensure_ascii=False, indent=2))
PY
}

write_codex_config() {
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<EOF
model = "${MODEL_NAME}"
model_provider = "custom"

[model_providers.custom]
name = "Custom OpenAI-Compatible"
base_url = "${BASE_URL}"
wire_api = "responses"
experimental_bearer_token = "${API_KEY}"
EOF
  echo "updated $HOME/.codex/config.toml"
}

install_local_skills() {
  if [[ ! -d "$BUNDLED_SKILLS_DIR/using-superpowers" || ! -d "$BUNDLED_SKILLS_DIR/agile-codex" || ! -d "$BUNDLED_SKILLS_DIR/browser-use" || ! -d "$BUNDLED_SKILLS_DIR/local-long-memory" ]]; then
    echo "missing bundled skills under $BUNDLED_SKILLS_DIR" >&2
    exit 1
  fi
  mkdir -p "$SKILLS_DIR"
  rm -rf "$SKILLS_DIR/using-superpowers" "$SKILLS_DIR/agile-codex" "$SKILLS_DIR/browser-use" "$SKILLS_DIR/local-long-memory"
  cp -a "$BUNDLED_SKILLS_DIR/using-superpowers" "$SKILLS_DIR/using-superpowers"
  cp -a "$BUNDLED_SKILLS_DIR/agile-codex" "$SKILLS_DIR/agile-codex"
  cp -a "$BUNDLED_SKILLS_DIR/browser-use" "$SKILLS_DIR/browser-use"
  cp -a "$BUNDLED_SKILLS_DIR/local-long-memory" "$SKILLS_DIR/local-long-memory"
  mkdir -p "$HOOKS_DIR"
  rm -rf "$HOOKS_DIR/memory-preload-bundle"
  rm -rf "$HOOKS_DIR/memory-auto-capture"
  if [[ -d "$BUNDLED_SKILLS_DIR/local-long-memory/hooks/memory-preload-bundle" ]]; then
    cp -a "$BUNDLED_SKILLS_DIR/local-long-memory/hooks/memory-preload-bundle" "$HOOKS_DIR/memory-preload-bundle"
  fi
  if [[ -d "$BUNDLED_SKILLS_DIR/local-long-memory/hooks/memory-auto-capture" ]]; then
    cp -a "$BUNDLED_SKILLS_DIR/local-long-memory/hooks/memory-auto-capture" "$HOOKS_DIR/memory-auto-capture"
  fi
  find "$SKILLS_DIR/agile-codex/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  find "$SKILLS_DIR/local-long-memory/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true
  find "$SKILLS_DIR/local-long-memory/tests" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true
  mkdir -p "$AGILE_CODEX_RUNTIME_DIR"
  echo "installed local skills into $SKILLS_DIR"
}

write_browser_use_skill_config() {
  local browser_skill_dir="$SKILLS_DIR/browser-use"
  local browser_runtime_dir="$browser_skill_dir/runtime"
  local browser_config_file="$browser_runtime_dir/config.json"

  if [[ ! -d "$browser_skill_dir" ]]; then
    echo "browser-use skill directory missing: $browser_skill_dir" >&2
    exit 1
  fi

  mkdir -p "$browser_runtime_dir"
  python3 - <<PY
import json
from pathlib import Path
path = Path(${browser_config_file@Q})
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
  'provider': 'default',
  'baseUrl': ${BASE_URL@Q},
  'apiKey': ${API_KEY@Q},
  'model': ${MODEL_NAME@Q},
  'headful': True,
  'resolution': {'width': 1920, 'height': 1080}
}, ensure_ascii=False, indent=2) + '\n')
print(path)
PY
}

install_feishu_plugin_and_config() {
  local current_app_id=""
  local current_app_secret=""
  local feishu_app_id=""
  local feishu_app_secret=""

  if [[ -f /usr/local/lib/node_modules/openclaw/extensions/feishu/openclaw.plugin.json ]] || [[ -f /usr/lib/node_modules/openclaw/extensions/feishu/openclaw.plugin.json ]]; then
    echo "Feishu plugin already bundled with current OpenClaw installation; skipping npm install"
  else
    echo "installing Feishu plugin: ${FEISHU_PLUGIN_SPEC}"
    openclaw plugins install "$FEISHU_PLUGIN_SPEC"
  fi

  current_app_id="$(python3 - <<PY
import json
from pathlib import Path
cfg = json.loads(Path(${CONFIG_PATH@Q}).read_text())
print(((cfg.get('channels') or {}).get('feishu') or {}).get('appId', ''))
PY
)"
  current_app_secret="$(python3 - <<PY
import json
from pathlib import Path
cfg = json.loads(Path(${CONFIG_PATH@Q}).read_text())
print(((cfg.get('channels') or {}).get('feishu') or {}).get('appSecret', ''))
PY
)"

  if [[ "$TENANT_NONINTERACTIVE" == "1" ]]; then
    feishu_app_id="$TENANT_FEISHU_APP_ID"
    feishu_app_secret="$TENANT_FEISHU_APP_SECRET"
  else
    feishu_app_id="$(prompt 'Feishu appId' "$current_app_id")"
    feishu_app_secret="$(prompt 'Feishu appSecret' "$current_app_secret")"
  fi

  openclaw config set channels.feishu.appId "\"${feishu_app_id}\""
  openclaw config set channels.feishu.appSecret "\"${feishu_app_secret}\""
  openclaw config set channels.feishu.enabled true --strict-json

  python3 - <<PY
import json
from pathlib import Path
cfg_path = Path(${CONFIG_PATH@Q})
cfg = json.loads(cfg_path.read_text())
channels = cfg.setdefault('channels', {})
feishu = channels.setdefault('feishu', {})
feishu['dmPolicy'] = 'open'
feishu['allowFrom'] = ['*']
cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n')
print('updated feishu channel settings in', cfg_path)
PY
}

setup_host_model_proxy() {
  local state_dir="$1"
  local upstream_base="$2"
  local upstream_key="$3"
  local proxy_token="$4"
  local proxy_port="$5"
  local proxy_pid_file="$state_dir/proxy.pid"
  local proxy_log_file="$state_dir/proxy.log"
  mkdir -p "$state_dir"
  stop_pid_file "$proxy_pid_file"
  local proxy_cmd proxy_pid
  printf -v proxy_cmd 'python3 %q --listen %q --port %q --upstream %q --api-key %q --require-bearer %q > %q 2>&1' \
    "$SCRIPT_DIR/app-proxy/openai_proxy.py" \
    "0.0.0.0" \
    "$proxy_port" \
    "$upstream_base" \
    "$upstream_key" \
    "$proxy_token" \
    "$proxy_log_file"
  proxy_pid="$(spawn_detached "$proxy_cmd")"
  echo "$proxy_pid" > "$proxy_pid_file"
  if ! wait_for_tcp_port "127.0.0.1" "$proxy_port" 30 1; then
    echo "tenant proxy failed to start on port $proxy_port" >&2
    [[ -f "$proxy_log_file" ]] && tail -n 80 "$proxy_log_file" >&2 || true
    return 1
  fi
}

setup_tenant_expiry() {
  local container_name="$1"
  local seconds="$2"
  local state_dir="$3"
  bash "$SCRIPT_DIR/scripts/tenant-schedule-expiry.sh" "$container_name" "$seconds" "$state_dir"
}

run_tenant_mode() {
  need_bin docker
  local compose_cmd
  compose_cmd="$(docker_compose_cmd)" || {
    echo 'docker compose not available' >&2
    exit 1
  }
  local duration_label duration_seconds model_mode tenant_short_uuid tenant_name tenant_container tenant_gateway_port tenant_vnc_port tenant_data_dir tenant_state_dir tenant_proxy_token tenant_proxy_port tenant_vnc_password host_base host_key host_model effective_base effective_key effective_model tenant_allowed_origins_json created_at expires_at expiry_mode expiry_unit
  duration_label="$(choose_tenant_duration)"
  duration_seconds="$(tenant_duration_seconds "$duration_label")"
  model_mode="$(choose_tenant_model_mode)"
  tenant_short_uuid="$(python3 - "$TENANT_SHORT_UUID" <<'PY'
import re
import secrets
import sys

candidate = (sys.argv[1] or '').strip().lower()
if candidate:
    candidate = re.sub(r'[^a-z0-9]', '', candidate)
    if len(candidate) < 4:
        raise SystemExit('tenant short uuid must be at least 4 lowercase alphanumeric characters')
else:
    candidate = secrets.token_hex(4)
print(candidate)
PY
)"
  if [[ -z "$tenant_short_uuid" ]]; then
    echo "failed to derive tenant short uuid" >&2
    return 1
  fi
  tenant_name="tenant-$(date -u +%Y%m%d%H%M%S)-${tenant_short_uuid}"
  tenant_container="${tenant_name}-openclaw"
  tenant_gateway_port="$(find_free_port)"
  tenant_vnc_port="$(find_free_port)"
  while [[ "$tenant_vnc_port" == "$tenant_gateway_port" ]]; do
    tenant_vnc_port="$(find_free_port)"
  done
  tenant_data_dir="$HOME/.openclaw-tenants/${tenant_name}"
  tenant_state_dir="$HOME/.openclaw/tenant-state/${tenant_name}"
  mkdir -p "$tenant_data_dir" "$tenant_state_dir"
  chmod 700 "$tenant_data_dir" "$tenant_state_dir" 2>/dev/null || true
  tenant_vnc_password="${TENANT_VNC_PASSWORD:-$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(8)))
PY
)}"

  if [[ "$model_mode" == "proxy" ]]; then
    mapfile -t CURRENT < <(current_values)
    host_base="$(prompt '宿主 Base URL' "${TENANT_HOST_BASE_URL:-${CURRENT[0]}}")"
    host_key="$(prompt '宿主 API key' "${TENANT_HOST_API_KEY:-${CURRENT[1]}}")"
    host_model="$(prompt '宿主 Model name' "${TENANT_HOST_MODEL:-${CURRENT[2]}}")"
    tenant_proxy_token="tenant-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
    tenant_proxy_port="$(find_free_port)"
    while [[ "$tenant_proxy_port" == "$tenant_gateway_port" || "$tenant_proxy_port" == "$tenant_vnc_port" ]]; do
      tenant_proxy_port="$(find_free_port)"
    done
    setup_host_model_proxy "$tenant_state_dir" "$host_base" "$host_key" "$tenant_proxy_token" "$tenant_proxy_port"
    effective_base="http://host.docker.internal:${tenant_proxy_port}/v1"
    effective_key="$tenant_proxy_token"
    effective_model="$host_model"
  else
    effective_base="$(prompt '租户 Base URL' "$TENANT_BASE_URL")"
    effective_key="$(prompt '租户 API key' "$TENANT_API_KEY")"
    effective_model="$(prompt '租户 Model name' "${TENANT_MODEL:-gpt-5.4}")"
  fi

  local tenant_feishu_app_id tenant_feishu_app_secret
  tenant_feishu_app_id="$(prompt '租户 Feishu appId' "$TENANT_FEISHU_APP_ID")"
  tenant_feishu_app_secret="$(prompt '租户 Feishu appSecret' "$TENANT_FEISHU_APP_SECRET")"
  tenant_allowed_origins_json="$(json_array \
    "http://localhost:${tenant_gateway_port}" \
    "http://127.0.0.1:${tenant_gateway_port}" \
    "http://localhost:18789" \
    "http://127.0.0.1:18789")"
  export TENANT_CONTAINER_NAME="$tenant_container"
  export TENANT_GATEWAY_PORT="$tenant_gateway_port"
  export TENANT_VNC_PORT="$tenant_vnc_port"
  export TENANT_DATA_DIR="$tenant_data_dir"
  export TENANT_BASE_URL="$effective_base"
  export TENANT_API_KEY="$effective_key"
  export TENANT_MODEL="$effective_model"
  export TENANT_FEISHU_APP_ID="$tenant_feishu_app_id"
  export TENANT_FEISHU_APP_SECRET="$tenant_feishu_app_secret"
  export TENANT_VNC_PASSWORD="$tenant_vnc_password"
  export TENANT_PROXY_MODE="$model_mode"
  export OPENCLAW_GATEWAY_BIND="lan"
  export OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON="$tenant_allowed_origins_json"
  export OPENCLAW_GATEWAY_PORT="18789"

  $compose_cmd -p "$tenant_name" -f "$SCRIPT_DIR/tenant-mode/docker-compose.yml" up -d --build
  echo "waiting for tenant container to finish installation..."
  if ! wait_for_tenant_ready "$tenant_container" "$TENANT_READY_TIMEOUT_SECONDS"; then
    stop_pid_file "$tenant_state_dir/proxy.pid"
    return 1
  fi
  created_at="$(date -u +%FT%TZ)"
  expires_at="$(python3 - <<PY
from datetime import datetime, timedelta, timezone

created_at = datetime.strptime(${created_at@Q}, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
print((created_at + timedelta(seconds=int(${duration_seconds@Q}))).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)"
  setup_tenant_expiry "$tenant_container" "$duration_seconds" "$tenant_state_dir"
  expiry_mode="$(cat "$tenant_state_dir/expiry.mode" 2>/dev/null || true)"
  expiry_unit="$(cat "$tenant_state_dir/expiry.unit" 2>/dev/null || true)"
  write_tenant_state \
    "$tenant_state_dir/tenant.json" \
    "$tenant_name" \
    "$tenant_container" \
    "$tenant_short_uuid" \
    "$duration_label" \
    "$duration_seconds" \
    "$model_mode" \
    "$tenant_gateway_port" \
    "$tenant_vnc_port" \
    "$tenant_data_dir" \
    "${tenant_proxy_port:-}" \
    "$created_at" \
    "$expires_at" \
    "$tenant_vnc_password" \
    "$expiry_mode" \
    "$expiry_unit" \
    "$effective_base" \
    "$effective_model" \
    "$tenant_feishu_app_id"

  cat <<EOF
租户模式已启动。
- short uuid: $tenant_short_uuid
- tenant: $tenant_name
- container: $tenant_container
- gateway ws port: $tenant_gateway_port
- vnc port: $tenant_vnc_port
- vnc password: $tenant_vnc_password
- duration: $duration_label (${duration_seconds}s)
- expires at (UTC): $expires_at
- model mode: $model_mode
- data dir: $tenant_data_dir
- state dir: $tenant_state_dir
- expiry scheduler: ${expiry_mode:-sleep-fallback}${expiry_unit:+ ($expiry_unit)}
EOF
}

configure_agile_codex_runtime() {
  local backend="process"
  local has_tmux="false"
  local has_jq="false"
  local has_wsl="false"

  if command -v tmux >/dev/null 2>&1; then
    backend="tmux"
    has_tmux="true"
  fi
  if command -v jq >/dev/null 2>&1; then
    has_jq="true"
  fi
  if command -v wsl >/dev/null 2>&1 || command -v wsl.exe >/dev/null 2>&1; then
    has_wsl="true"
  fi

  if is_linux || is_macos; then
    ensure_optional_bin jq jq || true
    if command -v jq >/dev/null 2>&1; then has_jq="true"; fi
    ensure_optional_bin tmux tmux || true
    if command -v tmux >/dev/null 2>&1; then backend="tmux"; has_tmux="true"; fi
  elif is_windows_like; then
    if [[ "$has_wsl" == "true" ]]; then
      backend="wsl"
    fi
  fi

  python3 - <<PY
import json
from pathlib import Path
path = Path(${AGILE_CODEX_RUNTIME_DIR@Q}) / 'platform.json'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
  'backend': ${backend@Q},
  'has_tmux': ${has_tmux@Q} == "true",
  'has_jq': ${has_jq@Q} == "true",
  'has_wsl': ${has_wsl@Q} == "true",
  'host_os': ${OSTYPE@Q},
}, ensure_ascii=False, indent=2) + '\n')
print(path)
PY
}

run_doctor_fix() {
  if openclaw doctor --fix >/tmp/openclaw-doctor-fix.log 2>&1; then
    echo "doctor --fix completed"
    return 0
  fi

  echo "doctor --fix failed" >&2
  [[ -f /tmp/openclaw-doctor-fix.log ]] && tail -n 120 /tmp/openclaw-doctor-fix.log >&2 || true
  return 1
}

restart_gateway_after_feishu_config() {
  if [[ -f /tmp/openclaw-gateway-run.pid ]]; then
    local old_pid
    old_pid="$(cat /tmp/openclaw-gateway-run.pid 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
  fi

  if is_container_like || ! have_systemd_user; then
    start_gateway_detached
    wait_for_gateway 30 2
    return
  fi

  if openclaw gateway restart >/tmp/openclaw-gateway-restart.log 2>&1; then
    if wait_for_gateway 20 2; then
      echo "gateway restarted after Feishu config"
      return 0
    fi
  fi

  start_gateway_detached
  wait_for_gateway 30 2
}

wait_for_gateway() {
  local attempts="${1:-30}"
  local delay_sec="${2:-2}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if openclaw gateway health >/tmp/openclaw-gateway-health.log 2>&1; then
      return 0
    fi
    sleep "$delay_sec"
  done
  return 1
}

start_gateway_for_cron() {
  rm -f /tmp/openclaw-gateway-start.log /tmp/openclaw-gateway-run.log /tmp/openclaw-gateway-run.pid /tmp/openclaw-gateway-health.log

  if openclaw gateway start >/tmp/openclaw-gateway-start.log 2>&1; then
    if wait_for_gateway 15 2; then
      echo "gateway started via service manager"
      return 0
    fi
  fi

  if [[ -f /tmp/openclaw-gateway-run.pid ]]; then
    local old_pid
    old_pid="$(cat /tmp/openclaw-gateway-run.pid 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'exec openclaw gateway run >/tmp/openclaw-gateway-run.log 2>&1' </dev/null >/dev/null 2>&1 &
  else
    nohup openclaw gateway run </dev/null >/tmp/openclaw-gateway-run.log 2>&1 &
  fi
  echo $! >/tmp/openclaw-gateway-run.pid

  if wait_for_gateway 30 2; then
    echo "gateway started via foreground fallback"
    return 0
  fi

  echo "failed to start gateway" >&2
  [[ -f /tmp/openclaw-gateway-start.log ]] && tail -n 80 /tmp/openclaw-gateway-start.log >&2 || true
  [[ -f /tmp/openclaw-gateway-run.log ]] && tail -n 80 /tmp/openclaw-gateway-run.log >&2 || true
  return 1
}

monitor_message() {
  cat <<'EOF'
你是 agile-codex 的周期监控器。请监控 ~/.openclaw/skills/agile-codex/runtime 下的运行状态，并每 10 分钟检查所有会话。

规则：
1. 检查 `~/.openclaw/skills/agile-codex/runtime` 下的 `*.status.json`、`*.meta.json`、`*.tail.txt`、`*.last.txt`。
2. 只对以下情况输出播报：
   - `active_work=true`
   - `needs_input=true`
   - `completed=true`
   - `state=missing` 且已尝试恢复
3. 如果会话只是 idle / standby / waiting / 0 active task / 无活跃任务，则不要播报。
4. 对需要播报的会话，汇报：
   - 会话名
   - 当前状态
   - 最近阶段/动作
   - 是否像是卡住
   - 下一步
5. 如果会话 state=missing 且可恢复，尝试调用恢复脚本，并在汇报里写明。
6. 如果发现 needs_input=true，明确告诉用户需要人工输入。
7. 如果完全没有需要播报的活跃会话，只回复 `HEARTBEAT_OK`。
8. 如已完成对某个会话的播报，调用 `~/.openclaw/skills/agile-codex/scripts/codex_agile_mark_reported.sh <session-name> <reason>` 标记，避免同一时间槽重复播报。

输出要求：
- 没有需要播报的会话：只输出 `HEARTBEAT_OK`
- 有需要播报的会话：输出简短项目播报，避免空话。
EOF
}

install_progress_monitor() {
  local existing_id=""
  existing_id="$(cron_job_id_by_name "$AGILE_CODEX_MONITOR_NAME")"

  local msg
  msg="$(monitor_message)"

  if [[ -n "$existing_id" ]]; then
    echo "updating existing progress monitor: $existing_id"
    openclaw cron edit "$existing_id" \
      --enable \
      --name "$AGILE_CODEX_MONITOR_NAME" \
      --description "Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input." \
      --every 10m \
      --session isolated \
      --light-context \
      --announce \
      --message "$msg" >/dev/null
  else
    echo "creating progress monitor"
    openclaw cron add \
      --name "$AGILE_CODEX_MONITOR_NAME" \
      --description "Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input." \
      --every 10m \
      --session isolated \
      --wake now \
      --light-context \
      --announce \
      --message "$msg" >/dev/null
  fi

  if [[ -n "$AGILE_CODEX_MONITOR_CHANNEL" ]]; then
    local refreshed_id=""
    refreshed_id="$(cron_job_id_by_name "$AGILE_CODEX_MONITOR_NAME")"
    if [[ -n "$refreshed_id" ]]; then
      if [[ -n "$AGILE_CODEX_MONITOR_TO" ]]; then
        openclaw cron edit "$refreshed_id" --channel "$AGILE_CODEX_MONITOR_CHANNEL" --to "$AGILE_CODEX_MONITOR_TO" >/dev/null
      else
        openclaw cron edit "$refreshed_id" --channel "$AGILE_CODEX_MONITOR_CHANNEL" >/dev/null
      fi
      if [[ -n "$AGILE_CODEX_MONITOR_ACCOUNT" ]]; then
        openclaw cron edit "$refreshed_id" --account "$AGILE_CODEX_MONITOR_ACCOUNT" >/dev/null
      fi
    fi
  fi
}

self_check() {
  echo
  echo "== self-check =="
  openclaw --version | head -n 1
  codex --version | head -n 1
  python3 - <<PY
import json
from pathlib import Path
cfg = json.loads(Path(${CONFIG_PATH@Q}).read_text())
platform_path = Path(${AGILE_CODEX_RUNTIME_DIR@Q}) / 'platform.json'
platform = json.loads(platform_path.read_text()) if platform_path.exists() else {}
feishu = ((cfg.get('channels') or {}).get('feishu') or {})
browser_use_cfg_path = Path(${SKILLS_DIR@Q}) / 'browser-use' / 'runtime' / 'config.json'
browser_use_cfg = json.loads(browser_use_cfg_path.read_text()) if browser_use_cfg_path.exists() else {}
print(json.dumps({
  'primary': cfg['agents']['defaults']['model']['primary'],
  'workspace': cfg['agents']['defaults']['workspace'],
  'using-superpowers': cfg.get('skills',{}).get('entries',{}).get('using-superpowers',{}).get('enabled'),
  'agile-codex': cfg.get('skills',{}).get('entries',{}).get('agile-codex',{}).get('enabled'),
  'browser-use': cfg.get('skills',{}).get('entries',{}).get('browser-use',{}).get('enabled'),
  'local-long-memory': cfg.get('skills',{}).get('entries',{}).get('local-long-memory',{}).get('enabled'),
  'skillsDirExists': Path(${SKILLS_DIR@Q}).exists(),
  'agileCodexPlatform': platform,
  'feishu': {
    'enabled': feishu.get('enabled'),
    'appId': feishu.get('appId'),
    'hasAppSecret': bool(feishu.get('appSecret')),
    'dmPolicy': feishu.get('dmPolicy'),
    'allowFrom': feishu.get('allowFrom'),
  },
  'pluginsAllow': ((cfg.get('plugins') or {}).get('allow') or []),
  'browserUseConfig': browser_use_cfg,
}, ensure_ascii=False, indent=2))
PY
  test -f "$SKILLS_DIR/using-superpowers/SKILL.md"
  test -f "$SKILLS_DIR/agile-codex/SKILL.md"
  test -f "$SKILLS_DIR/browser-use/SKILL.md"
  test -f "$SKILLS_DIR/local-long-memory/SKILL.md"
  test -f "$SKILLS_DIR/agile-codex/scripts/agile_codex_backend.py"
  test -f "$SKILLS_DIR/local-long-memory/scripts/memory_core.py"
  test -f "$HOOKS_DIR/memory-preload-bundle/HOOK.md"
  test -f "$HOOKS_DIR/memory-auto-capture/HOOK.md"
  openclaw agent --agent main -m "Reply with exactly INSTALLER_SMOKE_OK and nothing else." --json --timeout 60 >/tmp/openclaw-native-smoke.json 2>&1 || true
  tail -n 40 /tmp/openclaw-native-smoke.json
  openclaw cron list --json >/tmp/openclaw-native-cron.json 2>&1 || true
  tail -n 60 /tmp/openclaw-native-cron.json
}

ensure_agent_state_dirs() {
  local agent_root="$HOME/.openclaw/agents/main"
  local sessions_dir="$agent_root/sessions"
  local agent_dir="$agent_root/agent"
  mkdir -p "$sessions_dir" "$agent_dir"
  if [[ ! -f "$sessions_dir/sessions.json" ]]; then
    printf '{"sessions":[]}\n' > "$sessions_dir/sessions.json"
  fi
}

main() {
  local selected_mode
  selected_mode="$(choose_install_mode)"
  if [[ "$selected_mode" == "tenant" && "${1:-}" != "--tenant-container" ]]; then
    run_tenant_mode
    return 0
  fi

  need_bin node
  need_bin npm
  need_bin python3
  install_openclaw
  install_codex
  bootstrap_if_missing
  ensure_agent_state_dirs

  if [[ "$TENANT_NONINTERACTIVE" == "1" ]]; then
    BASE_URL="$TENANT_BASE_URL"
    API_KEY="$TENANT_API_KEY"
    MODEL_NAME="$TENANT_MODEL"
  else
    mapfile -t CURRENT < <(current_values)
    BASE_URL="$(prompt 'Base URL' "${CURRENT[0]}")"
    API_KEY="$(prompt 'API key' "${CURRENT[1]}")"
    MODEL_NAME="$(prompt 'Model name' "${CURRENT[2]}")"
  fi

  write_openclaw_config
  write_codex_config
  install_feishu_plugin_and_config
  run_doctor_fix
  restart_gateway_after_feishu_config
  install_local_skills
  write_browser_use_skill_config
  configure_agile_codex_runtime
  install_progress_monitor
  self_check
}

main "$@"

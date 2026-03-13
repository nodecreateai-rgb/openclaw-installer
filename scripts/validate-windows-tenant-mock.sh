#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERSHELL_IMAGE="${POWERSHELL_IMAGE:-mcr.microsoft.com/powershell}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-win-tenant-validate.XXXXXX")"
STATE_DIR="$WORK_DIR/state"
MOCKBIN_DIR="$WORK_DIR/mockbin"
MOCKBIN_NOSCHTASKS_DIR="$WORK_DIR/mockbin-noschtasks"
HTTP_PORT="${WINDOWS_TENANT_VALIDATE_HTTP_PORT:-}"
HTTP_PID=""

log() {
  printf '[windows-tenant-validate] %s\n' "$*"
}

fail() {
  printf '[windows-tenant-validate] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${HTTP_PID:-}" ]] && kill -0 "$HTTP_PID" >/dev/null 2>&1; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
    wait "$HTTP_PID" >/dev/null 2>&1 || true
  fi
  if [[ "${KEEP_VALIDATION_WORKDIR:-0}" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    log "keeping workdir: $WORK_DIR"
  fi
}
trap cleanup EXIT

need_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required binary: $1"
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

pick_free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

assert_contains() {
  local file="$1"
  local needle="$2"
  require_file "$file"
  grep -Fq -- "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  require_file "$file"
  if grep -Fq -- "$needle" "$file"; then
    fail "did not expect '$needle' in $file"
  fi
}

json_value() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
value = payload
for part in sys.argv[2].split('.'):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    raise SystemExit(1)
if isinstance(value, bool):
    print('true' if value else 'false')
else:
    print(value)
PY
}

latest_subdir() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

to_container_path() {
  local path="$1"
  printf '%s\n' "${path/$WORK_DIR/\/test}"
}

to_host_path() {
  local path="$1"
  printf '%s\n' "${path/\/test/$WORK_DIR}"
}

setup_mocks() {
  mkdir -p "$MOCKBIN_DIR" "$MOCKBIN_NOSCHTASKS_DIR" "$STATE_DIR"

  cat > "$MOCKBIN_DIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${MOCK_DOCKER_STATE_DIR:?missing MOCK_DOCKER_STATE_DIR}"
mkdir -p "$state_dir"
printf 'docker %s\n' "$*" >> "$state_dir/docker.log"
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  echo 'Docker Compose version v0.mock'
  exit 0
fi
if [[ "${1:-}" == "compose" ]]; then
  shift
  project=''
  compose_file=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p)
        project="$2"
        shift 2
        ;;
      -f)
        compose_file="$2"
        shift 2
        ;;
      up)
        container="${TENANT_CONTAINER_NAME:?missing TENANT_CONTAINER_NAME}"
        container_dir="$state_dir/$container"
        mkdir -p "$container_dir"
        printf 'running' > "$container_dir/status"
        : > "$container_dir/ready"
        env | sort > "$container_dir/compose.env"
        printf '%s\n' "$project" > "$container_dir/project"
        printf '%s\n' "$compose_file" > "$container_dir/compose-file"
        printf '%s\n' "$*" > "$container_dir/compose-args"
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done
fi
if [[ "${1:-}" == "inspect" && "${2:-}" == "-f" ]]; then
  format="$3"
  container="$4"
  container_dir="$state_dir/$container"
  case "$format" in
    '{{.State.Status}}')
      [[ -f "$container_dir/status" ]] && cat "$container_dir/status"
      exit 0
      ;;
    '{{.State.Running}}')
      if [[ -f "$container_dir/status" && "$(cat "$container_dir/status")" == "running" ]]; then
        echo 'true'
      else
        echo 'false'
      fi
      exit 0
      ;;
  esac
fi
if [[ "${1:-}" == "exec" ]]; then
  container="$2"
  shift 2
  container_dir="$state_dir/$container"
  if [[ "${1:-}" == "test" && "${2:-}" == "-f" && "${3:-}" == "/tmp/tenant-ready" ]]; then
    [[ -f "$container_dir/ready" ]]
    exit $?
  fi
  if [[ "${1:-}" == "openclaw" && "${2:-}" == "gateway" && "${3:-}" == "health" ]]; then
    [[ -f "$container_dir/ready" && ! -f "$container_dir/disabled" ]]
    exit $?
  fi
  if [[ "${1:-}" == "bash" && "${2:-}" == "-lc" ]]; then
    printf '%s\n' "$3" > "$container_dir/disable-command"
    : > "$container_dir/disabled"
    exit 0
  fi
  exit 0
fi
if [[ "${1:-}" == "logs" ]]; then
  container="${@: -1}"
  container_dir="$state_dir/$container"
  [[ -f "$container_dir/logs" ]] && cat "$container_dir/logs"
  exit 0
fi
echo "unsupported docker invocation: $*" >&2
exit 1
EOF
  chmod +x "$MOCKBIN_DIR/docker"

  cat > "$MOCKBIN_DIR/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -gt 0 && "$1" == *'app-proxy/openai_proxy.py' ]]; then
  shift
  port=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        port="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "$port" ]] || { echo 'missing --port for mock python3 proxy' >&2; exit 1; }
  exec pwsh -NoLogo -NoProfile -Command "\$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port); \$listener.Start(); try { while (\$true) { Start-Sleep -Seconds 1 } } finally { \$listener.Stop() }"
fi
echo "mock python3 unsupported args: $*" >&2
exit 1
EOF
  chmod +x "$MOCKBIN_DIR/python3"

  cat > "$MOCKBIN_DIR/schtasks.exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${MOCK_SCHTASKS_STATE_DIR:?missing MOCK_SCHTASKS_STATE_DIR}"
mkdir -p "$state_dir"
printf 'schtasks %s\n' "$*" >> "$state_dir/schtasks.log"
if [[ "${1:-}" == '/Create' ]]; then
  task_name=''
  task_cmd=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      /TN)
        task_name="$2"
        shift 2
        ;;
      /TR)
        task_cmd="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  printf '%s\n' "$task_name" > "$state_dir/last_task_name"
  printf '%s\n' "$task_cmd" > "$state_dir/last_task_cmd"
  exit 0
fi
if [[ "${1:-}" == '/Delete' ]]; then
  exit 0
fi
echo "unsupported schtasks invocation: $*" >&2
exit 1
EOF
  chmod +x "$MOCKBIN_DIR/schtasks.exe"

  cp "$MOCKBIN_DIR/docker" "$MOCKBIN_NOSCHTASKS_DIR/docker"
  cp "$MOCKBIN_DIR/python3" "$MOCKBIN_NOSCHTASKS_DIR/python3"
}

run_install_ps1() {
  local home_name="$1"
  local mock_path="$2"
  shift 2
  docker run --rm \
    -v "$ROOT_DIR:/repo" \
    -v "$WORK_DIR:/test" \
    -w /repo \
    -e HOME="/test/$home_name" \
    -e TEMP="/test/tmp-$home_name" \
    -e MOCK_PATH="$mock_path" \
    "$@" \
    "$POWERSHELL_IMAGE" \
    pwsh -NoLogo -NoProfile -Command '$env:PATH = $env:MOCK_PATH + ":" + $env:PATH; & /repo/install.ps1'
}

run_remote_bootstrap() {
  local home_name="$1"
  local archive_url="$2"
  docker run --rm --network host \
    -v "$ROOT_DIR:/repo" \
    -v "$WORK_DIR:/test" \
    -w /repo \
    -e HOME="/test/$home_name" \
    -e TEMP="/test/tmp-$home_name" \
    -e MOCK_PATH="/test/mockbin" \
    -e OPENCLAW_INSTALLER_ARCHIVE_URL="$archive_url" \
    -e INSTALL_MODE=tenant \
    -e TENANT_NONINTERACTIVE=1 \
    -e TENANT_PROXY_MODE=custom \
    -e TENANT_DURATION_LABEL=1h \
    -e TENANT_BASE_URL=https://tenant.remote.example/v1 \
    -e TENANT_API_KEY=tenant-remote-key \
    -e TENANT_MODEL=gpt-5.4 \
    -e TENANT_FEISHU_APP_ID=feishu-app \
    -e TENANT_FEISHU_APP_SECRET=feishu-secret \
    -e MOCK_DOCKER_STATE_DIR=/test/state/remote-docker \
    -e MOCK_SCHTASKS_STATE_DIR=/test/state/remote-schtasks \
    "$POWERSHELL_IMAGE" \
    pwsh -NoLogo -NoProfile -Command '$env:PATH = $env:MOCK_PATH + ":" + $env:PATH; $content = Get-Content /repo/install.ps1 -Raw; Invoke-Expression $content'
}

run_tenant_expire() {
  local state_dir="$1"
  local container_name="$2"
  local write_expiry_pid="${3:-0}"
  local command
  command='$env:PATH = $env:MOCK_PATH + ":" + $env:PATH; '
  if [[ "$write_expiry_pid" == "1" ]]; then
    command+='Set-Content -Path (Join-Path "'"$state_dir"'" "expiry.pid") -Value $PID -Encoding UTF8; '
  fi
  command+='& /repo/scripts/tenant-expire.ps1 -ContainerName "'"$container_name"'" -StateDir "'"$state_dir"'"'
  docker run --rm \
    -v "$ROOT_DIR:/repo" \
    -v "$WORK_DIR:/test" \
    -w /repo \
    -e MOCK_PATH="/test/mockbin" \
    -e MOCK_DOCKER_STATE_DIR=/test/state/proxy-docker \
    "$POWERSHELL_IMAGE" \
    pwsh -NoLogo -NoProfile -Command "$command"
}

run_tenant_reconcile() {
  local home_name="$1"
  local docker_state_dir="$2"
  local tenant_name="$3"
  docker run --rm \
    -v "$ROOT_DIR:/repo" \
    -v "$WORK_DIR:/test" \
    -w /repo \
    -e HOME="/test/$home_name" \
    -e TEMP="/test/tmp-$home_name" \
    -e MOCK_PATH="/test/mockbin" \
    -e MOCK_DOCKER_STATE_DIR="$docker_state_dir" \
    "$POWERSHELL_IMAGE" \
    pwsh -NoLogo -NoProfile -Command '$env:PATH = $env:MOCK_PATH + ":" + $env:PATH; & /repo/scripts/tenant-reconcile-disabled.ps1 "'"$tenant_name"'"'
}

build_archive() {
  python3 - "$ROOT_DIR" "$WORK_DIR/openclaw-installer-main.zip" <<'PY'
from pathlib import Path
import zipfile
import sys

repo = Path(sys.argv[1])
out = Path(sys.argv[2])
root_name = 'openclaw-installer-main'
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for path in repo.rglob('*'):
        if '.git' in path.parts:
            continue
        if path.is_dir():
            continue
        rel = path.relative_to(repo)
        zf.write(path, (Path(root_name) / rel).as_posix())
PY
}

start_archive_server() {
  if [[ -z "$HTTP_PORT" ]]; then
    HTTP_PORT="$(pick_free_port)"
  fi
  python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK_DIR" >/dev/null 2>&1 &
  HTTP_PID="$!"
  sleep 1
  kill -0 "$HTTP_PID" >/dev/null 2>&1 || fail "failed to start archive server on port $HTTP_PORT"
}

validate_custom_schtasks() {
  log 'running custom tenant scenario with schtasks'
  run_install_ps1 \
    home-custom \
    /test/mockbin \
    -e INSTALL_MODE=tenant \
    -e TENANT_NONINTERACTIVE=1 \
    -e TENANT_PROXY_MODE=custom \
    -e TENANT_DURATION_LABEL=1h \
    -e TENANT_BASE_URL=https://tenant.example/v1 \
    -e TENANT_API_KEY=tenant-custom-key \
    -e TENANT_MODEL=gpt-5.4 \
    -e TENANT_FEISHU_APP_ID=feishu-app \
    -e TENANT_FEISHU_APP_SECRET=feishu-secret \
    -e MOCK_DOCKER_STATE_DIR=/test/state/custom-docker \
    -e MOCK_SCHTASKS_STATE_DIR=/test/state/custom-schtasks

  local tenant_dir
  tenant_dir="$(latest_subdir "$WORK_DIR/home-custom/.openclaw/tenant-state")"
  require_file "$tenant_dir/tenant.json"
  [[ "$(json_value "$tenant_dir/tenant.json" modelMode)" == "custom" ]] || fail 'custom tenant.json modelMode mismatch'
  [[ "$(cat "$tenant_dir/expiry.mode")" == "windows-schtasks" ]] || fail 'custom expiry.mode mismatch'
  require_file "$WORK_DIR/state/custom-schtasks/last_task_cmd"
  assert_contains "$WORK_DIR/state/custom-schtasks/last_task_cmd" 'scripts/tenant-expire.ps1'
  assert_contains "$WORK_DIR/state/custom-schtasks/last_task_cmd" '-ContainerName "'
  assert_contains "$WORK_DIR/state/custom-schtasks/last_task_cmd" '-StateDir "'
  assert_contains "$WORK_DIR/state/custom-schtasks/last_task_cmd" '-SleepSeconds "'

  local compose_env
  compose_env="$(latest_subdir "$WORK_DIR/state/custom-docker")/compose.env"
  require_file "$compose_env"
  assert_contains "$compose_env" 'TENANT_PROXY_MODE=custom'
  assert_contains "$compose_env" 'TENANT_BASE_URL=https://tenant.example/v1'
}

validate_proxy_schtasks_and_expire() {
  log 'running proxy tenant scenario with schtasks'
  run_install_ps1 \
    home-proxy \
    /test/mockbin \
    -e INSTALL_MODE=tenant \
    -e TENANT_NONINTERACTIVE=1 \
    -e TENANT_PROXY_MODE=proxy \
    -e TENANT_DURATION_LABEL=1h \
    -e TENANT_HOST_BASE_URL=https://host.example/v1 \
    -e TENANT_HOST_API_KEY=host-secret-key \
    -e TENANT_HOST_MODEL=gpt-4o-mini \
    -e TENANT_FEISHU_APP_ID=feishu-app \
    -e TENANT_FEISHU_APP_SECRET=feishu-secret \
    -e MOCK_DOCKER_STATE_DIR=/test/state/proxy-docker \
    -e MOCK_SCHTASKS_STATE_DIR=/test/state/proxy-schtasks

  local tenant_dir tenant_json compose_env container_name data_dir data_dir_host
  tenant_dir="$(latest_subdir "$WORK_DIR/home-proxy/.openclaw/tenant-state")"
  tenant_json="$tenant_dir/tenant.json"
  require_file "$tenant_json"
  [[ "$(json_value "$tenant_json" modelMode)" == "proxy" ]] || fail 'proxy tenant.json modelMode mismatch'
  json_value "$tenant_json" proxyPort >/dev/null

  compose_env="$(latest_subdir "$WORK_DIR/state/proxy-docker")/compose.env"
  require_file "$compose_env"
  assert_contains "$compose_env" 'TENANT_PROXY_MODE=proxy'
  assert_contains "$compose_env" 'TENANT_BASE_URL=http://host.docker.internal:'
  assert_contains "$compose_env" 'TENANT_API_KEY=tenant-'
  assert_contains "$compose_env" 'TENANT_MODEL=gpt-4o-mini'
  assert_contains "$WORK_DIR/state/proxy-schtasks/last_task_cmd" '-ContainerName "'
  assert_contains "$WORK_DIR/state/proxy-schtasks/last_task_cmd" '-StateDir "'
  assert_contains "$WORK_DIR/state/proxy-schtasks/last_task_cmd" '-SleepSeconds "'

  container_name="$(json_value "$tenant_json" container)"
  data_dir="$(json_value "$tenant_json" dataDir)"
  data_dir_host="$(to_host_path "$data_dir")"
  run_tenant_expire "$(to_container_path "$tenant_dir")" "$container_name" 1
  require_file "$tenant_dir/disabled-at"
  require_file "$data_dir_host/TENANT_DISABLED"
  [[ ! -f "$tenant_dir/proxy.pid" ]] || fail 'proxy pid file should be removed after expiry'
  [[ ! -f "$tenant_dir/expiry.pid" ]] || fail 'expiry pid file should be removed when the fallback process exits'
  require_file "$(latest_subdir "$WORK_DIR/state/proxy-docker")/disable-command"
}

validate_fallback_scheduler() {
  log 'running custom tenant scenario without schtasks'
  run_install_ps1 \
    home-fallback \
    /test/mockbin-noschtasks \
    -e INSTALL_MODE=tenant \
    -e TENANT_NONINTERACTIVE=1 \
    -e TENANT_PROXY_MODE=custom \
    -e TENANT_DURATION_LABEL=1h \
    -e TENANT_BASE_URL=https://tenant.fallback.example/v1 \
    -e TENANT_API_KEY=tenant-fallback-key \
    -e TENANT_MODEL=gpt-5.4 \
    -e TENANT_FEISHU_APP_ID=feishu-app \
    -e TENANT_FEISHU_APP_SECRET=feishu-secret \
    -e MOCK_DOCKER_STATE_DIR=/test/state/fallback-docker

  local tenant_dir
  tenant_dir="$(latest_subdir "$WORK_DIR/home-fallback/.openclaw/tenant-state")"
  require_file "$tenant_dir/tenant.json"
  [[ "$(json_value "$tenant_dir/tenant.json" expiryMode)" == "powershell-sleep-fallback" ]] || fail 'fallback tenant.json expiryMode mismatch'
  [[ "$(cat "$tenant_dir/expiry.mode")" == "powershell-sleep-fallback" ]] || fail 'fallback expiry.mode mismatch'
  require_file "$tenant_dir/expiry.pid"
}

validate_reconcile_disabled() {
  log 'running disabled tenant reconcile scenario'
  run_install_ps1 \
    home-reconcile \
    /test/mockbin \
    -e INSTALL_MODE=tenant \
    -e TENANT_NONINTERACTIVE=1 \
    -e TENANT_PROXY_MODE=custom \
    -e TENANT_DURATION_LABEL=1h \
    -e TENANT_BASE_URL=https://tenant.reconcile.example/v1 \
    -e TENANT_API_KEY=tenant-reconcile-key \
    -e TENANT_MODEL=gpt-5.4 \
    -e TENANT_FEISHU_APP_ID=feishu-app \
    -e TENANT_FEISHU_APP_SECRET=feishu-secret \
    -e MOCK_DOCKER_STATE_DIR=/test/state/reconcile-docker \
    -e MOCK_SCHTASKS_STATE_DIR=/test/state/reconcile-schtasks

  local tenant_dir tenant_json tenant_name container_name data_dir data_dir_host compose_env
  tenant_dir="$(latest_subdir "$WORK_DIR/home-reconcile/.openclaw/tenant-state")"
  tenant_json="$tenant_dir/tenant.json"
  tenant_name="$(basename "$tenant_dir")"
  require_file "$tenant_json"
  container_name="$(json_value "$tenant_json" container)"
  data_dir="$(json_value "$tenant_json" dataDir)"
  data_dir_host="$(to_host_path "$data_dir")"
  cat > "$data_dir_host/openclaw.json" <<'JSON'
{
  "models": {
    "providers": {
      "default": {
        "baseUrl": "https://tenant.reconcile.example/v1",
        "apiKey": "tenant-reconcile-key",
        "models": [
          {
            "id": "gpt-5.4"
          }
        ]
      }
    }
  },
  "channels": {
    "feishu": {
      "appId": "feishu-app",
      "appSecret": "feishu-secret"
    }
  }
}
JSON

  run_tenant_expire "$(to_container_path "$tenant_dir")" "$container_name"
  require_file "$tenant_dir/disabled-at"
  require_file "$data_dir_host/TENANT_DISABLED"

  run_tenant_reconcile home-reconcile /test/state/reconcile-docker "$tenant_name"

  compose_env="$WORK_DIR/state/reconcile-docker/$container_name/compose.env"
  require_file "$compose_env"
  assert_contains "$compose_env" 'TENANT_PROXY_MODE=custom'
  assert_contains "$compose_env" 'TENANT_BASE_URL=https://tenant.reconcile.example/v1'
  assert_contains "$compose_env" 'TENANT_API_KEY=tenant-reconcile-key'
  assert_contains "$compose_env" 'TENANT_MODEL=gpt-5.4'
  [[ "$(json_value "$tenant_json" expiryMode)" == "windows-schtasks" ]] || fail 'reconcile tenant.json expiryMode mismatch'
  json_value "$tenant_json" vncPassword >/dev/null
}

validate_remote_bootstrap() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    log 'skipping remote bootstrap validation because docker --network host is only exercised here on Linux'
    return
  fi

  log 'running remote install.ps1 bootstrap scenario'
  build_archive
  start_archive_server
  run_remote_bootstrap 'home-remote' "http://127.0.0.1:${HTTP_PORT}/openclaw-installer-main.zip"

  local tenant_dir bootstrap_bundle
  tenant_dir="$(latest_subdir "$WORK_DIR/home-remote/.openclaw/tenant-state")"
  require_file "$tenant_dir/tenant.json"
  [[ "$(json_value "$tenant_dir/tenant.json" modelMode)" == "custom" ]] || fail 'remote bootstrap tenant.json modelMode mismatch'
  bootstrap_bundle="$(find "$WORK_DIR/home-remote/.openclaw/installer-bundles" -path '*/install-native.ps1' | sort | tail -n 1)"
  [[ -n "$bootstrap_bundle" ]] || fail 'remote bootstrap should keep a persistent installer bundle under HOME'
}

main() {
  need_bin docker
  need_bin python3
  setup_mocks
  validate_custom_schtasks
  validate_proxy_schtasks_and_expire
  validate_fallback_scheduler
  validate_reconcile_disabled
  validate_remote_bootstrap
  log 'all validations passed'
}

main "$@"

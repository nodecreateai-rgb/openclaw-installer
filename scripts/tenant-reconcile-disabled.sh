#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
    return 0
  fi
  return 1
}

tenant_name="${1:-}"
if [[ -z "$tenant_name" ]]; then
  echo "usage: $0 <tenant-name>" >&2
  exit 1
fi

tenant_state_root="${DOPE_TENANT_STATE_ROOT:-${OPENCLAW_TENANT_STATE_ROOT:-$HOME/.openclaw/tenant-state}}"
state_dir="$tenant_state_root/$tenant_name"
tenant_json="$state_dir/tenant.json"
if [[ ! -f "$tenant_json" ]]; then
  echo "tenant state missing: $tenant_json" >&2
  exit 1
fi

mapfile -t TENANT_FIELDS < <(python3 - "$tenant_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
print(payload.get('container', ''))
print(payload.get('dataDir', ''))
print(payload.get('gatewayPort', ''))
print(payload.get('vncPort', ''))
print(payload.get('modelMode', 'custom'))
print(payload.get('vncPassword', ''))
PY
)

container_name="${TENANT_FIELDS[0]}"
tenant_data_dir="${TENANT_FIELDS[1]}"
gateway_port="${TENANT_FIELDS[2]}"
vnc_port="${TENANT_FIELDS[3]}"
model_mode="${TENANT_FIELDS[4]}"
vnc_password="${TENANT_FIELDS[5]}"

if [[ -z "$container_name" || -z "$tenant_data_dir" || -z "$gateway_port" || -z "$vnc_port" ]]; then
  echo "tenant.json missing required fields: $tenant_json" >&2
  exit 1
fi

if [[ ! -f "$tenant_data_dir/TENANT_DISABLED" ]]; then
  echo "tenant is not disabled; this helper only reconciles disabled tenants" >&2
  exit 1
fi

if [[ -z "$vnc_password" ]]; then
  vnc_password="$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(8)))
PY
)"
fi

expiry_mode=""
expiry_unit=""
if [[ -f "$state_dir/expiry.mode" ]]; then
  expiry_mode="$(cat "$state_dir/expiry.mode")"
fi
if [[ -f "$state_dir/expiry.unit" ]]; then
  expiry_unit="$(cat "$state_dir/expiry.unit")"
fi

python3 - "$tenant_json" "$vnc_password" "$expiry_mode" "$expiry_unit" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload['vncPassword'] = sys.argv[2]
if sys.argv[3]:
    payload['expiryMode'] = sys.argv[3]
if sys.argv[4]:
    payload['expiryUnit'] = sys.argv[4]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
PY

openclaw_json="$tenant_data_dir/openclaw.json"
if [[ ! -f "$openclaw_json" ]]; then
  echo "tenant config missing: $openclaw_json" >&2
  exit 1
fi

mapfile -t MODEL_FIELDS < <(python3 - "$openclaw_json" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
providers = (((cfg.get('models') or {}).get('providers')) or {})
provider = next(iter(providers.values()), {}) if isinstance(providers, dict) else {}
models = provider.get('models') or []
model = ''
if isinstance(models, list) and models:
    model = (models[0] or {}).get('id', '')
channels = (cfg.get('channels') or {}).get('feishu') or {}
print(provider.get('baseUrl', ''))
print(provider.get('apiKey', ''))
print(model)
print(channels.get('appId', ''))
print(channels.get('appSecret', ''))
PY
)

tenant_base_url="${MODEL_FIELDS[0]}"
tenant_api_key="${MODEL_FIELDS[1]}"
tenant_model="${MODEL_FIELDS[2]}"
tenant_feishu_app_id="${MODEL_FIELDS[3]}"
tenant_feishu_app_secret="${MODEL_FIELDS[4]}"

tenant_allowed_origins_json="$(python3 - "$gateway_port" <<'PY'
import json
import sys

gateway_port = int(sys.argv[1])
print(json.dumps([
    f'http://localhost:{gateway_port}',
    f'http://127.0.0.1:{gateway_port}',
    'http://localhost:18789',
    'http://127.0.0.1:18789',
], ensure_ascii=False))
PY
)"

export TENANT_CONTAINER_NAME="$container_name"
export TENANT_GATEWAY_PORT="$gateway_port"
export TENANT_VNC_PORT="$vnc_port"
export TENANT_DATA_DIR="$tenant_data_dir"
export TENANT_BASE_URL="$tenant_base_url"
export TENANT_API_KEY="$tenant_api_key"
export TENANT_MODEL="$tenant_model"
export TENANT_FEISHU_APP_ID="$tenant_feishu_app_id"
export TENANT_FEISHU_APP_SECRET="$tenant_feishu_app_secret"
export TENANT_VNC_PASSWORD="$vnc_password"
export TENANT_PROXY_MODE="$model_mode"
export OPENCLAW_GATEWAY_BIND="lan"
export OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON="$tenant_allowed_origins_json"
export OPENCLAW_GATEWAY_PORT="18789"

compose_cmd="$(docker_compose_cmd)" || {
  echo "docker compose not available" >&2
  exit 1
}
$compose_cmd -p "$tenant_name" -f "$ROOT_DIR/tenant-mode/docker-compose.yml" up -d --build --force-recreate

echo "reconciled disabled tenant: $tenant_name"
echo "container: $container_name"
echo "gateway port: $gateway_port"
echo "vnc port: $vnc_port"
echo "vnc password: $vnc_password"

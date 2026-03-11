#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/root/.openclaw/openclaw.json}"
OPENCLAW_NPM_PACKAGE="${OPENCLAW_NPM_PACKAGE:-openclaw@latest}"

ensure_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
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

bootstrap_config_if_missing() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
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
      "workspace": "/root/.openclaw",
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
      "token": "openclaw-clone-local-token"
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
    echo "created default config: $CONFIG_PATH"
  fi
}

main() {
  ensure_bin npm
  ensure_bin python3
  install_openclaw
  bootstrap_config_if_missing
  echo "configuring OpenClaw model/provider settings..."
  openclaw-configure
}

main "$@"

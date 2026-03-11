#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"

TENANT_HOME=/root/.openclaw
INSTALL_MARKER="$TENANT_HOME/.tenant-installed"
DISABLE_FLAG="$TENANT_HOME/TENANT_DISABLED"
READY_FLAG=/tmp/tenant-ready

log() {
  printf '[tenant-entrypoint] %s\n' "$*"
}

start_xvfb() {
  if pgrep -x Xvfb >/dev/null 2>&1; then
    return 0
  fi
  Xvfb "$DISPLAY" -screen 0 "${SCREEN_WIDTH:-1920}x${SCREEN_HEIGHT:-1080}x24" >/tmp/xvfb.log 2>&1 &
}

start_fluxbox() {
  if pgrep -x fluxbox >/dev/null 2>&1; then
    return 0
  fi
  fluxbox >/tmp/fluxbox.log 2>&1 &
}

start_x11vnc() {
  local password_file="$TENANT_HOME/.x11vnc.pass"
  if pgrep -x x11vnc >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${TENANT_VNC_PASSWORD:-}" ]]; then
    x11vnc -storepasswd "$TENANT_VNC_PASSWORD" "$password_file" >/tmp/x11vnc-pass.log 2>&1
    chmod 600 "$password_file" 2>/dev/null || true
    x11vnc -display "$DISPLAY" -rfbport 5900 -forever -shared -rfbauth "$password_file" >/tmp/x11vnc.log 2>&1 &
  else
    x11vnc -display "$DISPLAY" -rfbport 5900 -forever -shared -nopw >/tmp/x11vnc.log 2>&1 &
  fi
}

gateway_running() {
  pgrep -f 'openclaw gateway run' >/dev/null 2>&1 || pgrep -f 'node .*openclaw.*gateway' >/dev/null 2>&1
}

stop_gateway() {
  pkill -x openclaw-gateway >/dev/null 2>&1 || true
  pkill -x openclaw >/dev/null 2>&1 || true
  pkill -f 'openclaw gateway run' >/dev/null 2>&1 || true
  pkill -f 'node .*openclaw.*gateway' >/dev/null 2>&1 || true
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

start_gateway() {
  if [[ -f "$DISABLE_FLAG" ]] || gateway_running; then
    return 0
  fi
  log "starting OpenClaw gateway"
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'exec openclaw gateway run >/tmp/openclaw-gateway-run.log 2>&1' </dev/null >/dev/null 2>&1 &
  else
    nohup sh -c 'exec openclaw gateway run >/tmp/openclaw-gateway-run.log 2>&1' >/dev/null 2>&1 &
  fi
  wait_for_gateway 30 2 || {
    log "gateway health check did not pass yet"
    return 1
  }
}

run_installer_once() {
  if [[ -f "$INSTALL_MARKER" ]]; then
    touch "$READY_FLAG"
    return 0
  fi
  OPENCLAW_WORKSPACE="$TENANT_HOME" \
  OPENCLAW_CONFIG_PATH="$TENANT_HOME/openclaw.json" \
  BUNDLED_SKILLS_DIR=/installer/bundled-skills \
  FEISHU_PLUGIN_SPEC='@m1heng-clawd/feishu' \
  TENANT_NONINTERACTIVE=1 \
  TENANT_FEISHU_APP_ID="${TENANT_FEISHU_APP_ID:-}" \
  TENANT_FEISHU_APP_SECRET="${TENANT_FEISHU_APP_SECRET:-}" \
  /installer/install-native.sh --tenant-container
  touch "$INSTALL_MARKER"
  touch "$READY_FLAG"
}

main() {
  mkdir -p "$TENANT_HOME"
  start_xvfb
  start_fluxbox
  start_x11vnc
  run_installer_once

  if [[ -f "$DISABLE_FLAG" ]]; then
    log "tenant is disabled; keeping services stopped"
    stop_gateway
  else
    start_gateway || true
  fi

  while true; do
    start_xvfb
    start_fluxbox
    start_x11vnc
    if [[ -f "$DISABLE_FLAG" ]]; then
      stop_gateway
    else
      start_gateway || true
    fi
    sleep 5
  done
}

main "$@"

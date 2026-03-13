#!/usr/bin/env bash
# Envoy bridge lifecycle helpers

BRIDGE_PID=""

start_bridge() {
  if [[ "$SOCKET_MODE_ENABLED" != "true" ]]; then
    return 0
  fi

  local app_token_env
  app_token_env=$(get_config "envoy" "socket_mode.app_token_env" "SLACK_APP_TOKEN")
  local app_token="${!app_token_env:-}"

  if [[ -z "$app_token" ]]; then
    log "[ERROR] [envoy] $app_token_env not set — Socket Mode disabled"
    SOCKET_MODE_ENABLED="false"
    export SOCKET_MODE_ENABLED
    return 1
  fi

  local bridge_script="$BASE_DIR/bin/lib/envoy/bridge.js"
  if [[ ! -f "$bridge_script" ]]; then
    log "[ERROR] [envoy] bridge.js not found: $bridge_script"
    SOCKET_MODE_ENABLED="false"
    export SOCKET_MODE_ENABLED
    return 1
  fi

  SLACK_APP_TOKEN="$app_token" SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}" \
    KINGDOM_BASE_DIR="$BASE_DIR" \
    node "$bridge_script" &
  BRIDGE_PID=$!
  log "[SYSTEM] [envoy] Bridge started (PID: $BRIDGE_PID)"
}

stop_bridge() {
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    BRIDGE_PID=""
    log "[SYSTEM] [envoy] Bridge stopped"
  fi
}

check_bridge_health() {
  [[ "$SOCKET_MODE_ENABLED" != "true" ]] && return 0
  [[ -z "$BRIDGE_PID" ]] && { start_bridge; return; }

  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    log "[WARN] [envoy] Bridge process dead, restarting..."
    start_bridge
    return
  fi

  local health_file="$BASE_DIR/state/envoy/bridge-health"
  if [[ -f "$health_file" ]]; then
    local mtime now age
    mtime=$(get_mtime "$health_file")
    now=$(date +%s)
    age=$((now - mtime))
    if (( age > 30 )); then
      log "[WARN] [envoy] Bridge health stale (${age}s), restarting..."
      stop_bridge
      start_bridge
    fi
  fi
}

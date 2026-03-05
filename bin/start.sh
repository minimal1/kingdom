#!/usr/bin/env bash
# bin/start.sh — Kingdom system startup
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

# --- Init ---
"$BASE_DIR/bin/init-dirs.sh"

# --- Session Startup ---

start_session() {
  local name="$1"
  local script="$2"

  if tmux has-session -t "$name" 2>/dev/null; then
    log "[SYSTEM] [start] Session already running: $name"
    return 0
  fi

  tmux new-session -d -s "$name" "$script"
  log "[SYSTEM] [start] Started session: $name"
}

# Start order: chamberlain → sentinel → envoy → king → generals
start_session "chamberlain" "$BASE_DIR/bin/chamberlain.sh"
start_session "sentinel"    "$BASE_DIR/bin/sentinel.sh"
start_session "envoy"       "$BASE_DIR/bin/envoy.sh"
start_session "king"        "$BASE_DIR/bin/king.sh"

# Start generals from manifests
for manifest in "$BASE_DIR/config/generals/"*.yaml; do
  [ -f "$manifest" ] || continue
  name=$(yq eval '.name' "$manifest" 2>/dev/null || grep -m1 '^name:' "$manifest" | sed 's/^name:[[:space:]]*//' | tr -d '"'"'")
  [ -z "$name" ] || [ "$name" = "null" ] && continue

  script="$BASE_DIR/bin/generals/${name}.sh"
  if [ -f "$script" ]; then
    start_session "$name" "$script"
  else
    log "[WARN] [start] General script not found: $script"
  fi
done

# Start dashboard container (if Docker available)
if command -v docker &>/dev/null; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^kingdom-dashboard$'; then
    docker run -d --name kingdom-dashboard \
      -p 9000:9000 \
      -v "$BASE_DIR/state/dashboard.json:/data/dashboard.json:ro" \
      --restart unless-stopped \
      kingdom-dashboard 2>/dev/null \
      && log "[SYSTEM] [start] Dashboard started on port 9000" \
      || log "[WARN] [start] Dashboard container failed to start"
  else
    log "[SYSTEM] [start] Dashboard already running"
  fi
fi

log "[SYSTEM] [start] Kingdom started."
echo "Kingdom started. Use 'bin/status.sh' to check."

# --- Watchdog Loop ---

ESSENTIAL_SESSIONS=("chamberlain" "sentinel" "envoy" "king")

watchdog_loop() {
  while true; do
    for session in "${ESSENTIAL_SESSIONS[@]}"; do
      if ! tmux has-session -t "$session" 2>/dev/null; then
        log "[WATCHDOG] Restarting dead session: $session"
        tmux new-session -d -s "$session" "$BASE_DIR/bin/${session}.sh"
      fi
    done
    sleep 60
  done
}

# Run watchdog in foreground (systemd or nohup keeps this alive)
watchdog_loop

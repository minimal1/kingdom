#!/usr/bin/env bash
# bin/stop.sh — Kingdom system shutdown
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

# Stop order: generals → king → envoy → sentinel → chamberlain (reverse of start)

CORE_SESSIONS=("king" "envoy" "sentinel" "chamberlain")

# Collect general names
GENERAL_SESSIONS=()
for manifest in "$BASE_DIR/config/generals/"*.yaml; do
  [ -f "$manifest" ] || continue
  local name=""
  name=$(yq eval '.name' "$manifest" 2>/dev/null || grep -m1 '^name:' "$manifest" | sed 's/^name:[[:space:]]*//' | tr -d '"'"'")
  [ -z "$name" ] || [ "$name" = "null" ] && continue
  GENERAL_SESSIONS+=("$name")
done

# Kill all soldier sessions first
if [ -f "$BASE_DIR/state/sessions.json" ]; then
  local count
  count=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
  for ((i=0; i<count; i++)); do
    local soldier_id
    soldier_id=$(jq -r ".[$i].id" "$BASE_DIR/state/sessions.json" 2>/dev/null)
    if [ -n "$soldier_id" ] && tmux has-session -t "$soldier_id" 2>/dev/null; then
      tmux kill-session -t "$soldier_id"
      log "[SYSTEM] [stop] Killed soldier: $soldier_id"
    fi
  done
fi

# Stop generals
for name in "${GENERAL_SESSIONS[@]}"; do
  if tmux has-session -t "$name" 2>/dev/null; then
    tmux send-keys -t "$name" C-c
    log "[SYSTEM] [stop] Stopping general: $name"
  fi
done

# Stop core sessions
for name in "${CORE_SESSIONS[@]}"; do
  if tmux has-session -t "$name" 2>/dev/null; then
    tmux send-keys -t "$name" C-c
    log "[SYSTEM] [stop] Stopping: $name"
  fi
done

# Wait for graceful shutdown
sleep 5

# Force kill remaining
ALL_SESSIONS=("${GENERAL_SESSIONS[@]}" "${CORE_SESSIONS[@]}")
for name in "${ALL_SESSIONS[@]}"; do
  if tmux has-session -t "$name" 2>/dev/null; then
    tmux kill-session -t "$name"
    log "[SYSTEM] [stop] Force killed: $name"
  fi
done

log "[SYSTEM] [stop] Kingdom stopped."
echo "Kingdom stopped."

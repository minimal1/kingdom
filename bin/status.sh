#!/usr/bin/env bash
# bin/status.sh — Kingdom system status
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

echo ""
echo "Kingdom Status"
echo "═══════════════════════════════════════════"

# --- Session Status ---

check_session() {
  local name="$1"
  local hb_file="$BASE_DIR/state/${name}/heartbeat"

  if tmux has-session -t "$name" 2>/dev/null; then
    local hb_age="N/A"
    if [ -f "$hb_file" ]; then
      local mtime
      mtime=$(get_mtime "$hb_file" 2>/dev/null || echo 0)
      local now
      now=$(date +%s)
      hb_age="$((now - mtime))s"
    fi
    printf "  [OK]   %-16s heartbeat: %s\n" "$name" "$hb_age"
  else
    printf "  [DOWN] %-16s\n" "$name"
  fi
}

echo ""
echo "Core Sessions:"
check_session "chamberlain"
check_session "sentinel"
check_session "envoy"
check_session "king"

echo ""
echo "Generals:"
for manifest in "$BASE_DIR/config/generals/"*.yaml; do
  [ -f "$manifest" ] || continue
  name=$(yq eval '.name' "$manifest" 2>/dev/null || grep -m1 '^name:' "$manifest" | sed 's/^name:[[:space:]]*//' | tr -d '"'"'")
  [ -z "$name" ] || [ "$name" = "null" ] && continue
  check_session "$name"
done

# --- Active Soldiers ---

echo ""
echo "Soldiers:"
soldier_count=0
if [ -f "$BASE_DIR/state/sessions.json" ]; then
  soldier_count=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
fi
echo "  Active: $soldier_count"

# --- Resources ---

echo ""
echo "Resources:"
if [ -f "$BASE_DIR/state/resources.json" ]; then
  health="" ; cpu="" ; mem="" ; disk=""
  health=$(jq -r '.health // "unknown"' "$BASE_DIR/state/resources.json")
  cpu=$(jq -r '.system.cpu_percent // "?"' "$BASE_DIR/state/resources.json")
  mem=$(jq -r '.system.memory_percent // "?"' "$BASE_DIR/state/resources.json")
  disk=$(jq -r '.system.disk_percent // "?"' "$BASE_DIR/state/resources.json")
  printf "  Health: %s  CPU: %s%%  MEM: %s%%  DISK: %s%%\n" "$health" "$cpu" "$mem" "$disk"
else
  echo "  resources.json not found"
fi

echo ""
echo "═══════════════════════════════════════════"

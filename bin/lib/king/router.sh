#!/usr/bin/env bash
# King Router — manifest loading, routing table, event sorting
# Uses JSON files instead of associative arrays for bash 3.2 compatibility

GENERALS_CONFIG_DIR="$BASE_DIR/config/generals"

# Runtime state files (created in /tmp per session)
ROUTING_TABLE_FILE=""
SCHEDULES_FILE=""
DEFAULT_REPO_FILE=""
ROUTING_TABLE_COUNT=0

# Load general manifests and build routing table
load_general_manifests() {
  ROUTING_TABLE_FILE=$(mktemp)
  SCHEDULES_FILE=$(mktemp)
  DEFAULT_REPO_FILE=$(mktemp)
  echo '{}' > "$ROUTING_TABLE_FILE"
  echo -n > "$SCHEDULES_FILE"
  echo '{}' > "$DEFAULT_REPO_FILE"
  ROUTING_TABLE_COUNT=0

  for manifest in "$GENERALS_CONFIG_DIR"/*.yaml; do
    [ -f "$manifest" ] || continue

    local name
    name=$(yq eval '.name' "$manifest" 2>/dev/null)
    [ -z "$name" ] && continue

    # default_repo → lookup table
    local default_repo
    default_repo=$(yq eval '.default_repo // ""' "$manifest" 2>/dev/null)
    if [ -n "$default_repo" ]; then
      local updated_repo
      updated_repo=$(jq --arg gn "$name" --arg r "$default_repo" '.[$gn] = $r' "$DEFAULT_REPO_FILE")
      echo "$updated_repo" > "$DEFAULT_REPO_FILE"
    fi

    # Subscribe events → routing table
    local subscribes
    subscribes=$(yq eval '.subscribes[]' "$manifest" 2>/dev/null)
    local sub_count=0

    while IFS= read -r event_type; do
      [ -z "$event_type" ] && continue

      # Check if already claimed
      local existing
      existing=$(jq -r --arg et "$event_type" '.[$et] // empty' "$ROUTING_TABLE_FILE")
      if [ -n "$existing" ]; then
        log "[WARN] [king] Event type '$event_type' already claimed by $existing, ignoring $name"
        continue
      fi

      # Add to routing table
      local updated
      updated=$(jq --arg et "$event_type" --arg gn "$name" '.[$et] = $gn' "$ROUTING_TABLE_FILE")
      echo "$updated" > "$ROUTING_TABLE_FILE"
      ROUTING_TABLE_COUNT=$((ROUTING_TABLE_COUNT + 1))
      sub_count=$((sub_count + 1))
    done <<< "$subscribes"

    # Schedule entries
    local schedule_count
    schedule_count=$(yq eval '.schedules | length' "$manifest" 2>/dev/null)
    [ -z "$schedule_count" ] && schedule_count=0
    for ((i=0; i<schedule_count; i++)); do
      local sched_json
      sched_json=$(yq eval -o=json ".schedules[$i]" "$manifest" 2>/dev/null | jq -c .)
      if [ -n "$sched_json" ] && [ "$sched_json" != "null" ]; then
        echo "${name}|${sched_json}" >> "$SCHEDULES_FILE"
      fi
    done

    log "[SYSTEM] [king] Loaded general: $name ($sub_count event types, $schedule_count schedules)"
  done

  log "[SYSTEM] [king] Routing table: $ROUTING_TABLE_COUNT event types mapped"
}

# Find general for a given event type
find_general() {
  local event_type="$1"

  local general
  general=$(jq -r --arg et "$event_type" '.[$et] // empty' "$ROUTING_TABLE_FILE" 2>/dev/null)

  if [ -n "$general" ]; then
    echo "$general"
    return 0
  fi

  log "[WARN] [king] No general found for event type: $event_type"
  return 1
}

# Get default repo for a general (from manifest default_repo field)
get_default_repo() {
  local general="$1"
  jq -r --arg gn "$general" '.[$gn] // empty' "$DEFAULT_REPO_FILE" 2>/dev/null
}

general_supports_engine() {
  local general="$1"
  local engine="$2"
  local manifest="$GENERALS_CONFIG_DIR/${general}.yaml"
  [ -f "$manifest" ] || return 1

  local supported
  supported=$(yq eval '.supported_engines[]' "$manifest" 2>/dev/null || true)
  if [ -z "$supported" ]; then
    [ "$engine" = "claude" ]
    return
  fi

  echo "$supported" | grep -qx "$engine"
}

# Get number of mapped event types
get_routing_table_count() {
  echo "$ROUTING_TABLE_COUNT"
}

# Read schedules file as array
get_schedules() {
  cat "$SCHEDULES_FILE" 2>/dev/null
}

# Collect events from directory and sort by priority (high → normal → low)
collect_and_sort_events() {
  local dir="$1"

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    local p
    p=$(jq -r '.priority' "$f" 2>/dev/null)
    local order=2
    case "$p" in
      high) order=1 ;;
      normal) order=2 ;;
      low) order=3 ;;
    esac
    echo "$order $f"
  done | sort -n | cut -d' ' -f2
}

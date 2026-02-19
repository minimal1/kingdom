#!/usr/bin/env bash
# King Resource Check — health level reading and task admission control

RESOURCES_FILE="$BASE_DIR/state/resources.json"

# Read health level from resources.json (maintained by chamberlain)
# Stale detection: if timestamp > 120s old, assume chamberlain crash → return orange
get_resource_health() {
  local data
  data=$(cat "$RESOURCES_FILE" 2>/dev/null || echo '{}')
  local health
  health=$(echo "$data" | jq -r '.health // "green"')
  local ts
  ts=$(echo "$data" | jq -r '.timestamp // empty')

  # No timestamp → initial state → green
  [ -z "$ts" ] && echo "green" && return 0

  # Stale check: >120s since last update → orange
  local ts_epoch now elapsed
  if is_macos; then
    ts_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)
  else
    ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
  fi
  now=$(date +%s)
  elapsed=$((now - ts_epoch))

  if (( elapsed > 120 )); then
    log "[WARN] [king] resources.json stale: ${elapsed}s old (threshold: 120s)"
    echo "orange"
    return 0
  fi

  echo "$health"
}

# Read token status from resources.json
get_token_status() {
  local data
  data=$(cat "$RESOURCES_FILE" 2>/dev/null || echo '{}')
  echo "$data" | jq -r '.tokens.status // "ok"'
}

# Decide if a task can be accepted based on health + priority + token status
can_accept_task() {
  local health="$1"
  local priority="$2"
  local token_status="$3"

  # Token status critical: high priority only
  if [[ "$token_status" == "critical" ]]; then
    [ "$priority" = "high" ] && return 0
    return 1
  fi

  # Token status warning: high OR health=green
  if [[ "$token_status" == "warning" ]]; then
    [[ "$priority" == "high" || "$health" == "green" ]] && return 0
    return 1
  fi

  # Token status ok/unknown: use existing health-based logic
  case "$health" in
    green)  return 0 ;;
    yellow) [ "$priority" = "high" ] && return 0
            return 1 ;;
    orange) return 1 ;;
    red)    return 1 ;;
  esac
}

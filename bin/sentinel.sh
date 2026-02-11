#!/usr/bin/env bash
# Kingdom Sentinel - Main Polling Loop
# 외부 서비스(GitHub, Jira)를 폴링하여 이벤트를 감지한다.

set -uo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/sentinel/watcher-common.sh"

# Graceful Shutdown
RUNNING=true
trap 'RUNNING=false; log "[SYSTEM] [sentinel] Shutting down..."; exit 0' SIGTERM SIGINT

# Watcher 동적 로딩: sentinel.yaml의 polling 키에서 스캔
WATCHERS=()
for key in $(yq eval '.polling | keys | .[]' "$BASE_DIR/config/sentinel.yaml" 2>/dev/null); do
  if [ -f "$BASE_DIR/bin/lib/sentinel/${key}-watcher.sh" ]; then
    WATCHERS+=("$key")
  else
    log "[WARN] [sentinel] Unknown watcher in config: $key (no ${key}-watcher.sh)"
  fi
done

if [ ${#WATCHERS[@]} -eq 0 ]; then
  log "[WARN] [sentinel] No watchers configured in sentinel.yaml"
fi

for watcher in "${WATCHERS[@]}"; do
  source "$BASE_DIR/bin/lib/sentinel/${watcher}-watcher.sh"
done

declare -A LAST_POLL

log "[SYSTEM] [sentinel] Started. Watchers: ${WATCHERS[*]}"

while $RUNNING; do
  update_heartbeat "sentinel"

  for watcher in "${WATCHERS[@]}"; do
    interval=$(get_interval "$watcher")
    elapsed=$(( $(date +%s) - ${LAST_POLL[$watcher]:-0} ))

    if [[ "$elapsed" -ge "$interval" ]]; then
      log "[EVENT] [sentinel] Polling: $watcher"

      # 1. fetch
      raw=$("${watcher}_fetch" 2>/dev/null)
      if [[ $? -ne 0 ]]; then
        log "[EVENT] [sentinel] ERROR: ${watcher}_fetch failed"
        LAST_POLL[$watcher]=$(date +%s)
        continue
      fi

      # 2. parse
      events=$("${watcher}_parse" "$raw" 2>/dev/null)

      # 3. emit (중복 제거)
      echo "$events" | jq -c '.[]' 2>/dev/null | while read -r event; do
        event_id=$(echo "$event" | jq -r '.id')
        if ! is_duplicate "$event_id"; then
          sentinel_emit_event "$event"
        fi
      done

      LAST_POLL[$watcher]=$(date +%s)
    fi
  done

  sleep 5
done

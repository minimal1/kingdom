#!/usr/bin/env bash
# bin/dashboard-collect.sh — Kingdom 대시보드 데이터 수집기
# state/, queue/, config/generals/, logs/ 데이터를 state/dashboard.json으로 합침
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

OUTPUT="$BASE_DIR/state/dashboard.json"
TMP_OUTPUT="${OUTPUT}.tmp"
NOW=$(date +%s)

# --- System ---

collect_system() {
  local res="$BASE_DIR/state/resources.json"
  if [ -f "$res" ]; then
    local health cpu mem disk load_avg
    health=$(jq -r '.health // "unknown"' "$res" 2>/dev/null) || health="unknown"
    cpu=$(jq -r '.system.cpu_percent // 0' "$res" 2>/dev/null) || cpu=0
    mem=$(jq -r '.system.memory_percent // 0' "$res" 2>/dev/null) || mem=0
    disk=$(jq -r '.system.disk_percent // 0' "$res" 2>/dev/null) || disk=0
    load_avg=$(jq -r '(.system.load_average // [0,0,0]) | join(",")' "$res" 2>/dev/null) || load_avg="0,0,0"
    printf '{"health":"%s","cpu_percent":%s,"memory_percent":%s,"disk_percent":%s,"load_avg":"%s"}' \
      "$health" "$cpu" "$mem" "$disk" "$load_avg"
  else
    echo '{"health":"unknown","cpu_percent":0,"memory_percent":0,"disk_percent":0,"load_avg":"0,0,0"}'
  fi
}

# --- Roles ---

check_role() {
  local name="$1"
  local hb_file="$BASE_DIR/state/${name}/heartbeat"
  local alive="false"
  local hb_age=-1

  if tmux has-session -t "$name" 2>/dev/null; then
    alive="true"
  fi

  if [ -f "$hb_file" ]; then
    local mtime
    mtime=$(get_mtime "$hb_file" 2>/dev/null || echo 0)
    hb_age=$((NOW - mtime))
  fi

  printf '"%s":{"alive":%s,"heartbeat_age_s":%d}' "$name" "$alive" "$hb_age"
}

collect_roles() {
  local parts=""
  for role in king sentinel envoy chamberlain; do
    if [ -n "$parts" ]; then
      parts="${parts},"
    fi
    parts="${parts}$(check_role "$role")"
  done
  printf '{%s}' "$parts"
}

# --- Generals ---

collect_generals() {
  local first="true"
  printf '['
  for manifest in "$BASE_DIR/config/generals/"*.yaml; do
    [ -f "$manifest" ] || continue
    local name desc gtype
    name=$(yq eval '.name // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$name" ] || [ "$name" = "null" ] && continue
    desc=$(yq eval '.description // ""' "$manifest" 2>/dev/null || echo "")
    # type: event if subscribes non-empty, schedule if schedules non-empty, else manual
    local has_subs has_scheds
    has_subs=$(yq eval '.subscribes | length' "$manifest" 2>/dev/null || echo 0)
    has_scheds=$(yq eval '.schedules | length' "$manifest" 2>/dev/null || echo 0)
    if [ "$has_subs" -gt 0 ] 2>/dev/null; then
      gtype="event"
    elif [ "$has_scheds" -gt 0 ] 2>/dev/null; then
      gtype="schedule"
    else
      gtype="manual"
    fi
    if [ "$first" = "true" ]; then
      first="false"
    else
      printf ','
    fi
    # JSON-escape description
    local safe_desc
    safe_desc=$(printf '%s' "$desc" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$desc")
    printf '{"name":"%s","description":%s,"type":"%s"}' "$name" "$safe_desc" "$gtype"
  done
  printf ']'
}

# --- Queue ---

count_files() {
  local dir="$1"
  if [ -d "$dir" ]; then
    local c
    c=$(find "$dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "$c"
  else
    echo "0"
  fi
}

collect_queue() {
  local ep tp ta mp mf
  ep=$(count_files "$BASE_DIR/queue/events/pending")
  tp=$(count_files "$BASE_DIR/queue/tasks/pending")
  ta=$(count_files "$BASE_DIR/queue/tasks/in_progress")
  mp=$(count_files "$BASE_DIR/queue/messages/pending")
  mf=$(count_files "$BASE_DIR/queue/messages/failed")
  printf '{"events_pending":%d,"tasks_pending":%d,"tasks_active":%d,"messages_pending":%d,"messages_failed":%d}' \
    "$ep" "$tp" "$ta" "$mp" "$mf"
}

# --- Soldiers ---

collect_soldiers() {
  local sessions_file="$BASE_DIR/state/sessions.json"
  if [ -f "$sessions_file" ]; then
    # sessions.json의 각 엔트리에 elapsed_s 추가
    jq --argjson now "$NOW" '
      [ .[] | . + {
        elapsed_s: ($now - ((.started_at // "1970-01-01T00:00:00Z") | fromdateiso8601 // 0))
      }]
    ' "$sessions_file" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

# --- Recent Events ---

collect_recent_events() {
  local logfile="$BASE_DIR/logs/events.log"
  if [ -f "$logfile" ]; then
    tail -n 10 "$logfile" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

# --- Assemble ---

collected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
system_json=$(collect_system)
roles_json=$(collect_roles)
generals_json=$(collect_generals)
queue_json=$(collect_queue)
soldiers_json=$(collect_soldiers)
events_json=$(collect_recent_events)

jq -n \
  --arg ts "$collected_at" \
  --argjson sys "$system_json" \
  --argjson roles "$roles_json" \
  --argjson gens "$generals_json" \
  --argjson q "$queue_json" \
  --argjson sol "$soldiers_json" \
  --argjson evt "$events_json" \
  '{
    collected_at: $ts,
    system: $sys,
    roles: $roles,
    generals: $gens,
    queue: $q,
    soldiers: $sol,
    recent_events: $evt
  }' > "$TMP_OUTPUT"

mv "$TMP_OUTPUT" "$OUTPUT"

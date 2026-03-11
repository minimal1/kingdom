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
  if [ ! -f "$sessions_file" ]; then
    echo '[]'
    return
  fi

  # in_progress 태스크에서 task_id → {general, task_type, payload} 매핑 구축
  local task_meta='{}'
  for task_file in "$BASE_DIR/queue/tasks/in_progress/"*.json; do
    [ -f "$task_file" ] || continue
    local tid
    tid=$(jq -r '.id // ""' "$task_file" 2>/dev/null) || continue
    if [ -n "$tid" ]; then
      task_meta=$(echo "$task_meta" | jq --arg k "$tid" --argjson v "$(jq '{general: .target_general, task_type: .type, payload: .payload}' "$task_file" 2>/dev/null)" '. + {($k): $v}')
    fi
  done

  # sessions.json + task 메타데이터 병합
  jq --argjson tmap "$task_meta" '
    [ .[] | . + {
      general: ($tmap[.task_id].general // null),
      task_type: ($tmap[.task_id].task_type // null),
      payload: ($tmap[.task_id].payload // null)
    }]
  ' "$sessions_file" 2>/dev/null || echo '[]'
}

# --- Sentinel detail ---

collect_sentinel() {
  local cfg="$BASE_DIR/config/sentinel.yaml"
  if [ ! -f "$cfg" ]; then
    echo '{"watchers":[]}'
    return
  fi

  local first="true"
  printf '{"watchers":['

  # polling 하위 키 = watcher 이름
  local names
  names=$(yq eval '.polling | keys | .[]' "$cfg" 2>/dev/null) || true
  for name in $names; do
    local interval
    interval=$(yq eval ".polling.${name}.interval_seconds // 0" "$cfg" 2>/dev/null) || interval=0

    # state 파일에서 mtime → last_check_at
    local last_check=""
    for sf in "$BASE_DIR/state/sentinel/${name}"*.json; do
      if [ -f "$sf" ]; then
        local mt
        mt=$(get_mtime "$sf" 2>/dev/null || echo 0)
        if [ "$mt" -gt 0 ] 2>/dev/null; then
          last_check=$(date -u -r "$mt" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || true
        fi
        break
      fi
    done

    if [ "$first" = "true" ]; then
      first="false"
    else
      printf ','
    fi
    printf '{"name":"%s","interval_seconds":%d,"last_check_at":"%s"}' \
      "$name" "$interval" "$last_check"
  done

  printf ']}'
}

# --- Envoy detail ---

collect_envoy() {
  local threads=0 awaiting=0 convos=0
  local state_dir="$BASE_DIR/state/envoy"
  local ip_dir="$BASE_DIR/queue/tasks/in_progress"

  # active_threads: thread-mappings 중 in_progress 태스크가 있는 것만 카운트
  if [ -f "$state_dir/thread-mappings.json" ] && [ -d "$ip_dir" ]; then
    threads=$(
      jq -r 'keys[]' "$state_dir/thread-mappings.json" 2>/dev/null | while read -r tid; do
        if [ -f "$ip_dir/${tid}.json" ]; then
          echo "1"
        fi
      done | wc -l | tr -d ' '
    )
    threads=${threads:-0}
  fi
  if [ -f "$state_dir/awaiting-responses.json" ]; then
    awaiting=$(jq 'length' "$state_dir/awaiting-responses.json" 2>/dev/null) || awaiting=0
  fi
  if [ -f "$state_dir/conversation-threads.json" ]; then
    convos=$(jq 'length' "$state_dir/conversation-threads.json" 2>/dev/null) || convos=0
  fi

  printf '{"active_threads":%d,"awaiting_responses":%d,"conversations":%d}' \
    "$threads" "$awaiting" "$convos"
}

# --- Task History ---

collect_task_history() {
  local completed_dir="$BASE_DIR/queue/tasks/completed"
  local results_dir="$BASE_DIR/state/results"

  if [ ! -d "$completed_dir" ]; then
    echo '[]'
    return
  fi

  # 파일명(task_id) 역순으로 최근 20개 completed task 파일 수집
  local sorted
  sorted=$(find "$completed_dir" -maxdepth 1 -name '*.json' -type f -print 2>/dev/null | sort -r | head -20)
  if [ -z "$sorted" ]; then
    echo '[]'
    return
  fi

  local result
  result=$(echo "$sorted" | while read -r f; do
    [ -f "$f" ] || continue
    local mt
    mt=$(get_mtime "$f" 2>/dev/null || echo 0)
    local ts=""
    if [ "$mt" -gt 0 ] 2>/dev/null; then
      ts=$(date -u -r "$mt" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || true
    fi

    # task 파일에서 기본 정보 추출
    local task_id task_type target_general
    task_id=$(jq -r '.id // ""' "$f" 2>/dev/null) || task_id=""
    task_type=$(jq -r '.type // ""' "$f" 2>/dev/null) || task_type=""
    target_general=$(jq -r '.target_general // ""' "$f" 2>/dev/null) || target_general=""

    # result 파일 병합
    local result_file="$results_dir/${task_id}.json"
    local status="unknown" summary="" error=""
    if [ -n "$task_id" ] && [ -f "$result_file" ]; then
      status=$(jq -r '.status // "unknown"' "$result_file" 2>/dev/null) || status="unknown"
      summary=$(jq -r '.summary // ""' "$result_file" 2>/dev/null) || summary=""
      error=$(jq -r '.error // ""' "$result_file" 2>/dev/null) || error=""
    fi

    # jq로 안전한 JSON 생성
    jq -nc \
      --arg id "$task_id" \
      --arg type "$task_type" \
      --arg general "$target_general" \
      --arg completed_at "$ts" \
      --arg status "$status" \
      --arg summary "$summary" \
      --arg error "$error" \
      '{id:$id, type:$type, general:$general, completed_at:$completed_at, status:$status, summary:$summary, error:$error}'
  done | jq -sc '.' 2>/dev/null)

  if [ -z "$result" ] || [ "$result" = "null" ]; then
    echo '[]'
  else
    echo "$result"
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
sentinel_json=$(collect_sentinel)
envoy_json=$(collect_envoy)
task_history_json=$(collect_task_history)

jq -n \
  --arg ts "$collected_at" \
  --argjson sys "$system_json" \
  --argjson roles "$roles_json" \
  --argjson gens "$generals_json" \
  --argjson q "$queue_json" \
  --argjson sol "$soldiers_json" \
  --argjson evt "$events_json" \
  --argjson sen "$sentinel_json" \
  --argjson env "$envoy_json" \
  --argjson hist "$task_history_json" \
  '{
    collected_at: $ts,
    system: $sys,
    roles: $roles,
    generals: $gens,
    queue: $q,
    soldiers: $sol,
    recent_events: $evt,
    sentinel: $sen,
    envoy: $env,
    task_history: $hist
  }' > "$TMP_OUTPUT"

mv "$TMP_OUTPUT" "$OUTPUT"

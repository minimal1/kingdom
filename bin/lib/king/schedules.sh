#!/usr/bin/env bash
# King schedule helpers

schedule_key() {
  local general="$1"
  local name="$2"
  printf '%s:%s' "$general" "$name"
}

cron_matches_at_epoch() {
  local expr="$1"
  local epoch="$2"
  local min hour dom mon dow

  read -r min hour dom mon dow <<< "$expr"

  local now_min now_hour now_dom now_mon now_dow
  now_min=$(date -r "$epoch" +%-M 2>/dev/null || date -d "@$epoch" +%-M)
  now_hour=$(date -r "$epoch" +%-H 2>/dev/null || date -d "@$epoch" +%-H)
  now_dom=$(date -r "$epoch" +%-d 2>/dev/null || date -d "@$epoch" +%-d)
  now_mon=$(date -r "$epoch" +%-m 2>/dev/null || date -d "@$epoch" +%-m)
  now_dow=$(date -r "$epoch" +%u 2>/dev/null || date -d "@$epoch" +%u)

  _cron_field_matches "$min" "$now_min" || return 1
  _cron_field_matches "$hour" "$now_hour" || return 1
  _cron_field_matches "$dom" "$now_dom" || return 1
  _cron_field_matches "$mon" "$now_mon" || return 1
  _cron_field_matches "$dow" "$now_dow" || return 1
  return 0
}

cron_matches() {
  cron_matches_at_epoch "$1" "$(date +%s)"
}

_cron_field_matches() {
  local field="$1"
  local value="$2"

  [ "$field" = "*" ] && return 0

  if [[ "$field" == \*/* ]]; then
    local step="${field#*/}"
    (( value % step == 0 )) && return 0
    return 1
  fi

  if [[ "$field" == *-* ]]; then
    local low="${field%%-*}"
    local high="${field##*-}"
    [ "$value" -ge "$low" ] && [ "$value" -le "$high" ] && return 0
    return 1
  fi

  [ "$field" = "$value" ] && return 0
  return 1
}

already_triggered() {
  local general="$1"
  local name="$2"
  local minute_key="${3:-$(date +%Y-%m-%dT%H:%M)}"
  local key
  key=$(schedule_key "$general" "$name")
  local last
  last=$(jq -r --arg n "$key" '.[$n] // ""' "$SCHEDULE_SENT_FILE" 2>/dev/null)
  [ "$last" = "$minute_key" ]
}

mark_triggered() {
  local general="$1"
  local name="$2"
  local minute_key="${3:-$(date +%Y-%m-%dT%H:%M)}"
  local key
  key=$(schedule_key "$general" "$name")
  local current
  current=$(cat "$SCHEDULE_SENT_FILE" 2>/dev/null || echo '{}')
  printf '%s' "$current" | jq --arg n "$key" --arg d "$minute_key" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
}

dispatch_scheduled_task() {
  local general="$1"
  local sched_name="$2"
  local task_type="$3"
  local payload="$4"
  local repo="${5:-}"
  local task_id
  task_id=$(next_task_id) || return 1

  local repo_arg="null"
  if [[ -n "$repo" ]]; then
    repo_arg="\"$repo\""
  fi

  local task
  task=$(jq -n \
    --arg id "$task_id" \
    --arg general "$general" \
    --arg type "$task_type" \
    --arg sched "$sched_name" \
    --argjson payload "$payload" \
    --argjson repo "$repo_arg" \
    '{
      id: $id,
      event_id: ("schedule-" + $sched),
      target_general: $general,
      type: $type,
      repo: $repo,
      payload: $payload,
      priority: "low",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task" || return 1
  create_thread_start_message "$task_id" "$general" \
    "$(jq -n --arg t "$task_type" --argjson r "$repo_arg" '{type: ("schedule." + $t), repo: $r}')"
}

check_general_schedules() {
  local schedules
  schedules=$(get_schedules)
  [ -z "$schedules" ] && return 0

  local now_epoch current_minute first_minute
  now_epoch=$(date +%s)
  current_minute=$((now_epoch - (now_epoch % 60)))
  first_minute="${KING_LAST_SCHEDULE_SCAN_EPOCH:-$((current_minute - 60))}"
  first_minute=$((first_minute - (first_minute % 60)))

  if (( first_minute > current_minute )); then
    first_minute=$current_minute
  fi

  echo "$schedules" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local general="${entry%%|*}"
    local sched_json="${entry#*|}"

    local sched_name
    sched_name=$(echo "$sched_json" | jq -r '.name')
    local cron_expr
    cron_expr=$(echo "$sched_json" | jq -r '.cron')
    local task_type
    task_type=$(echo "$sched_json" | jq -r '.task_type')
    local payload
    payload=$(echo "$sched_json" | jq '.payload')
    local repo
    repo=$(echo "$sched_json" | jq -r '.repo // empty')

    local slot
    slot=$first_minute
    while (( slot <= current_minute )); do
      local minute_key
      minute_key=$(date -r "$slot" +%Y-%m-%dT%H:%M 2>/dev/null || date -d "@$slot" +%Y-%m-%dT%H:%M)

      if cron_matches_at_epoch "$cron_expr" "$slot" && ! already_triggered "$general" "$sched_name" "$minute_key"; then
        local health
        health=$(get_resource_health)
        if ! can_accept_task "$health" "normal"; then
          log "[WARN] [king] Skipping schedule '$sched_name': resource $health"
          break
        fi

        if dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload" "$repo"; then
          mark_triggered "$general" "$sched_name" "$minute_key"
          log "[EVENT] [king] Scheduled task triggered: $sched_name -> $general ($minute_key)"
        else
          log "[ERROR] [king] Failed to dispatch schedule: $sched_name -> $general ($minute_key)"
        fi
      fi

      slot=$((slot + 60))
    done
  done

  KING_LAST_SCHEDULE_SCAN_EPOCH=$current_minute
}

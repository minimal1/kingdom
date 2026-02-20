#!/usr/bin/env bash
# King Functions — all king logic extracted for testability
# Source this file to get king functions without starting the main loop.

# --- Sequence ID Generation (unified) ---

next_seq_id() {
  local prefix="$1"
  local seq_file="$2"

  local today
  today=$(date +%Y%m%d)
  local last
  last=$(cat "$seq_file" 2>/dev/null || echo "00000000:000")
  local last_date="${last%%:*}"
  local last_seq="${last##*:}"

  local seq
  if [ "$last_date" = "$today" ]; then
    seq=$((10#$last_seq + 1))
  else
    seq=1
  fi

  local formatted
  formatted=$(printf '%03d' $seq)
  echo "${today}:${formatted}" > "$seq_file"
  echo "${prefix}-${today}-${formatted}"
}

next_task_id() {
  next_seq_id "task" "$TASK_SEQ_FILE"
}

next_msg_id() {
  next_seq_id "msg" "$MSG_SEQ_FILE"
}

# --- Atomic Write Helper ---

write_to_queue() {
  local dir="$1"
  local id="$2"
  local json="$3"

  echo "$json" > "$dir/.tmp-${id}.json"
  mv "$dir/.tmp-${id}.json" "$dir/${id}.json"
}

# --- Message Creation Helpers ---

create_thread_start_message() {
  local task_id="$1"
  local general="$2"
  local event="$3"
  local event_type
  event_type=$(echo "$event" | jq -r '.type')
  local repo
  repo=$(echo "$event" | jq -r '.repo // ""')
  local msg_id
  msg_id=$(next_msg_id)
  local channel
  channel=$(get_config "king" "slack.default_channel")

  local content
  content=$(printf '📋 %s | %s\n%s' "$general" "$task_id" "$event_type")
  [ -n "$repo" ] && content=$(printf '📋 %s | %s\n%s | %s' "$general" "$task_id" "$event_type" "$repo")

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_thread_update_message() {
  local task_id="$1"
  local content="$2"
  local msg_id
  msg_id=$(next_msg_id)

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
    '{id: $id, type: "thread_update", task_id: $task, content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_notification_message() {
  local task_id="$1"
  local content="$2"
  local msg_id
  msg_id=$(next_msg_id)
  local channel
  channel=$(get_config "king" "slack.default_channel")

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "normal", content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

# --- Event Processing ---

process_pending_events() {
  local pending_dir="$BASE_DIR/queue/events/pending"
  local events
  events=$(collect_and_sort_events "$pending_dir")
  [ -z "$events" ] && return 0

  echo "$events" | while IFS= read -r event_file; do
    [ -f "$event_file" ] || continue
    local event
    event=$(cat "$event_file")
    local event_id
    event_id=$(echo "$event" | jq -r '.id')
    local event_type
    event_type=$(echo "$event" | jq -r '.type')
    local priority
    priority=$(echo "$event" | jq -r '.priority')

    # slack.human_response → resume path
    if [ "$event_type" = "slack.human_response" ]; then
      process_human_response "$event" "$event_file" || true
      continue
    fi

    # 1. Resource check (health + token status)
    local health token_status
    health=$(get_resource_health)
    token_status=$(get_token_status)
    if ! can_accept_task "$health" "$priority" "$token_status"; then
      continue
    fi

    # 2. Soldier count check
    local max_soldiers
    max_soldiers=$(get_config "king" "concurrency.max_soldiers" "3")
    local active_soldiers=0
    if [ -f "$BASE_DIR/state/sessions.json" ]; then
      active_soldiers=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
    fi
    if [ "$active_soldiers" -ge "$max_soldiers" ] 2>/dev/null; then
      log "[EVENT] [king] Max soldiers reached ($active_soldiers/$max_soldiers), deferring: $event_id"
      continue
    fi

    # 3. General matching
    local general
    general=$(find_general "$event_type" 2>/dev/null || true)
    if [ -z "$general" ]; then
      log "[WARN] [king] No general for event type: $event_type, discarding: $event_id"
      mv "$event_file" "$BASE_DIR/queue/events/completed/"
      continue
    fi

    # 4. Dispatch task
    dispatch_new_task "$event" "$general" "$event_file"
  done
}

dispatch_new_task() {
  local event="$1"
  local general="$2"
  local event_file="$3"

  local event_id
  event_id=$(echo "$event" | jq -r '.id')
  local event_type
  event_type=$(echo "$event" | jq -r '.type')
  local repo
  repo=$(echo "$event" | jq -r '.repo // empty')
  local priority
  priority=$(echo "$event" | jq -r '.priority')
  local task_id
  task_id=$(next_task_id)

  local task
  task=$(jq -n \
    --arg id "$task_id" \
    --arg event_id "$event_id" \
    --arg general "$general" \
    --arg type "$event_type" \
    --arg priority "$priority" \
    --argjson payload "$(echo "$event" | jq '.payload // {}')" \
    --arg repo "$repo" \
    '{
      id: $id,
      event_id: $event_id,
      target_general: $general,
      type: $type,
      repo: $repo,
      payload: $payload,
      priority: $priority,
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"

  create_thread_start_message "$task_id" "$general" "$event"
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Dispatched: $event_id -> $general (task: $task_id)"
}

process_human_response() {
  local event="$1"
  local event_file="$2"

  local event_id
  event_id=$(echo "$event" | jq -r '.id')
  local original_task_id
  original_task_id=$(echo "$event" | jq -r '.payload.task_id')
  local human_response
  human_response=$(echo "$event" | jq -r '.payload.human_response')
  local task_id
  task_id=$(next_task_id)

  local checkpoint_file="$BASE_DIR/state/results/${original_task_id}-checkpoint.json"
  if [ ! -f "$checkpoint_file" ]; then
    log "[ERROR] [king] Checkpoint not found for task: $original_task_id"
    mv "$event_file" "$BASE_DIR/queue/events/completed/"
    return 1
  fi

  local checkpoint
  checkpoint=$(cat "$checkpoint_file")
  local original_general
  original_general=$(echo "$checkpoint" | jq -r '.target_general')
  local repo
  repo=$(echo "$checkpoint" | jq -r '.repo // empty')

  local task
  task=$(jq -n \
    --arg id "$task_id" \
    --arg event_id "$event_id" \
    --arg general "$original_general" \
    --arg original_task "$original_task_id" \
    --arg response "$human_response" \
    --arg repo "$repo" \
    --arg checkpoint_path "$checkpoint_file" \
    '{
      id: $id,
      event_id: $event_id,
      target_general: $general,
      type: "resume",
      repo: $repo,
      payload: {
        original_task_id: $original_task,
        checkpoint_path: $checkpoint_path,
        human_response: $response
      },
      priority: "high",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"

  create_thread_update_message "$original_task_id" \
    "Human response received — resuming task"

  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Resumed task: $original_task_id -> $original_general (new: $task_id)"
}

# --- Result Processing ---

check_task_results() {
  local results_dir="$BASE_DIR/state/results"
  local tasks_in_progress="$BASE_DIR/queue/tasks/in_progress"

  for result_file in "$results_dir"/task-*.json; do
    [ -f "$result_file" ] || continue

    # Skip general-internal files
    echo "$result_file" | grep -qE '\-(checkpoint|raw|soldier-id)\.' && continue

    local result
    result=$(cat "$result_file")
    local task_id
    task_id=$(echo "$result" | jq -r '.task_id')
    local status
    status=$(echo "$result" | jq -r '.status')

    # Skip if task not in_progress (already processed)
    [ -f "$tasks_in_progress/${task_id}.json" ] || continue

    case "$status" in
      success)
        handle_success "$task_id" "$result"
        ;;
      failed)
        handle_failure "$task_id" "$result"
        ;;
      needs_human)
        handle_needs_human "$task_id" "$result"
        ;;
      skipped)
        handle_skipped "$task_id" "$result"
        ;;
      *)
        log "[WARN] [king] Unknown result status: $status for task: $task_id"
        ;;
    esac
  done
}

handle_success() {
  local task_id="$1"
  local result="$2"
  local summary
  summary=$(echo "$result" | jq -r '.summary // "completed"')

  local task
  task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general
  general=$(echo "$task" | jq -r '.target_general')

  complete_task "$task_id"
  create_notification_message "$task_id" "$(printf '✅ %s | %s\n%s' "$general" "$task_id" "$summary")"

  log "[EVENT] [king] Task completed: $task_id"
}

handle_failure() {
  local task_id="$1"
  local result="$2"
  local error
  error=$(echo "$result" | jq -r '.error // "unknown"')

  local task
  task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general
  general=$(echo "$task" | jq -r '.target_general')

  complete_task "$task_id"
  create_notification_message "$task_id" "$(printf '❌ %s | %s\n%s' "$general" "$task_id" "$error")"

  log "[ERROR] [king] Task failed permanently: $task_id — $error"
}

handle_needs_human() {
  local task_id="$1"
  local result="$2"
  local question
  question=$(echo "$result" | jq -r '.question')
  local checkpoint_path
  checkpoint_path=$(echo "$result" | jq -r '.checkpoint_path')

  local msg_id
  msg_id=$(next_msg_id)
  local message
  message=$(jq -n \
    --arg id "$msg_id" \
    --arg task_id "$task_id" \
    --arg content "[question] $question" \
    --arg checkpoint "$checkpoint_path" \
    '{
      id: $id,
      type: "human_input_request",
      task_id: $task_id,
      content: $content,
      context: { checkpoint_path: $checkpoint },
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"

  # Task stays in_progress (waiting for human response)
  log "[EVENT] [king] Needs human input for task: $task_id"
}

handle_skipped() {
  local task_id="$1"
  local result="$2"
  local reason
  reason=$(echo "$result" | jq -r '.reason // "out of scope"')

  local task
  task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general
  general=$(echo "$task" | jq -r '.target_general')

  complete_task "$task_id"
  create_notification_message "$task_id" "$(printf '⏭️ %s | %s\n%s' "$general" "$task_id" "$reason")"

  log "[EVENT] [king] Task skipped: $task_id — $reason"
}

complete_task() {
  local task_id="$1"
  local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"

  if [ -f "$task_file" ]; then
    local task
    task=$(cat "$task_file")
    local event_id
    event_id=$(echo "$task" | jq -r '.event_id')

    mv "$task_file" "$BASE_DIR/queue/tasks/completed/"

    local event_file="$BASE_DIR/queue/events/dispatched/${event_id}.json"
    if [ -f "$event_file" ]; then
      mv "$event_file" "$BASE_DIR/queue/events/completed/"
    fi
  fi
}

# --- Schedule Processing ---

cron_matches() {
  local expr="$1"
  local min hour dom mon dow

  # Split cron expression into fields
  read -r min hour dom mon dow <<< "$expr"

  local now_min now_hour now_dom now_mon now_dow
  now_min=$(date +%-M)
  now_hour=$(date +%-H)
  now_dom=$(date +%-d)
  now_mon=$(date +%-m)
  now_dow=$(date +%u)  # 1=Mon, 7=Sun

  # Check each field
  _cron_field_matches "$min" "$now_min" || return 1
  _cron_field_matches "$hour" "$now_hour" || return 1
  _cron_field_matches "$dom" "$now_dom" || return 1
  _cron_field_matches "$mon" "$now_mon" || return 1
  _cron_field_matches "$dow" "$now_dow" || return 1
  return 0
}

_cron_field_matches() {
  local field="$1"
  local value="$2"

  # Wildcard
  [ "$field" = "*" ] && return 0

  # Step (e.g. */10, */5)
  if [[ "$field" == \*/* ]]; then
    local step="${field#*/}"
    (( value % step == 0 )) && return 0
    return 1
  fi

  # Range (e.g. 1-5)
  if [[ "$field" == *-* ]]; then
    local low="${field%%-*}"
    local high="${field##*-}"
    [ "$value" -ge "$low" ] && [ "$value" -le "$high" ] && return 0
    return 1
  fi

  # Exact match
  [ "$field" = "$value" ] && return 0
  return 1
}

already_triggered() {
  local name="$1"
  local now_key
  now_key=$(date +%Y-%m-%dT%H:%M)
  local last
  last=$(jq -r --arg n "$name" '.[$n] // ""' "$SCHEDULE_SENT_FILE" 2>/dev/null)
  [ "$last" = "$now_key" ]
}

mark_triggered() {
  local name="$1"
  local now_key
  now_key=$(date +%Y-%m-%dT%H:%M)
  local current
  current=$(cat "$SCHEDULE_SENT_FILE" 2>/dev/null || echo '{}')
  echo "$current" | jq --arg n "$name" --arg d "$now_key" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
}

dispatch_scheduled_task() {
  local general="$1"
  local sched_name="$2"
  local task_type="$3"
  local payload="$4"
  local task_id
  task_id=$(next_task_id)

  local task
  task=$(jq -n \
    --arg id "$task_id" \
    --arg general "$general" \
    --arg type "$task_type" \
    --arg sched "$sched_name" \
    --argjson payload "$payload" \
    '{
      id: $id,
      event_id: ("schedule-" + $sched),
      target_general: $general,
      type: $type,
      repo: null,
      payload: $payload,
      priority: "low",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"

  create_thread_start_message "$task_id" "$general" \
    "$(jq -n --arg t "$task_type" '{type: ("schedule." + $t), repo: null}')"
}

check_general_schedules() {
  local schedules
  schedules=$(get_schedules)
  [ -z "$schedules" ] && return 0

  echo "$schedules" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local general="${entry%%|*}"
    local sched_json="${entry#*|}"

    local sched_name
    sched_name=$(echo "$sched_json" | jq -r '.name')
    local cron_expr
    cron_expr=$(echo "$sched_json" | jq -r '.cron')

    if cron_matches "$cron_expr" && ! already_triggered "$sched_name"; then
      local task_type
      task_type=$(echo "$sched_json" | jq -r '.task_type')
      local payload
      payload=$(echo "$sched_json" | jq '.payload')

      local health token_status
      health=$(get_resource_health)
      token_status=$(get_token_status)
      if ! can_accept_task "$health" "normal" "$token_status"; then
        log "[WARN] [king] Skipping schedule '$sched_name': resource $health, token $token_status"
        continue
      fi

      dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload"
      mark_triggered "$sched_name"
      log "[EVENT] [king] Scheduled task triggered: $sched_name -> $general"
    fi
  done
}

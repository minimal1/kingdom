#!/usr/bin/env bats
# king.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Copy configs
  cp "${BATS_TEST_DIRNAME}/../config/king.yaml" "$BASE_DIR/config/"
  install_test_general "gen-pr"
  install_test_general "gen-jira"
  install_test_general "gen-test"

  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/router.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/resource-check.sh"

  # Initialize state files
  echo '0' > "$BASE_DIR/state/king/task-seq"
  echo '0' > "$BASE_DIR/state/king/msg-seq"
  echo '{}' > "$BASE_DIR/state/king/schedule-sent.json"
  echo '[]' > "$BASE_DIR/state/sessions.json"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"green\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  # Source king functions (not the main loop)
  TASK_SEQ_FILE="$BASE_DIR/state/king/task-seq"
  MSG_SEQ_FILE="$BASE_DIR/state/king/msg-seq"
  SCHEDULE_SENT_FILE="$BASE_DIR/state/king/schedule-sent.json"

  load_general_manifests

  # Define king functions inline (avoid main loop execution)
  source_king_functions
}

source_king_functions() {
  # next_task_id
  next_task_id() {
    local today
    today=$(date +%Y%m%d)
    local last
    last=$(cat "$TASK_SEQ_FILE" 2>/dev/null || echo "00000000:000")
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
    echo "${today}:${formatted}" > "$TASK_SEQ_FILE"
    echo "task-${today}-${formatted}"
  }

  # next_msg_id
  next_msg_id() {
    local today
    today=$(date +%Y%m%d)
    local last
    last=$(cat "$MSG_SEQ_FILE" 2>/dev/null || echo "00000000:000")
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
    echo "${today}:${formatted}" > "$MSG_SEQ_FILE"
    echo "msg-${today}-${formatted}"
  }

  # Message creation helpers
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

    echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
    mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
       "$BASE_DIR/queue/messages/pending/${msg_id}.json"
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

    echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
    mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
       "$BASE_DIR/queue/messages/pending/${msg_id}.json"
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

    echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
    mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
       "$BASE_DIR/queue/messages/pending/${msg_id}.json"
  }

  # Event processing
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
        id: $id, event_id: $event_id, target_general: $general,
        type: $type, repo: $repo, payload: $payload,
        priority: $priority, retry_count: 0,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"
      }')

    echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
    mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
       "$BASE_DIR/queue/tasks/pending/${task_id}.json"

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
        id: $id, event_id: $event_id, target_general: $general,
        type: "resume", repo: $repo,
        payload: { original_task_id: $original_task, checkpoint_path: $checkpoint_path, human_response: $response },
        priority: "high", retry_count: 0,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"
      }')

    echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
    mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
       "$BASE_DIR/queue/tasks/pending/${task_id}.json"

    create_thread_update_message "$original_task_id" "Human response received — resuming task"
    mv "$event_file" "$BASE_DIR/queue/events/dispatched/"
    log "[EVENT] [king] Resumed task: $original_task_id -> $original_general (new: $task_id)"
  }

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

      if [ "$event_type" = "slack.human_response" ]; then
        process_human_response "$event" "$event_file" || true
        continue
      fi

      local health
      health=$(get_resource_health)
      if ! can_accept_task "$health" "$priority"; then
        continue
      fi

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

      local general
      general=$(find_general "$event_type" 2>/dev/null || true)
      if [ -z "$general" ]; then
        log "[WARN] [king] No general for event type: $event_type, discarding: $event_id"
        mv "$event_file" "$BASE_DIR/queue/events/completed/"
        continue
      fi

      dispatch_new_task "$event" "$general" "$event_file"
    done
  }

  # Result processing
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
      --arg id "$msg_id" --arg task_id "$task_id" \
      --arg content "[question] $question" --arg checkpoint "$checkpoint_path" \
      '{id: $id, type: "human_input_request", task_id: $task_id,
        content: $content, context: { checkpoint_path: $checkpoint },
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
    mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
       "$BASE_DIR/queue/messages/pending/${msg_id}.json"
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

  check_task_results() {
    local results_dir="$BASE_DIR/state/results"
    local tasks_in_progress="$BASE_DIR/queue/tasks/in_progress"
    for result_file in "$results_dir"/task-*.json; do
      [ -f "$result_file" ] || continue
      echo "$result_file" | grep -qE '\-(checkpoint|raw|soldier-id)\.' && continue
      local result
      result=$(cat "$result_file")
      local task_id
      task_id=$(echo "$result" | jq -r '.task_id')
      local status
      status=$(echo "$result" | jq -r '.status')
      [ -f "$tasks_in_progress/${task_id}.json" ] || continue
      case "$status" in
        success) handle_success "$task_id" "$result" ;;
        failed) handle_failure "$task_id" "$result" ;;
        needs_human) handle_needs_human "$task_id" "$result" ;;
        skipped) handle_skipped "$task_id" "$result" ;;
      esac
    done
  }

  # Cron + schedule
  cron_matches() {
    local expr="$1"
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "$expr"
    local now_min now_hour now_dom now_mon now_dow
    now_min=$(date +%-M)
    now_hour=$(date +%-H)
    now_dom=$(date +%-d)
    now_mon=$(date +%-m)
    now_dow=$(date +%u)
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
      --arg id "$task_id" --arg general "$general" \
      --arg type "$task_type" --arg sched "$sched_name" \
      --argjson payload "$payload" \
      '{id: $id, event_id: ("schedule-" + $sched), target_general: $general,
        type: $type, repo: null, payload: $payload,
        priority: "low", retry_count: 0,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
    mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
       "$BASE_DIR/queue/tasks/pending/${task_id}.json"
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
        local health
        health=$(get_resource_health)
        if ! can_accept_task "$health" "normal"; then
          continue
        fi
        dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload"
        mark_triggered "$sched_name"
      fi
    done
  }
}

teardown() {
  [ -n "$ROUTING_TABLE_FILE" ] && rm -f "$ROUTING_TABLE_FILE"
  [ -n "$SCHEDULES_FILE" ] && rm -f "$SCHEDULES_FILE"
  teardown_kingdom_env
}

# --- Task ID Generation ---

@test "king: next_task_id generates correct format" {
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-001" ]]
}

@test "king: next_task_id increments sequence" {
  next_task_id > /dev/null
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-002" ]]
}

@test "king: next_task_id resets on new date" {
  echo "20260101:050" > "$TASK_SEQ_FILE"
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-001" ]]
}

@test "king: next_msg_id generates correct format" {
  local id
  id=$(next_msg_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "msg-${today}-001" ]]
}

# --- Event Processing ---

@test "king: process_pending_events creates task from event" {
  cat > "$BASE_DIR/queue/events/pending/evt-001.json" << 'EOF'
{"id":"evt-001","type":"github.pr.review_requested","source":"github","priority":"normal","repo":"chequer/qp","payload":{"pr_number":123}}
EOF

  process_pending_events

  # Event moved to dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-001.json" ]

  # Task created in pending
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -ge 1 ]

  # Task has correct general
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
}

@test "king: process_pending_events creates thread_start message" {
  cat > "$BASE_DIR/queue/events/pending/evt-002.json" << 'EOF'
{"id":"evt-002","type":"jira.ticket.assigned","source":"jira","priority":"normal","repo":"chequer/qp","payload":{}}
EOF

  process_pending_events

  # Message created
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -ge 1 ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
}

@test "king: unmatched event moves to completed" {
  cat > "$BASE_DIR/queue/events/pending/evt-003.json" << 'EOF'
{"id":"evt-003","type":"unknown.event","source":"test","priority":"normal","payload":{}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-003.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-003.json" ]
}

@test "king: yellow health defers normal priority events" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"yellow\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  cat > "$BASE_DIR/queue/events/pending/evt-004.json" << 'EOF'
{"id":"evt-004","type":"github.pr.review_requested","source":"github","priority":"normal","payload":{}}
EOF

  process_pending_events

  # Event should stay in pending (deferred)
  assert [ -f "$BASE_DIR/queue/events/pending/evt-004.json" ]
}

@test "king: yellow health accepts high priority events" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"yellow\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  cat > "$BASE_DIR/queue/events/pending/evt-005.json" << 'EOF'
{"id":"evt-005","type":"github.pr.review_requested","source":"github","priority":"high","payload":{}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-005.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-005.json" ]
}

# --- Result Processing ---

@test "king: handle_success completes task and creates notification" {
  # Setup: task in in_progress, event in dispatched
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-001.json" << 'EOF'
{"id":"task-20260210-001","event_id":"evt-010","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-010.json"

  # Result file
  cat > "$BASE_DIR/state/results/task-20260210-001.json" << 'EOF'
{"task_id":"task-20260210-001","status":"success","summary":"PR approved"}
EOF

  check_task_results

  # Task moved to completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-001.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-001.json" ]

  # Event moved to completed
  assert [ -f "$BASE_DIR/queue/events/completed/evt-010.json" ]

  # Notification message created
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "notification"
  run jq -r '.content' "$msg_file"
  assert_output --partial "✅ gen-pr"
}

@test "king: handle_failure completes task with error notification" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-002.json" << 'EOF'
{"id":"task-20260210-002","event_id":"evt-011","target_general":"gen-jira","type":"jira.ticket.assigned","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-011.json"

  cat > "$BASE_DIR/state/results/task-20260210-002.json" << 'EOF'
{"task_id":"task-20260210-002","status":"failed","error":"build failed"}
EOF

  check_task_results

  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-002.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-002.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.content' "$msg_file"
  assert_output --partial "❌ gen-jira"
}

@test "king: handle_needs_human creates human_input_request message" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" << 'EOF'
{"id":"task-20260210-003","event_id":"evt-012","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF

  cat > "$BASE_DIR/state/results/task-20260210-003.json" << 'EOF'
{"task_id":"task-20260210-003","status":"needs_human","question":"Should I approve this PR?","checkpoint_path":"/tmp/cp.json"}
EOF

  check_task_results

  # Task stays in in_progress
  assert [ -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"
  run jq -r '.content' "$msg_file"
  assert_output --partial "[question]"
}

@test "king: skips checkpoint/raw/soldier-id result files" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-004.json" << 'EOF'
{"id":"task-20260210-004","event_id":"evt-013","status":"in_progress"}
EOF

  # These should be skipped
  echo '{"task_id":"task-20260210-004"}' > "$BASE_DIR/state/results/task-20260210-004-checkpoint.json"
  echo '{"task_id":"task-20260210-004"}' > "$BASE_DIR/state/results/task-20260210-004-raw.json"
  echo 'soldier-123' > "$BASE_DIR/state/results/task-20260210-004-soldier-id"

  check_task_results

  # Task should remain in_progress (no valid result file to process)
  assert [ -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-004.json" ]
}

# --- Human Response ---

@test "king: process_human_response creates resume task" {
  # Checkpoint for original task
  cat > "$BASE_DIR/state/results/task-20260210-010-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","repo":"chequer/qp","context":"some context"}
EOF

  # Human response event
  cat > "$BASE_DIR/queue/events/pending/evt-hr-001.json" << 'EOF'
{"id":"evt-hr-001","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-20260210-010","human_response":"Yes, approve it"}}
EOF

  process_pending_events

  # Event moved to dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-hr-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-hr-001.json" ]

  # Resume task created
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.type' "$task_file"
  assert_output "resume"
  run jq -r '.payload.human_response' "$task_file"
  assert_output "Yes, approve it"
  run jq -r '.priority' "$task_file"
  assert_output "high"
}

@test "king: human_response with missing checkpoint moves to completed" {
  cat > "$BASE_DIR/queue/events/pending/evt-hr-002.json" << 'EOF'
{"id":"evt-hr-002","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-nonexistent","human_response":"test"}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-hr-002.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-hr-002.json" ]
}

# --- Cron Matching ---

@test "king: cron_matches wildcard matches always" {
  run cron_matches "* * * * *"
  assert_success
}

@test "king: cron_matches exact mismatch fails" {
  run cron_matches "59 23 31 12 7"
  # This will almost certainly fail (unless it's Dec 31 at 23:59 on Sunday)
  assert_failure
}

@test "king: cron_matches range works" {
  local now_dow
  now_dow=$(date +%u)
  # Range 1-7 should always match
  run cron_matches "* * * * 1-7"
  assert_success
}

# --- Schedule ---

@test "king: already_triggered prevents duplicate" {
  mark_triggered "test-schedule"
  run already_triggered "test-schedule"
  assert_success
}

@test "king: untriggered schedule returns false" {
  run already_triggered "never-triggered"
  assert_failure
}

@test "king: handle_skipped completes task and creates skip notification" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-005.json" << 'EOF'
{"id":"task-20260210-005","event_id":"evt-014","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-014.json"

  cat > "$BASE_DIR/state/results/task-20260210-005.json" << 'EOF'
{"task_id":"task-20260210-005","status":"skipped","reason":"PR is outside frontend scope"}
EOF

  check_task_results

  # Task moved to completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-005.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-005.json" ]

  # Event moved to completed
  assert [ -f "$BASE_DIR/queue/events/completed/evt-014.json" ]

  # Notification message created with ⏭️ prefix
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 1 ]
  local content
  content=$(jq -r '.content' "$BASE_DIR/queue/messages/pending/"*.json)
  echo "$content" | grep -q '⏭️ gen-pr'
}

@test "king: max_soldiers defers events when full" {
  # Fill sessions.json with 3 entries (max_soldiers = 3)
  echo '[{"id":"s1"},{"id":"s2"},{"id":"s3"}]' > "$BASE_DIR/state/sessions.json"

  cat > "$BASE_DIR/queue/events/pending/evt-full.json" << 'EOF'
{"id":"evt-full","type":"github.pr.review_requested","source":"github","priority":"normal","payload":{}}
EOF

  process_pending_events

  # Event should stay in pending (deferred due to max soldiers)
  assert [ -f "$BASE_DIR/queue/events/pending/evt-full.json" ]
}

# --- Cron Step Pattern ---

@test "king: cron step */10 matches multiples" {
  run _cron_field_matches "*/10" "0"
  assert_success
  run _cron_field_matches "*/10" "20"
  assert_success
  run _cron_field_matches "*/10" "7"
  assert_failure
}

@test "king: cron step */5 matches multiples" {
  run _cron_field_matches "*/5" "0"
  assert_success
  run _cron_field_matches "*/5" "15"
  assert_success
  run _cron_field_matches "*/5" "3"
  assert_failure
}

# --- Minute-based Dedup ---

@test "king: already_triggered uses minute-based dedup" {
  mark_triggered "test-min"
  run already_triggered "test-min"
  assert_success
}

@test "king: different minute is not duplicate" {
  local old_key
  old_key=$(date -v-1M +%Y-%m-%dT%H:%M 2>/dev/null || date -d "1 minute ago" +%Y-%m-%dT%H:%M)
  echo "{}" | jq --arg n "test-old" --arg d "$old_key" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
  run already_triggered "test-old"
  assert_failure
}

# --- Schedule Dispatch E2E ---

@test "king: check_general_schedules dispatches task and message" {
  # Write a schedule that always matches (every minute)
  echo 'gen-test|{"name":"test-every-min","cron":"* * * * *","task_type":"test-sched","payload":{}}' > "$SCHEDULES_FILE"

  check_general_schedules

  # Task created in pending
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -ge 1 ]

  # Task has correct fields
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-test"
  run jq -r '.type' "$task_file"
  assert_output "test-sched"
  run jq -r '.event_id' "$task_file"
  assert_output "schedule-test-every-min"

  # Thread start message created
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -ge 1 ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
  run jq -r '.content' "$msg_file"
  assert_output --partial "gen-test"

  # Dedup: second call should NOT create another task
  check_general_schedules
  local task_count2
  task_count2=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count2" -eq "$task_count" ]
}

@test "king: check_general_schedules skips non-matching cron" {
  # Schedule that never matches (Feb 30 doesn't exist)
  echo 'gen-test|{"name":"test-never","cron":"0 0 30 2 *","task_type":"never","payload":{}}' > "$SCHEDULES_FILE"

  check_general_schedules

  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

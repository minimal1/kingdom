#!/usr/bin/env bash
# Integration Test Helper — loads king + general functions without main loops

setup_integration_env() {
  # Copy all configs
  local src_dir="${BATS_TEST_DIRNAME}/../.."
  cp "$src_dir/config/king.yaml" "$BASE_DIR/config/"
  cp "$src_dir/config/chamberlain.yaml" "$BASE_DIR/config/"
  install_test_general "gen-pr"
  install_test_general "gen-jira"
  install_test_general "gen-test"

  # Source common + king modules
  source "$src_dir/bin/lib/common.sh"
  source "$src_dir/bin/lib/king/router.sh"
  source "$src_dir/bin/lib/king/resource-check.sh"

  # Initialize state
  echo '0' > "$BASE_DIR/state/king/task-seq"
  echo '0' > "$BASE_DIR/state/king/msg-seq"
  echo '{}' > "$BASE_DIR/state/king/schedule-sent.json"
  echo '[]' > "$BASE_DIR/state/sessions.json"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"green\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  TASK_SEQ_FILE="$BASE_DIR/state/king/task-seq"
  MSG_SEQ_FILE="$BASE_DIR/state/king/msg-seq"
  SCHEDULE_SENT_FILE="$BASE_DIR/state/king/schedule-sent.json"

  load_general_manifests

  # Load king functions
  _define_king_functions

  # Load general functions
  GENERAL_DOMAIN="gen-pr"
  # Copy common.sh to expected path for general source chain
  mkdir -p "$BASE_DIR/bin/lib/general"
  cp "$src_dir/bin/lib/general/common.sh" "$BASE_DIR/bin/lib/general/"
  cp "$src_dir/bin/lib/general/prompt-builder.sh" "$BASE_DIR/bin/lib/general/"
  mkdir -p "$BASE_DIR/plugins/friday"

  # Create mock spawn-soldier
  cat > "$BASE_DIR/mock-spawn-soldier.sh" << 'MOCKEOF'
#!/usr/bin/env bash
TASK_ID="$1"
SOLDIER_ID="soldier-$(date +%s)-$$"
echo "$SOLDIER_ID" > "${KINGDOM_BASE_DIR}/state/results/${TASK_ID}-soldier-id"
MOCKEOF
  chmod +x "$BASE_DIR/mock-spawn-soldier.sh"
  export SPAWN_SOLDIER_SCRIPT="$BASE_DIR/mock-spawn-soldier.sh"

  source "$src_dir/bin/lib/general/common.sh"
}

_define_king_functions() {
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

  create_thread_start_message() {
    local task_id="$1"
    local event="$2"
    local event_type
    event_type=$(echo "$event" | jq -r '.type')
    local repo
    repo=$(echo "$event" | jq -r '.repo // ""')
    local msg_id
    msg_id=$(next_msg_id)
    local content="[start] ${event_type}"
    [ -n "$repo" ] && content="$content — $repo"
    local message
    message=$(jq -n --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
      '{id: $id, type: "thread_start", task_id: $task, content: $ct,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$message" > "$BASE_DIR/queue/messages/pending/${msg_id}.json"
  }

  create_thread_update_message() {
    local task_id="$1"
    local content="$2"
    local msg_id
    msg_id=$(next_msg_id)
    local message
    message=$(jq -n --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
      '{id: $id, type: "thread_update", task_id: $task, content: $ct,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$message" > "$BASE_DIR/queue/messages/pending/${msg_id}.json"
  }

  create_notification_message() {
    local task_id="$1"
    local content="$2"
    local msg_id
    msg_id=$(next_msg_id)
    local message
    message=$(jq -n --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
      '{id: $id, type: "notification", task_id: $task, content: $ct,
        urgency: "normal", created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$message" > "$BASE_DIR/queue/messages/pending/${msg_id}.json"
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
      --arg id "$task_id" --arg event_id "$event_id" --arg general "$general" \
      --arg type "$event_type" --arg priority "$priority" \
      --argjson payload "$(echo "$event" | jq '.payload // {}')" --arg repo "$repo" \
      '{id: $id, event_id: $event_id, target_general: $general, type: $type,
        repo: $repo, payload: $payload, priority: $priority, retry_count: 0,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$task" > "$BASE_DIR/queue/tasks/pending/${task_id}.json"
    create_thread_start_message "$task_id" "$event"
    mv "$event_file" "$BASE_DIR/queue/events/dispatched/"
    log "[EVENT] [king] Dispatched: $event_id -> $general (task: $task_id)"
  }

  process_human_response() {
    local event="$1"
    local event_file="$2"
    local original_task_id
    original_task_id=$(echo "$event" | jq -r '.payload.task_id')
    local human_response
    human_response=$(echo "$event" | jq -r '.payload.human_response')
    local task_id
    task_id=$(next_task_id)
    local checkpoint_file="$BASE_DIR/state/results/${original_task_id}-checkpoint.json"
    if [ ! -f "$checkpoint_file" ]; then
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
      --arg id "$task_id" --arg general "$original_general" \
      --arg original_task "$original_task_id" --arg response "$human_response" \
      --arg repo "$repo" --arg cp "$checkpoint_file" \
      '{id: $id, target_general: $general, type: "resume", repo: $repo,
        payload: {original_task_id: $original_task, checkpoint_path: $cp, human_response: $response},
        priority: "high", created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$task" > "$BASE_DIR/queue/tasks/pending/${task_id}.json"
    create_thread_update_message "$original_task_id" "Human response received"
    mv "$event_file" "$BASE_DIR/queue/events/dispatched/"
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
      local general
      general=$(find_general "$event_type" 2>/dev/null || true)
      if [ -z "$general" ]; then
        mv "$event_file" "$BASE_DIR/queue/events/completed/"
        continue
      fi
      dispatch_new_task "$event" "$general" "$event_file"
    done
  }

  complete_task() {
    local task_id="$1"
    local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
    if [ -f "$task_file" ]; then
      local event_id
      event_id=$(jq -r '.event_id' "$task_file")
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
    complete_task "$task_id"
    create_notification_message "$task_id" "[complete] $summary"
  }

  handle_failure() {
    local task_id="$1"
    local result="$2"
    local error
    error=$(echo "$result" | jq -r '.error // "unknown"')
    complete_task "$task_id"
    create_notification_message "$task_id" "[failed] $error"
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
      --arg content "[question] $question" --arg cp "$checkpoint_path" \
      '{id: $id, type: "human_input_request", task_id: $task_id,
        content: $content, context: {checkpoint_path: $cp},
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
    echo "$message" > "$BASE_DIR/queue/messages/pending/${msg_id}.json"
  }

  check_task_results() {
    for result_file in "$BASE_DIR/state/results"/task-*.json; do
      [ -f "$result_file" ] || continue
      echo "$result_file" | grep -qE '\-(checkpoint|raw|soldier-id)\.' && continue
      local result
      result=$(cat "$result_file")
      local task_id
      task_id=$(echo "$result" | jq -r '.task_id')
      local status
      status=$(echo "$result" | jq -r '.status')
      [ -f "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" ] || continue
      case "$status" in
        success) handle_success "$task_id" "$result" ;;
        failed) handle_failure "$task_id" "$result" ;;
        needs_human) handle_needs_human "$task_id" "$result" ;;
      esac
    done
  }
}

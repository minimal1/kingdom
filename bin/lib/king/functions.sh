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

# --- Source Ref Helper ---

# DM 기반 task의 원본 메시지 참조를 추출 (리액션 업데이트용)
extract_source_ref() {
  local task="$1"
  local src_msg_ts src_ch
  src_msg_ts=$(echo "$task" | jq -r '.payload.message_ts // empty')
  src_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  if [[ -n "$src_msg_ts" && -n "$src_ch" ]]; then
    jq -n --arg ch "$src_ch" --arg ts "$src_msg_ts" '{channel: $ch, message_ts: $ts}'
  else
    echo "null"
  fi
}

# --- Atomic Write Helper ---

write_to_queue() {
  local dir="$1"
  local id="$2"
  local json="$3"

  echo "$json" > "$dir/.tmp-${id}.json"
  mv "$dir/.tmp-${id}.json" "$dir/${id}.json"
}

# --- Task Context Formatter ---

format_task_context() {
  local type="$1"
  local payload="$2"

  case "$type" in
    github.pr.*|github.issue.*)
      local title pr_number repo_name html_url
      title=$(echo "$payload" | jq -r '.subject_title // empty')
      pr_number=$(echo "$payload" | jq -r '.pr_number // empty')
      repo_name=$(echo "$payload" | jq -r '.repo // empty')
      if [[ -n "$pr_number" && -n "$repo_name" ]]; then
        html_url="https://github.com/${repo_name}/pull/${pr_number}"
        printf '<%s|#%s %s>' "$html_url" "$pr_number" "$title"
      elif [[ -n "$title" ]]; then
        printf '%s' "$title"
      fi
      ;;
    jira.ticket.*)
      local url ticket_key summary
      url=$(echo "$payload" | jq -r '.url // empty')
      ticket_key=$(echo "$payload" | jq -r '.ticket_key // empty')
      summary=$(echo "$payload" | jq -r '.summary // empty')
      if [[ -n "$url" && -n "$ticket_key" ]]; then
        printf '<%s|%s %s>' "$url" "$ticket_key" "$summary"
      elif [[ -n "$summary" ]]; then
        printf '%s' "$summary"
      fi
      ;;
  esac
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
  channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"

  # Build rich context from payload
  local payload
  payload=$(echo "$event" | jq -c '.payload // {}')
  # Inject repo into payload for format_task_context if not present
  if [[ -n "$repo" ]]; then
    payload=$(echo "$payload" | jq --arg r "$repo" '.repo //= $r')
  fi
  local ctx
  ctx=$(format_task_context "$event_type" "$payload")

  local content
  if [[ -n "$ctx" ]]; then
    content=$(printf '📋 *%s* | %s\n%s\n`%s`' "$general" "$task_id" "$ctx" "$event_type")
  else
    content=$(printf '📋 *%s* | %s\n`%s`' "$general" "$task_id" "$event_type")
    [ -n "$repo" ] && content=$(printf '📋 *%s* | %s\n`%s` | %s' "$general" "$task_id" "$event_type" "$repo")
  fi

  # DM 이벤트: 기존 메시지를 스레드 부모로 재사용 (새 메시지 불필요)
  local existing_ts existing_ch
  existing_ts=$(echo "$event" | jq -r '.payload.message_ts // empty')
  existing_ch=$(echo "$event" | jq -r '.payload.channel // empty')

  local message
  if [[ -n "$existing_ts" && -n "$existing_ch" ]]; then
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$existing_ch" --arg ct "$content" \
      --arg ts "$existing_ts" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        thread_ts: $ts,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  else
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$channel" --arg ct "$content" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  fi

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
  local override_channel="${3:-}"
  local source_ref_json="${4:-null}"
  local msg_id
  msg_id=$(next_msg_id)
  local channel
  if [ -n "$override_channel" ]; then
    channel="$override_channel"
  else
    channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"
  fi

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    --argjson sr "$source_ref_json" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "normal", content: $ct, source_ref: $sr,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_proclamation_message() {
  local task_id="$1" channel="$2" message="$3"
  local msg_id
  msg_id=$(next_msg_id)
  local proc_task_id="proclamation-${task_id}"

  local msg
  msg=$(jq -n \
    --arg id "$msg_id" --arg task "$proc_task_id" \
    --arg ch "$channel" --arg ct "$message" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "high", content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$msg"
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

    # slack.thread.reply → unified resume path
    if [ "$event_type" = "slack.thread.reply" ]; then
      process_thread_reply "$event" "$event_file" || true
      continue
    fi

    # 1. Resource check (health)
    local health
    health=$(get_resource_health)
    if ! can_accept_task "$health" "$priority"; then
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
    local general=""

    if [ "$event_type" = "slack.channel.message" ]; then
      # DM 메시지 -> 상소 심의 (petition) 비동기 처리로 위임
      local petition_enabled
      petition_enabled=$(get_config "king" "petition.enabled" "true")
      local message_text
      message_text=$(echo "$event" | jq -r '.payload.text // empty')

      if [[ "$petition_enabled" = "true" && -n "$message_text" ]]; then
        mv "$event_file" "$PETITIONING_DIR/"
        spawn_petition "$event_id" "$message_text"
        continue
      fi

      # petition 비활성화 시 정적 매핑 직행
      general=$(find_general "$event_type" 2>/dev/null || true)
      if [ -z "$general" ]; then
        handle_unroutable_dm "$event" "$event_file"
        continue
      fi
    else
      # 일반 이벤트 -> 기존 정적 매핑
      general=$(find_general "$event_type" 2>/dev/null || true)
      if [ -z "$general" ]; then
        log "[WARN] [king] No general for event type: $event_type, discarding: $event_id"
        mv "$event_file" "$BASE_DIR/queue/events/completed/"
        continue
      fi
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
  # 이벤트에 repo가 없으면 장군 manifest의 default_repo 사용
  if [[ -z "$repo" ]]; then
    repo=$(get_default_repo "$general")
  fi
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

process_thread_reply() {
  local event="$1"
  local event_file="$2"

  local event_id
  event_id=$(echo "$event" | jq -r '.id')
  local text
  text=$(echo "$event" | jq -r '.payload.text')
  local channel
  channel=$(echo "$event" | jq -r '.payload.channel')
  local thread_ts
  thread_ts=$(echo "$event" | jq -r '.payload.thread_ts')

  # reply_context에서 resume 정보 추출
  local general
  general=$(echo "$event" | jq -r '.payload.reply_context.general // empty')
  local session_id
  session_id=$(echo "$event" | jq -r '.payload.reply_context.session_id // empty')
  local repo
  repo=$(echo "$event" | jq -r '.payload.reply_context.repo // empty')

  if [[ -z "$general" ]]; then
    log "[WARN] [king] No general in reply_context, discarding: $event_id"
    mv "$event_file" "$BASE_DIR/queue/events/completed/"
    return 0
  fi

  local task_id
  task_id=$(next_task_id)
  local task
  task=$(jq -n \
    --arg id "$task_id" --arg event_id "$event_id" \
    --arg general "$general" --arg text "$text" \
    --arg session_id "$session_id" --arg repo "$repo" \
    --arg channel "$channel" --arg thread_ts "$thread_ts" \
    '{ id: $id, event_id: $event_id, target_general: $general,
       type: "resume", repo: (if $repo == "" then null else $repo end),
       payload: { human_response: $text, session_id: $session_id,
                  channel: $channel, thread_ts: $thread_ts },
       priority: "high",
       created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"
  log "[EVENT] [king] Thread reply -> $general (task: $task_id)"
}

# --- Result Processing ---

check_task_results() {
  local results_dir="$BASE_DIR/state/results"
  local tasks_in_progress="$BASE_DIR/queue/tasks/in_progress"

  for result_file in "$results_dir"/task-*.json; do
    [ -f "$result_file" ] || continue

    # Skip general-internal files
    echo "$result_file" | grep -qE '\-(checkpoint|raw|soldier-id|session-id)\.' && continue

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
      killed)
        handle_killed "$task_id" "$result"
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

  # reply_to 분기: 기존 스레드에 답글 or 새 알림
  local reply_ch
  reply_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  local reply_ts
  reply_ts=$(echo "$task" | jq -r '.payload.thread_ts // .payload.message_ts // empty')

  if [[ -n "$reply_ch" && -n "$reply_ts" ]]; then
    local session_id=""
    local session_id_file="$BASE_DIR/state/results/${task_id}-session-id"
    if [ -f "$session_id_file" ]; then
      session_id=$(cat "$session_id_file")
    fi
    local repo
    repo=$(echo "$task" | jq -r '.repo // empty')
    local msg_id
    msg_id=$(next_msg_id)

    local track_json="null"
    if [[ -n "$session_id" ]]; then
      local reply_ctx
      reply_ctx=$(jq -n --arg s "$session_id" --arg g "$general" --arg r "$repo" \
        '{session_id: $s, general: $g, repo: $r}')
      track_json=$(jq -n --argjson rc "$reply_ctx" '{reply_context: $rc}')
    fi

    local source_ref
    source_ref=$(extract_source_ref "$task")

    local message
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$reply_ch" --arg ts "$reply_ts" --arg ct "$summary" \
      --argjson tc "$track_json" --argjson sr "$source_ref" \
      '{ id: $id, type: "thread_reply", task_id: $task, channel: $ch,
         thread_ts: $ts, content: $ct, track_conversation: $tc, source_ref: $sr,
         created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
    write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
  else
    local notify_ch
    notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
    local task_type
    task_type=$(echo "$task" | jq -r '.type // empty')
    local payload
    payload=$(echo "$task" | jq -c '.payload // {}')
    local task_repo
    task_repo=$(echo "$task" | jq -r '.repo // empty')
    if [[ -n "$task_repo" ]]; then
      payload=$(echo "$payload" | jq --arg r "$task_repo" '.repo //= $r')
    fi
    local ctx
    ctx=$(format_task_context "$task_type" "$payload")
    local source_ref
    source_ref=$(extract_source_ref "$task")
    local notif_content
    if [[ -n "$ctx" ]]; then
      notif_content=$(printf '✅ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$summary")
    else
      notif_content=$(printf '✅ *%s* | %s\n%s' "$general" "$task_id" "$summary")
    fi
    create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref"
  fi

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

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
  local notify_ch
  notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
  local task_type
  task_type=$(echo "$task" | jq -r '.type // empty')
  local payload
  payload=$(echo "$task" | jq -c '.payload // {}')
  local task_repo
  task_repo=$(echo "$task" | jq -r '.repo // empty')
  if [[ -n "$task_repo" ]]; then
    payload=$(echo "$payload" | jq --arg r "$task_repo" '.repo //= $r')
  fi
  local ctx
  ctx=$(format_task_context "$task_type" "$payload")
  local source_ref
  source_ref=$(extract_source_ref "$task")
  local notif_content
  if [[ -n "$ctx" ]]; then
    notif_content=$(printf '❌ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$error")
  else
    notif_content=$(printf '❌ *%s* | %s\n%s' "$general" "$task_id" "$error")
  fi
  create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref"

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

  log "[ERROR] [king] Task failed permanently: $task_id — $error"
}

handle_killed() {
  local task_id="$1"
  local result="$2"
  local error
  error=$(echo "$result" | jq -r '.error // "unknown"')

  local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  local task
  task=$(cat "$task_file" 2>/dev/null)
  local general
  general=$(echo "$task" | jq -r '.target_general')
  local retry_count
  retry_count=$(echo "$task" | jq -r '.retry_count // 0')

  local max_retries
  max_retries=$(get_config "king" "retry.max_attempts" "2")

  if (( retry_count < max_retries )); then
    # Re-queue: in_progress/ → pending/ with incremented retry_count
    local updated_task
    updated_task=$(echo "$task" | jq --argjson rc "$((retry_count + 1))" \
      '.retry_count = $rc | .status = "pending"')
    echo "$updated_task" > "${task_file}.tmp"
    mv "${task_file}.tmp" "$BASE_DIR/queue/tasks/pending/${task_id}.json"
    rm -f "$task_file"

    # Clean up result files for this task
    rm -f "$BASE_DIR/state/results/${task_id}-raw.json"
    rm -f "$BASE_DIR/state/results/${task_id}-soldier-id"
    rm -f "$BASE_DIR/state/results/${task_id}-session-id"
    rm -f "$BASE_DIR/state/results/${task_id}.json"

    log "[RETRY] [king] Task re-queued: $task_id ($general) retry=$((retry_count + 1))/$max_retries — $error"
  else
    # Max retries exceeded → fail permanently
    handle_failure "$task_id" "$result"
    log "[ERROR] [king] Task killed after max retries: $task_id ($general) — $error"
  fi
}

handle_needs_human() {
  local task_id="$1"
  local result="$2"
  local question
  question=$(echo "$result" | jq -r '.question')
  local checkpoint_path
  checkpoint_path=$(echo "$result" | jq -r '.checkpoint_path')

  # checkpoint에서 reply_context 구성
  local checkpoint
  checkpoint=$(cat "$checkpoint_path" 2>/dev/null || echo '{}')
  local general
  general=$(echo "$checkpoint" | jq -r '.target_general // empty')
  local session_id
  session_id=$(echo "$checkpoint" | jq -r '.session_id // empty')
  local repo
  repo=$(echo "$checkpoint" | jq -r '.repo // empty')

  local reply_ctx
  reply_ctx=$(jq -n \
    --arg g "$general" --arg s "$session_id" --arg r "$repo" \
    '{general: $g, session_id: $s, repo: $r}')

  # DM 원본 채널/스레드 정보 추출 (complete_task가 파일 이동 전에 읽기)
  local task
  task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local reply_ch reply_ts
  reply_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  reply_ts=$(echo "$task" | jq -r '.payload.thread_ts // .payload.message_ts // empty')

  local source_ref
  source_ref=$(extract_source_ref "$task")

  # 태스크 완료 (checkpoint에 모든 정보 보존됨)
  complete_task "$task_id"
  rm -f "$BASE_DIR/state/results/${task_id}.json"

  local msg_id
  msg_id=$(next_msg_id)
  local message
  message=$(jq -n \
    --arg id "$msg_id" \
    --arg task_id "$task_id" \
    --arg content "[question] $question" \
    --argjson reply_ctx "$reply_ctx" \
    --argjson sr "$source_ref" \
    --arg ch "$reply_ch" --arg ts "$reply_ts" \
    '{
      id: $id,
      type: "human_input_request",
      task_id: $task_id,
      content: $content,
      reply_context: $reply_ctx,
      source_ref: $sr,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    } + (if $ch != "" then {channel: $ch} else {} end)
      + (if $ts != "" then {thread_ts: $ts} else {} end)')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
  log "[EVENT] [king] Needs human input: $task_id (completed, reply_context included)"
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
  local notify_ch
  notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
  local task_type
  task_type=$(echo "$task" | jq -r '.type // empty')
  local payload
  payload=$(echo "$task" | jq -c '.payload // {}')
  local task_repo
  task_repo=$(echo "$task" | jq -r '.repo // empty')
  if [[ -n "$task_repo" ]]; then
    payload=$(echo "$payload" | jq --arg r "$task_repo" '.repo //= $r')
  fi
  local ctx
  ctx=$(format_task_context "$task_type" "$payload")
  local source_ref
  source_ref=$(extract_source_ref "$task")
  local notif_content
  if [[ -n "$ctx" ]]; then
    notif_content=$(printf '⏭️ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$reason")
  else
    notif_content=$(printf '⏭️ *%s* | %s\n%s' "$general" "$task_id" "$reason")
  fi
  create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref"

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

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

# --- DM Petition Helpers (상소 심의) ---

handle_direct_response() {
  local event="$1" event_file="$2" response="$3"
  local channel
  channel=$(echo "$event" | jq -r '.payload.channel // empty')
  local message_ts
  message_ts=$(echo "$event" | jq -r '.payload.message_ts // empty')
  local event_id
  event_id=$(echo "$event" | jq -r '.id')

  if [[ -n "$channel" && -n "$message_ts" ]]; then
    local msg_id
    msg_id=$(next_msg_id)
    local source_ref
    source_ref=$(jq -n --arg ch "$channel" --arg ts "$message_ts" '{channel: $ch, message_ts: $ts}')
    local message
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$event_id" \
      --arg ch "$channel" --arg ts "$message_ts" --arg ct "$response" \
      --argjson sr "$source_ref" \
      '{ id: $id, type: "thread_reply", task_id: $task, channel: $ch,
         thread_ts: $ts, content: $ct, track_conversation: null, source_ref: $sr,
         created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
    write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
  fi

  mv "$event_file" "$BASE_DIR/queue/events/completed/"
  log "[EVENT] [king] Petition direct response for: $event_id"
}

handle_unroutable_dm() {
  local event="$1" event_file="$2"
  local channel
  channel=$(echo "$event" | jq -r '.payload.channel // empty')
  local message_ts
  message_ts=$(echo "$event" | jq -r '.payload.message_ts // empty')
  local event_id
  event_id=$(echo "$event" | jq -r '.id')

  local msg_id
  msg_id=$(next_msg_id)
  local content="현재 이 요청을 처리할 수 있는 전문가가 없습니다. GitHub PR이나 Jira 티켓 관련 요청이라면 해당 시스템에서 직접 이벤트가 생성됩니다."

  if [[ -n "$channel" && -n "$message_ts" ]]; then
    local message
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$event_id" \
      --arg ch "$channel" --arg ts "$message_ts" --arg ct "$content" \
      '{ id: $id, type: "thread_reply", task_id: $task, channel: $ch,
         thread_ts: $ts, content: $ct, track_conversation: null,
         created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
    write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
  fi

  mv "$event_file" "$BASE_DIR/queue/events/completed/"
  log "[EVENT] [king] Unroutable DM, replied with guidance: $event_id"
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
  local repo="${5:-}"
  local task_id
  task_id=$(next_task_id)

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

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"

  create_thread_start_message "$task_id" "$general" \
    "$(jq -n --arg t "$task_type" --argjson r "$repo_arg" '{type: ("schedule." + $t), repo: $r}')"
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
        log "[WARN] [king] Skipping schedule '$sched_name': resource $health"
        continue
      fi

      local repo
      repo=$(echo "$sched_json" | jq -r '.repo // empty')
      dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload" "$repo"
      mark_triggered "$sched_name"
      log "[EVENT] [king] Scheduled task triggered: $sched_name -> $general"
    fi
  done
}

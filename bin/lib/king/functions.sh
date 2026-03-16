#!/usr/bin/env bash
# King Functions — all king logic extracted for testability
# Source this file to get king functions without starting the main loop.
KING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$KING_LIB_DIR/../runtime/engine.sh"
source "$KING_LIB_DIR/messages.sh"
source "$KING_LIB_DIR/schedules.sh"

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

    if [ "$event_type" = "slack.channel.message" ] || [ "$event_type" = "slack.app_mention" ]; then
      # DM 메시지 -> 상소 심의 (petition) 비동기 처리로 위임
      local petition_enabled
      petition_enabled=$(get_config "king" "petition.enabled" "true")
      local message_text
      message_text=$(echo "$event" | jq -r '.payload.text // empty')

      if [[ "$petition_enabled" = "true" && -n "$message_text" ]]; then
        move_file_to_dir "$event_file" "$PETITIONING_DIR/" || return 1
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
        emit_internal_event "event.discarded" "king" \
          "$(jq -n -c --arg eid "$event_id" --arg et "$event_type" --arg reason "no_general" \
            '{event_id: $eid, event_type: $et, reason: $reason}')"
        move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
        continue
      fi
    fi

    local runtime_engine
    runtime_engine=$(get_runtime_engine)
    if ! general_supports_engine "$general" "$runtime_engine"; then
      log "[WARN] [king] General '$general' does not support runtime engine '$runtime_engine', discarding: $event_id"
      move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
      continue
    fi

    # 4. Dispatch task
    if ! dispatch_new_task "$event" "$general" "$event_file"; then
      log "[ERROR] [king] Failed to dispatch event: $event_id"
    fi
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

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task" || return 1
  create_thread_start_message "$task_id" "$general" "$event" || return 1
  move_file_to_dir "$event_file" "$BASE_DIR/queue/events/dispatched/" || return 1
  emit_internal_event "event.dispatched" "king" \
    "$(jq -n -c --arg eid "$event_id" --arg tid "$task_id" --arg tg "$general" \
      '{event_id: $eid, task_id: $tid, target_general: $tg}')"
  emit_internal_event "task.created" "king" \
    "$(jq -n -c --arg tid "$task_id" --arg et "$event_type" --arg tg "$general" --arg p "$priority" \
      '{task_id: $tid, event_type: $et, target_general: $tg, priority: $p}')"

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
    move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
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

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task" || return 1
  move_file_to_dir "$event_file" "$BASE_DIR/queue/events/dispatched/" || return 1
  emit_internal_event "task.resumed" "king" \
    "$(jq -n -c --arg tid "$task_id" --arg oid "$event_id" \
      '{task_id: $tid, original_task_id: $oid}')"
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
    write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message" || return 1
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
    create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref" || return 1
  fi

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg" || return 1
  fi

  complete_task "$task_id"
  emit_internal_event "task.completed" "$general" \
    "$(jq -n -c --arg tid "$task_id" --arg st "success" '{task_id: $tid, status: $st}')"

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
  create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref" || return 1

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg" || return 1
  fi

  complete_task "$task_id"
  emit_internal_event "task.failed" "$general" \
    "$(jq -n -c --arg tid "$task_id" --arg err "$error" '{task_id: $tid, error: $err}')"

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

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message" || return 1
  complete_task "$task_id"
  emit_internal_event "task.needs_human" "$general" \
    "$(jq -n -c --arg tid "$task_id" --arg q "$question" '{task_id: $tid, question: $q}')"
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
  create_notification_message "$task_id" "$notif_content" "$notify_ch" "$source_ref" || return 1

  # Proclamation: 별도 채널 공표
  local proc_ch proc_msg
  proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg" || return 1
  fi

  complete_task "$task_id"
  emit_internal_event "task.completed" "$general" \
    "$(jq -n -c --arg tid "$task_id" --arg st "skipped" --arg rs "$reason" \
      '{task_id: $tid, status: $st, reason: $rs}')"

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

    move_file_to_dir "$task_file" "$BASE_DIR/queue/tasks/completed/" || return 1

    local event_file="$BASE_DIR/queue/events/dispatched/${event_id}.json"
    if [ -f "$event_file" ]; then
      move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
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

  move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
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

  move_file_to_dir "$event_file" "$BASE_DIR/queue/events/completed/" || return 1
  log "[EVENT] [king] Unroutable DM, replied with guidance: $event_id"
}

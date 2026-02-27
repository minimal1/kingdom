#!/usr/bin/env bash
# Kingdom Envoy - Slack Communication Manager
# Slack으로 메시지 발송 + 사람 응답 수집 + DM 인바운드 + 대화 스레드 추적

set -uo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/envoy/slack-api.sh"
source "$BASE_DIR/bin/lib/envoy/thread-manager.sh"

RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [envoy] Shutting down..."; exit 0' SIGTERM SIGINT

LAST_OUTBOUND=0
LAST_THREAD_CHECK=0
LAST_CHANNEL_CHECK=0
LAST_CONV_CHECK=0
OUTBOUND_INTERVAL=$(get_config "envoy" "intervals.outbound_seconds" "5")
THREAD_CHECK_INTERVAL=$(get_config "envoy" "intervals.thread_check_seconds" "30")
CHANNEL_CHECK_INTERVAL=$(get_config "envoy" "intervals.channel_check_seconds" "30")
CONV_CHECK_INTERVAL=$(get_config "envoy" "intervals.conversation_check_seconds" "15")
CONV_TTL=$(get_config "envoy" "intervals.conversation_ttl_seconds" "3600")

DEFAULT_CHANNEL="${SLACK_DEFAULT_CHANNEL:-$(get_config "envoy" "slack.default_channel")}"

# DM 채널 ID 확보 (User ID → DM channel ID 변환)
CHANNEL_FOR_HISTORY=""
if [[ "$DEFAULT_CHANNEL" == U* ]]; then
  DM_RESP=$(slack_api "conversations.open" \
    "$(jq -n --arg u "$DEFAULT_CHANNEL" '{users: $u}')" 2>/dev/null) || true
  if [[ -n "$DM_RESP" ]]; then
    CHANNEL_FOR_HISTORY=$(echo "$DM_RESP" | jq -r '.channel.id // empty')
  fi
elif [[ "$DEFAULT_CHANNEL" == D* ]]; then
  CHANNEL_FOR_HISTORY="$DEFAULT_CHANNEL"
fi

log "[SYSTEM] [envoy] Started. channel_for_history=${CHANNEL_FOR_HISTORY:-none}"

# --- Message Processors ---

process_thread_start() {
  local msg="$1"
  local task_id channel content
  task_id=$(echo "$msg" | jq -r '.task_id')
  channel=$(echo "$msg" | jq -r '.channel // "'"$DEFAULT_CHANNEL"'"')
  content=$(echo "$msg" | jq -r '.content')

  local response
  response=$(send_message "$channel" "$content") || return 1
  local thread_ts
  thread_ts=$(echo "$response" | jq -r '.ts')

  # API 응답의 실제 channel ID 사용 (DM일 때 D-prefixed ID 반환)
  local actual_channel
  actual_channel=$(echo "$response" | jq -r '.channel // "'"$channel"'"')

  save_thread_mapping "$task_id" "$thread_ts" "$actual_channel"
  emit_internal_event "message.sent" "envoy" \
    "$(jq -n -c --arg mid "$(echo "$msg" | jq -r '.id')" --arg tid "$task_id" --arg ch "$actual_channel" \
      '{msg_id: $mid, task_id: $tid, channel: $ch}')"
  log "[EVENT] [envoy] Thread started for task: $task_id"
}

process_thread_update() {
  local msg="$1"
  local task_id content
  task_id=$(echo "$msg" | jq -r '.task_id')
  content=$(echo "$msg" | jq -r '.content')
  local mapping
  mapping=$(get_thread_mapping "$task_id")

  if [[ -n "$mapping" ]]; then
    local thread_ts channel
    thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
    channel=$(echo "$mapping" | jq -r '.channel')
    send_thread_reply "$channel" "$thread_ts" "$content" || return 1
  else
    log "[WARN] [envoy] No thread mapping for task: $task_id (thread_update)"
  fi
}

process_human_input_request() {
  local msg="$1"
  local task_id content
  task_id=$(echo "$msg" | jq -r '.task_id')
  content=$(echo "$msg" | jq -r '.content')
  local reply_ctx
  reply_ctx=$(echo "$msg" | jq -c '.reply_context // {}')
  local mapping
  mapping=$(get_thread_mapping "$task_id")

  if [[ -n "$mapping" ]]; then
    local thread_ts channel
    thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
    channel=$(echo "$mapping" | jq -r '.channel')
    send_thread_reply "$channel" "$thread_ts" "$content" || return 1
    add_awaiting_response "$task_id" "$thread_ts" "$channel" "$reply_ctx"
    log "[EVENT] [envoy] Human input requested for task: $task_id"
  else
    # DM 원본: 메시지에 channel/thread_ts가 직접 포함된 경우 (thread_mapping 없이)
    local msg_ch msg_ts
    msg_ch=$(echo "$msg" | jq -r '.channel // empty')
    msg_ts=$(echo "$msg" | jq -r '.thread_ts // empty')
    if [[ -n "$msg_ch" && -n "$msg_ts" ]]; then
      send_thread_reply "$msg_ch" "$msg_ts" "$content" || return 1
      add_awaiting_response "$task_id" "$msg_ts" "$msg_ch" "$reply_ctx"
      log "[EVENT] [envoy] Human input requested for task: $task_id (DM fallback)"
    else
      log "[WARN] [envoy] No thread mapping for task: $task_id (human_input_request)"
    fi
  fi
}

process_thread_reply_msg() {
  local msg="$1"
  local channel thread_ts content task_id
  channel=$(echo "$msg" | jq -r '.channel')
  thread_ts=$(echo "$msg" | jq -r '.thread_ts')
  content=$(echo "$msg" | jq -r '.content')
  task_id=$(echo "$msg" | jq -r '.task_id')

  local reply_response
  reply_response=$(send_thread_reply "$channel" "$thread_ts" "$content") || return 1
  local bot_reply_ts
  bot_reply_ts=$(echo "$reply_response" | jq -r '.ts // empty')

  # 대화 추적 등록 (track_conversation이 있을 때)
  local track
  track=$(echo "$msg" | jq -r '.track_conversation // empty')
  if [[ -n "$track" && "$track" != "null" ]]; then
    local reply_ctx
    reply_ctx=$(echo "$msg" | jq -c '.track_conversation.reply_context // {}')
    local ttl
    ttl=$(echo "$msg" | jq -r '.track_conversation.ttl_seconds // "'"$CONV_TTL"'"')
    save_conversation_thread "$thread_ts" "$task_id" "$channel" "$reply_ctx" "$ttl" "$bot_reply_ts"
    log "[EVENT] [envoy] Conversation tracked for thread: $thread_ts"
  fi

  save_thread_mapping "$task_id" "$thread_ts" "$channel"
}

process_notification() {
  local msg="$1"
  local task_id content
  task_id=$(echo "$msg" | jq -r '.task_id // empty')
  content=$(echo "$msg" | jq -r '.content')

  if [[ -n "$task_id" ]]; then
    local mapping
    mapping=$(get_thread_mapping "$task_id")
    if [[ -n "$mapping" ]]; then
      local thread_ts channel
      thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
      channel=$(echo "$mapping" | jq -r '.channel')
      send_thread_reply "$channel" "$thread_ts" "$content" || return 1

      if echo "$content" | grep -qE '^(✅|❌|⏭️)'; then
        remove_thread_mapping "$task_id"
        remove_awaiting_response "$task_id"
        log "[EVENT] [envoy] Thread closed for task: $task_id"
      fi
    else
      local channel
      channel=$(echo "$msg" | jq -r '.channel // "'"$DEFAULT_CHANNEL"'"')
      send_message "$channel" "$content" || return 1
      log "[WARN] [envoy] No thread mapping for task: $task_id, sent to channel"
    fi
  else
    local channel
    channel=$(echo "$msg" | jq -r '.channel // "'"$DEFAULT_CHANNEL"'"')
    send_message "$channel" "$content" || return 1
  fi
}

process_report() {
  local msg="$1"
  local channel content
  channel=$(echo "$msg" | jq -r '.channel // "'"$DEFAULT_CHANNEL"'"')
  content=$(echo "$msg" | jq -r '.content')
  send_message "$channel" "$content" || return 1
  log "[EVENT] [envoy] Report sent"
}

# --- Outbound Queue Processing ---

MAX_RETRY_COUNT=$(get_config "envoy" "retry.max_count" "3")

process_outbound_queue() {
  local pending_dir="$BASE_DIR/queue/messages/pending"
  local sent_dir="$BASE_DIR/queue/messages/sent"
  local failed_dir="$BASE_DIR/queue/messages/failed"
  mkdir -p "$failed_dir"

  for msg_file in "$pending_dir"/*.json; do
    [[ -f "$msg_file" ]] || continue

    local msg msg_type
    msg=$(cat "$msg_file")
    msg_type=$(echo "$msg" | jq -r '.type')

    local send_ok=true
    case "$msg_type" in
      thread_start)        process_thread_start "$msg" || send_ok=false ;;
      thread_update)       process_thread_update "$msg" || send_ok=false ;;
      thread_reply)        process_thread_reply_msg "$msg" || send_ok=false ;;
      human_input_request) process_human_input_request "$msg" || send_ok=false ;;
      notification)        process_notification "$msg" || send_ok=false ;;
      report)              process_report "$msg" || send_ok=false ;;
      *)                   log "[EVENT] [envoy] Unknown message type: $msg_type" ;;
    esac

    if $send_ok; then
      mv "$msg_file" "$sent_dir/"
    else
      # Increment retry count and check limit
      local retry_count
      retry_count=$(echo "$msg" | jq -r '.retry_count // 0')
      retry_count=$((retry_count + 1))

      if (( retry_count >= MAX_RETRY_COUNT )); then
        log "[ERROR] [envoy] Message permanently failed after $retry_count retries: $(basename "$msg_file")"
        mv "$msg_file" "$failed_dir/"
      else
        # Update retry count in-place for next attempt
        echo "$msg" | jq --argjson rc "$retry_count" '.retry_count = $rc' > "${msg_file}.tmp"
        mv "${msg_file}.tmp" "$msg_file"
        log "[WARN] [envoy] Message send failed (retry $retry_count/$MAX_RETRY_COUNT): $(basename "$msg_file")"
      fi
    fi
  done
}

# --- Inbound: DM Channel Messages ---

check_channel_messages() {
  [[ -n "$CHANNEL_FOR_HISTORY" ]] || return 0
  local last_ts
  last_ts=$(cat "$BASE_DIR/state/envoy/last-channel-check-ts" 2>/dev/null || echo "0")
  local response
  response=$(read_channel_messages "$CHANNEL_FOR_HISTORY" "$last_ts") || return 0

  echo "$response" | jq -c '
    .messages[]? | select(.bot_id == null and .subtype == null
      and (.thread_ts == null or .thread_ts == .ts))
  ' 2>/dev/null | while IFS= read -r msg; do
    local msg_ts msg_user msg_text
    msg_ts=$(echo "$msg" | jq -r '.ts')
    msg_user=$(echo "$msg" | jq -r '.user // empty')
    msg_text=$(echo "$msg" | jq -r '.text // empty')
    [[ -z "$msg_text" ]] && continue

    local event_id="evt-slack-msg-$(echo "$msg_ts" | tr '.' '-')"
    local event
    event=$(jq -n \
      --arg id "$event_id" --arg text "$msg_text" \
      --arg user_id "$msg_user" --arg channel "$CHANNEL_FOR_HISTORY" \
      --arg message_ts "$msg_ts" \
      '{ id: $id, type: "slack.channel.message", source: "slack", repo: null,
         payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
         priority: "normal",
         created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
    emit_event "$event"
    log "[EVENT] [envoy] DM message detected: $event_id"
  done

  # 최대 ts 갱신
  local new_max
  new_max=$(echo "$response" | jq -r '[.messages[]?.ts // empty] | map(tonumber) | max // empty' 2>/dev/null)
  if [[ -n "$new_max" && "$new_max" != "null" ]]; then
    echo "$new_max" > "$BASE_DIR/state/envoy/last-channel-check-ts"
  fi
}

# --- Inbound: Awaiting Responses (needs_human) ---

check_awaiting_responses() {
  [[ -f "$AWAITING_FILE" ]] || return 0
  local count
  count=$(jq 'length' "$AWAITING_FILE")
  [[ "$count" -gt 0 ]] || return 0

  jq -c '.[]' "$AWAITING_FILE" | while read -r entry; do
    local task_id thread_ts channel asked_at reply_ctx
    task_id=$(echo "$entry" | jq -r '.task_id')
    thread_ts=$(echo "$entry" | jq -r '.thread_ts')
    channel=$(echo "$entry" | jq -r '.channel')
    asked_at=$(echo "$entry" | jq -r '.asked_at')
    reply_ctx=$(echo "$entry" | jq '.reply_context // {}')

    local replies
    replies=$(read_thread_replies "$channel" "$thread_ts" "$asked_at") || continue

    local human_reply
    human_reply=$(echo "$replies" | jq -r \
      '.messages[]? | select(.bot_id == null and .ts != "'"$thread_ts"'") | .text' | head -1)

    if [[ -n "$human_reply" ]]; then
      local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
      local event
      event=$(jq -n \
        --arg id "$event_id" --arg text "$human_reply" \
        --arg channel "$channel" --arg thread_ts "$thread_ts" \
        --argjson reply_ctx "$reply_ctx" \
        '{ id: $id, type: "slack.thread.reply", source: "slack",
           payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                      reply_context: $reply_ctx },
           priority: "high",
           created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')

      emit_event "$event"
      remove_awaiting_response "$task_id"
      log "[EVENT] [envoy] Human responded (awaiting): $task_id"
    fi
  done
}

# --- Inbound: Conversation Threads (멀티턴 대화) ---

is_macos() {
  [[ "$(uname)" == "Darwin" ]]
}

check_conversation_threads() {
  [[ -f "$CONV_FILE" ]] || return 0
  local count
  count=$(jq 'length' "$CONV_FILE" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0
  local now_epoch
  now_epoch=$(date +%s)

  jq -c 'to_entries[]' "$CONV_FILE" | while IFS= read -r entry; do
    local thread_ts data channel last_reply_ts expires_at reply_ctx
    thread_ts=$(echo "$entry" | jq -r '.key')
    data=$(echo "$entry" | jq '.value')
    channel=$(echo "$data" | jq -r '.channel')
    last_reply_ts=$(echo "$data" | jq -r '.last_reply_ts')
    expires_at=$(echo "$data" | jq -r '.expires_at')
    reply_ctx=$(echo "$data" | jq '.reply_context // {}')

    # TTL 체크
    local expires_epoch
    if is_macos; then
      expires_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || echo 0)
    else
      expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo 0)
    fi
    if (( now_epoch > expires_epoch )); then
      remove_conversation_thread "$thread_ts"
      log "[EVENT] [envoy] Conversation expired: $thread_ts"
      continue
    fi

    local replies
    replies=$(read_thread_replies "$channel" "$thread_ts" "$last_reply_ts") || continue

    local human_reply
    human_reply=$(echo "$replies" | jq -r \
      '.messages[]? | select(.bot_id == null and .ts != "'"$thread_ts"'" and .ts != "'"$last_reply_ts"'") | .text' | head -1)

    if [[ -n "$human_reply" ]]; then
      local reply_ts
      reply_ts=$(echo "$replies" | jq -r \
        '.messages[]? | select(.bot_id == null and .ts != "'"$thread_ts"'" and .ts != "'"$last_reply_ts"'") | .ts' | head -1)

      local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
      local event
      event=$(jq -n \
        --arg id "$event_id" --arg text "$human_reply" \
        --arg channel "$channel" --arg thread_ts "$thread_ts" \
        --argjson reply_ctx "$reply_ctx" \
        '{ id: $id, type: "slack.thread.reply", source: "slack",
           payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                      reply_context: $reply_ctx },
           priority: "high",
           created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')

      emit_event "$event"
      update_conversation_thread "$thread_ts" "$reply_ts"
      log "[EVENT] [envoy] Conversation reply detected: $thread_ts"
    fi
  done
}

# --- Main Loop ---

start_heartbeat_daemon "envoy"

while $RUNNING; do
  now=$(date +%s)

  if (( now - LAST_OUTBOUND >= OUTBOUND_INTERVAL )); then
    process_outbound_queue
    LAST_OUTBOUND=$now
  fi

  if (( now - LAST_THREAD_CHECK >= THREAD_CHECK_INTERVAL )); then
    check_awaiting_responses
    LAST_THREAD_CHECK=$now
  fi

  if (( now - LAST_CHANNEL_CHECK >= CHANNEL_CHECK_INTERVAL )); then
    check_channel_messages
    LAST_CHANNEL_CHECK=$now
  fi

  if (( now - LAST_CONV_CHECK >= CONV_CHECK_INTERVAL )); then
    check_conversation_threads
    LAST_CONV_CHECK=$now
  fi

  sleep 5
done

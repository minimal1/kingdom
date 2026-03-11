#!/usr/bin/env bash
# Kingdom Envoy - Slack Communication Manager
# Socket Mode (bridge.js) 또는 레거시 폴링 방식으로 동작
# Slack으로 메시지 발송 + 사람 응답 수집 + DM 인바운드 + 대화 스레드 추적

set -uo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/envoy/thread-manager.sh"

# --- Socket Mode 설정 ---
SOCKET_MODE_ENABLED=$(get_config "envoy" "socket_mode.enabled" "false")
export SOCKET_MODE_ENABLED

# slack-api.sh는 SOCKET_MODE_ENABLED에 따라 outbox/curl 분기
source "$BASE_DIR/bin/lib/envoy/slack-api.sh"

RUNNING=true

# --- Bridge Lifecycle (Socket Mode only) ---

BRIDGE_PID=""

start_bridge() {
  if [[ "$SOCKET_MODE_ENABLED" != "true" ]]; then
    return 0
  fi

  local app_token_env
  app_token_env=$(get_config "envoy" "socket_mode.app_token_env" "SLACK_APP_TOKEN")
  local app_token="${!app_token_env:-}"

  if [[ -z "$app_token" ]]; then
    log "[ERROR] [envoy] $app_token_env not set — Socket Mode disabled"
    SOCKET_MODE_ENABLED="false"
    export SOCKET_MODE_ENABLED
    return 1
  fi

  local bridge_script="$BASE_DIR/bin/lib/envoy/bridge.js"
  if [[ ! -f "$bridge_script" ]]; then
    log "[ERROR] [envoy] bridge.js not found: $bridge_script"
    SOCKET_MODE_ENABLED="false"
    export SOCKET_MODE_ENABLED
    return 1
  fi

  SLACK_APP_TOKEN="$app_token" SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}" \
    KINGDOM_BASE_DIR="$BASE_DIR" \
    node "$bridge_script" &
  BRIDGE_PID=$!
  log "[SYSTEM] [envoy] Bridge started (PID: $BRIDGE_PID)"
}

stop_bridge() {
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    BRIDGE_PID=""
    log "[SYSTEM] [envoy] Bridge stopped"
  fi
}

check_bridge_health() {
  [[ "$SOCKET_MODE_ENABLED" != "true" ]] && return 0
  [[ -z "$BRIDGE_PID" ]] && { start_bridge; return; }

  # Check if process is alive
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    log "[WARN] [envoy] Bridge process dead, restarting..."
    start_bridge
    return
  fi

  # Check health file mtime
  local health_file="$BASE_DIR/state/envoy/bridge-health"
  if [[ -f "$health_file" ]]; then
    local mtime now age
    mtime=$(get_mtime "$health_file")
    now=$(date +%s)
    age=$((now - mtime))
    if (( age > 30 )); then
      log "[WARN] [envoy] Bridge health stale (${age}s), restarting..."
      stop_bridge
      start_bridge
    fi
  fi
}

# --- Graceful Shutdown ---
trap 'RUNNING=false; stop_bridge; stop_heartbeat_daemon; rm -f /tmp/kingdom-wake-$$.fifo; log "[SYSTEM] [envoy] Shutting down..."; exit 0' SIGTERM SIGINT

# --- Timers ---
LAST_OUTBOUND=0
LAST_THREAD_CHECK=0
LAST_CHANNEL_CHECK=0
LAST_CONV_CHECK=0
LAST_CONV_EXPIRE=0
LAST_BRIDGE_CHECK=0
OUTBOUND_INTERVAL=$(get_config "envoy" "intervals.outbound_seconds" "5")
THREAD_CHECK_INTERVAL=$(get_config "envoy" "intervals.thread_check_seconds" "30")
CHANNEL_CHECK_INTERVAL=$(get_config "envoy" "intervals.channel_check_seconds" "30")
CONV_CHECK_INTERVAL=$(get_config "envoy" "intervals.conversation_check_seconds" "15")
CONV_TTL=$(get_config "envoy" "intervals.conversation_ttl_seconds" "3600")

DEFAULT_CHANNEL="${SLACK_DEFAULT_CHANNEL:-$(get_config "envoy" "slack.default_channel")}"

# --- Legacy: DM 채널 ID 확보 (Socket Mode 비활성 시만) ---
CHANNEL_FOR_HISTORY=""
if [[ "$SOCKET_MODE_ENABLED" != "true" ]]; then
  if [[ "$DEFAULT_CHANNEL" == U* ]]; then
    DM_RESP=$(slack_api "conversations.open" \
      "$(jq -n --arg u "$DEFAULT_CHANNEL" '{users: $u}')" 2>/dev/null) || true
    if [[ -n "$DM_RESP" ]]; then
      CHANNEL_FOR_HISTORY=$(echo "$DM_RESP" | jq -r '.channel.id // empty')
    fi
  elif [[ "$DEFAULT_CHANNEL" == D* ]]; then
    CHANNEL_FOR_HISTORY="$DEFAULT_CHANNEL"
  fi
fi

# --- Reaction Helper ---

update_source_reactions() {
  local msg="$1" final_emoji="$2"
  local source_ref
  source_ref=$(echo "$msg" | jq -c '.source_ref // empty')
  [[ -z "$source_ref" || "$source_ref" == "null" ]] && return 0

  local src_ch src_ts
  src_ch=$(echo "$source_ref" | jq -r '.channel')
  src_ts=$(echo "$source_ref" | jq -r '.message_ts')

  remove_reaction "$src_ch" "$src_ts" "eyes" || true
  if [[ -n "$final_emoji" ]]; then
    add_reaction "$src_ch" "$src_ts" "$final_emoji" || true
  fi
}

# --- Message Processors ---

process_thread_start() {
  local msg="$1"
  local task_id channel content
  task_id=$(echo "$msg" | jq -r '.task_id')
  channel=$(echo "$msg" | jq -r '.channel // "'"$DEFAULT_CHANNEL"'"')
  content=$(echo "$msg" | jq -r '.content')

  local thread_ts actual_channel
  local existing_ts
  existing_ts=$(echo "$msg" | jq -r '.thread_ts // empty')

  if [[ -n "$existing_ts" ]]; then
    # DM 경로: 기존 메시지를 스레드 부모로 재사용 (새 메시지 불필요)
    thread_ts="$existing_ts"
    actual_channel="$channel"
    send_thread_reply "$channel" "$thread_ts" "$content" || return 1
  else
    # 일반 경로: 새 채널 메시지 생성
    local response
    response=$(send_message "$channel" "$content") || return 1
    thread_ts=$(echo "$response" | jq -r '.ts')
    # API 응답의 실제 channel ID 사용 (DM일 때 D-prefixed ID 반환)
    actual_channel=$(echo "$response" | jq -r '.channel // "'"$channel"'"')
  fi

  save_thread_mapping "$task_id" "$thread_ts" "$actual_channel"
  add_reaction "$actual_channel" "$thread_ts" "eyes" || true
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
    update_source_reactions "$msg" "raising_hand"
    log "[EVENT] [envoy] Human input requested for task: $task_id"
  else
    # DM 원본: 메시지에 channel/thread_ts가 직접 포함된 경우 (thread_mapping 없이)
    local msg_ch msg_ts
    msg_ch=$(echo "$msg" | jq -r '.channel // empty')
    msg_ts=$(echo "$msg" | jq -r '.thread_ts // empty')
    if [[ -n "$msg_ch" && -n "$msg_ts" ]]; then
      send_thread_reply "$msg_ch" "$msg_ts" "$content" || return 1
      add_awaiting_response "$task_id" "$msg_ts" "$msg_ch" "$reply_ctx"
      update_source_reactions "$msg" "raising_hand"
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

  update_source_reactions "$msg" "white_check_mark"
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
        # 스레드 부모 메시지 리액션 업데이트
        remove_reaction "$channel" "$thread_ts" "eyes" || true
        if echo "$content" | grep -q '^✅'; then
          add_reaction "$channel" "$thread_ts" "white_check_mark" || true
        elif echo "$content" | grep -q '^❌'; then
          add_reaction "$channel" "$thread_ts" "x" || true
        fi

        remove_thread_mapping "$task_id"
        remove_awaiting_response "$task_id"
        # 원본 DM에 최종 리액션 업데이트
        if echo "$content" | grep -q '^✅'; then
          update_source_reactions "$msg" "white_check_mark"
        elif echo "$content" | grep -q '^❌'; then
          update_source_reactions "$msg" "x"
        else
          update_source_reactions "$msg" ""
        fi
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

# --- Inbound: Socket Mode (socket-inbox 파일 처리) ---

check_socket_inbox() {
  local inbox_dir="$BASE_DIR/state/envoy/socket-inbox"
  [[ -d "$inbox_dir" ]] || return 0

  for inbox_file in "$inbox_dir"/*.json; do
    [[ -f "$inbox_file" ]] || continue

    local event
    event=$(cat "$inbox_file")
    local type
    type=$(echo "$event" | jq -r '.type')
    local channel user_id text ts thread_ts event_ts
    channel=$(echo "$event" | jq -r '.channel')
    user_id=$(echo "$event" | jq -r '.user_id')
    text=$(echo "$event" | jq -r '.text')
    ts=$(echo "$event" | jq -r '.ts')
    thread_ts=$(echo "$event" | jq -r '.thread_ts // empty')
    event_ts=$(echo "$event" | jq -r '.event_ts')

    case "$type" in
      message)
        # DM top-level message → slack.channel.message 이벤트
        local event_id="evt-slack-msg-$(echo "$ts" | tr '.' '-')"
        local evt
        evt=$(jq -n \
          --arg id "$event_id" --arg text "$text" \
          --arg user_id "$user_id" --arg channel "$channel" \
          --arg message_ts "$ts" \
          '{ id: $id, type: "slack.channel.message", source: "slack", repo: null,
             payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
             priority: "normal",
             created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
        add_reaction "$channel" "$ts" "eyes" || true
        emit_event "$evt"
        log "[EVENT] [envoy] DM message (socket): $event_id"
        ;;

      app_mention)
        # @멘션 → slack.app_mention 이벤트
        local event_id="evt-slack-mention-$(echo "$ts" | tr '.' '-')"
        local evt
        evt=$(jq -n \
          --arg id "$event_id" --arg text "$text" \
          --arg user_id "$user_id" --arg channel "$channel" \
          --arg message_ts "$ts" \
          '{ id: $id, type: "slack.app_mention", source: "slack", repo: null,
             payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
             priority: "normal",
             created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
        add_reaction "$channel" "$ts" "eyes" || true
        emit_event "$evt"
        log "[EVENT] [envoy] App mention (socket): $event_id"
        ;;

      thread_reply)
        # 스레드 응답 → awaiting/conversation 매칭 확인
        [[ -n "$thread_ts" ]] || { rm -f "$inbox_file"; continue; }

        local matched=false

        # Check awaiting-responses.json
        if [[ -f "$AWAITING_FILE" ]]; then
          local awaiting_match
          awaiting_match=$(jq -r --arg tts "$thread_ts" \
            '.[] | select(.thread_ts == $tts) | .task_id' "$AWAITING_FILE" 2>/dev/null | head -1)
          if [[ -n "$awaiting_match" ]]; then
            local reply_ctx
            reply_ctx=$(jq --arg tts "$thread_ts" \
              '.[] | select(.thread_ts == $tts) | .reply_context // {}' "$AWAITING_FILE" 2>/dev/null | head -1)
            [[ -z "$reply_ctx" || "$reply_ctx" == "null" ]] && reply_ctx='{}'
            local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
            local evt
            evt=$(jq -n \
              --arg id "$event_id" --arg text "$text" \
              --arg channel "$channel" --arg thread_ts "$thread_ts" \
              --argjson reply_ctx "$reply_ctx" \
              '{ id: $id, type: "slack.thread.reply", source: "slack",
                 payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                            reply_context: $reply_ctx },
                 priority: "high",
                 created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
            emit_event "$evt"
            remove_awaiting_response "$awaiting_match"
            log "[EVENT] [envoy] Thread reply (awaiting, socket): $awaiting_match"
            matched=true
          fi
        fi

        # Check conversation-threads.json
        if [[ "$matched" != "true" && -f "$CONV_FILE" ]]; then
          local conv_match
          conv_match=$(jq -r --arg tts "$thread_ts" '.[$tts] // empty' "$CONV_FILE" 2>/dev/null)
          if [[ -n "$conv_match" ]]; then
            local reply_ctx
            reply_ctx=$(echo "$conv_match" | jq '.reply_context // {}')
            local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
            local evt
            evt=$(jq -n \
              --arg id "$event_id" --arg text "$text" \
              --arg channel "$channel" --arg thread_ts "$thread_ts" \
              --argjson reply_ctx "$reply_ctx" \
              '{ id: $id, type: "slack.thread.reply", source: "slack",
                 payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                            reply_context: $reply_ctx },
                 priority: "high",
                 created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
            emit_event "$evt"
            update_conversation_thread "$thread_ts" "$ts"
            log "[EVENT] [envoy] Thread reply (conversation, socket): $thread_ts"
            matched=true
          fi
        fi

        if [[ "$matched" != "true" ]]; then
          log "[DEBUG] [envoy] Unmatched thread reply ignored: $thread_ts"
        fi
        ;;

      *)
        log "[WARN] [envoy] Unknown socket-inbox type: $type"
        ;;
    esac

    rm -f "$inbox_file"
  done
}

# --- Inbound: Legacy polling (Socket Mode 비활성 시) ---

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
    add_reaction "$CHANNEL_FOR_HISTORY" "$msg_ts" "eyes" || true
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

# --- Conversation TTL Expiry (Socket Mode: Slack API 호출 없이 시계만 확인) ---

expire_conversations() {
  [[ -f "$CONV_FILE" ]] || return 0
  local count
  count=$(jq 'length' "$CONV_FILE" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0
  local now_epoch
  now_epoch=$(date +%s)

  jq -c 'to_entries[]' "$CONV_FILE" | while IFS= read -r entry; do
    local thread_ts expires_at
    thread_ts=$(echo "$entry" | jq -r '.key')
    expires_at=$(echo "$entry" | jq -r '.value.expires_at')

    local expires_epoch
    if is_macos; then
      expires_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || echo 0)
    else
      expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo 0)
    fi
    if (( now_epoch > expires_epoch )); then
      remove_conversation_thread "$thread_ts"
      log "[EVENT] [envoy] Conversation expired: $thread_ts"
    fi
  done
}

# --- Main Loop ---

log "[SYSTEM] [envoy] Started. socket_mode=$SOCKET_MODE_ENABLED channel_for_history=${CHANNEL_FOR_HISTORY:-none}"

start_heartbeat_daemon "envoy"

# Start bridge if Socket Mode enabled
if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
  start_bridge
fi

while $RUNNING; do
  now=$(date +%s)

  # Socket Mode: socket-inbox 처리
  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    check_socket_inbox
  fi

  # 아웃바운드: 메시지 큐 소비
  if (( now - LAST_OUTBOUND >= OUTBOUND_INTERVAL )); then
    process_outbound_queue
    LAST_OUTBOUND=$now
  fi

  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    # Socket Mode: TTL 만료 정리 (60초마다, Slack API 무관)
    if (( now - LAST_CONV_EXPIRE >= 60 )); then
      expire_conversations
      LAST_CONV_EXPIRE=$now
    fi

    # Socket Mode: 브릿지 생존 확인 (30초마다)
    if (( now - LAST_BRIDGE_CHECK >= 30 )); then
      check_bridge_health
      LAST_BRIDGE_CHECK=$now
    fi
  else
    # Legacy: polling 기반 인바운드
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
  fi

  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    sleep_or_wake 5 "$BASE_DIR/state/envoy/socket-inbox"
  else
    sleep_or_wake 5 "$BASE_DIR/queue/messages/pending"
  fi
done

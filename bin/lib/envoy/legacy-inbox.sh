#!/usr/bin/env bash
# Envoy legacy polling inbox processing

envoy_is_macos() {
  [[ "$(uname)" == "Darwin" ]]
}

resolve_history_channel() {
  CHANNEL_FOR_HISTORY=""
  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    return 0
  fi

  if [[ "$DEFAULT_CHANNEL" == U* ]]; then
    DM_RESP=$(slack_api "conversations.open" \
      "$(jq -n --arg u "$DEFAULT_CHANNEL" '{users: $u}')" 2>/dev/null) || true
    if [[ -n "$DM_RESP" ]]; then
      CHANNEL_FOR_HISTORY=$(echo "$DM_RESP" | jq -r '.channel.id // empty')
    fi
  elif [[ "$DEFAULT_CHANNEL" == D* ]]; then
    CHANNEL_FOR_HISTORY="$DEFAULT_CHANNEL"
  fi
}

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

    local event_id
    event_id=$(emit_socket_message_event "slack.channel.message" "evt-slack-msg" "$CHANNEL_FOR_HISTORY" "$msg_user" "$msg_text" "$msg_ts")
    log "[EVENT] [envoy] DM message detected: $event_id"
  done

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
      emit_thread_reply_event "$human_reply" "$channel" "$thread_ts" "$reply_ctx"
      remove_awaiting_response "$task_id"
      log "[EVENT] [envoy] Human responded (awaiting): $task_id"
    fi
  done
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

    local expires_epoch
    if envoy_is_macos; then
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

      emit_thread_reply_event "$human_reply" "$channel" "$thread_ts" "$reply_ctx"
      update_conversation_thread "$thread_ts" "$reply_ts"
      log "[EVENT] [envoy] Conversation reply detected: $thread_ts"
    fi
  done
}

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
    if envoy_is_macos; then
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

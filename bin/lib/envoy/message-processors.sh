#!/usr/bin/env bash
# Envoy outbound message processors

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
    thread_ts="$existing_ts"
    actual_channel="$channel"
    send_thread_reply "$channel" "$thread_ts" "$content" || return 1
  else
    local response
    response=$(send_message "$channel" "$content") || return 1
    thread_ts=$(echo "$response" | jq -r '.ts')
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
        remove_reaction "$channel" "$thread_ts" "eyes" || true
        if echo "$content" | grep -q '^✅'; then
          add_reaction "$channel" "$thread_ts" "white_check_mark" || true
        elif echo "$content" | grep -q '^❌'; then
          add_reaction "$channel" "$thread_ts" "x" || true
        fi

        remove_thread_mapping "$task_id"
        remove_awaiting_response "$task_id"
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

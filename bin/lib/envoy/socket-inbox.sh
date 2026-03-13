#!/usr/bin/env bash
# Envoy socket mode inbox processing

emit_socket_message_event() {
  local event_type="$1"
  local id_prefix="$2"
  local channel="$3"
  local user_id="$4"
  local text="$5"
  local ts="$6"
  local event_id="${id_prefix}-$(echo "$ts" | tr '.' '-')"
  local evt

  evt=$(jq -n \
    --arg id "$event_id" --arg text "$text" \
    --arg user_id "$user_id" --arg channel "$channel" \
    --arg message_ts "$ts" --arg type "$event_type" \
    '{ id: $id, type: $type, source: "slack", repo: null,
       payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
       priority: "normal",
       created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
  add_reaction "$channel" "$ts" "eyes" || true
  emit_event "$evt"
  echo "$event_id"
}

emit_thread_reply_event() {
  local text="$1" channel="$2" thread_ts="$3" reply_ctx="$4"
  local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
  local event
  event=$(jq -n \
    --arg id "$event_id" --arg text "$text" \
    --arg channel "$channel" --arg thread_ts "$thread_ts" \
    --argjson reply_ctx "$reply_ctx" \
    '{ id: $id, type: "slack.thread.reply", source: "slack",
       payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                  reply_context: $reply_ctx },
       priority: "high",
       created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
  emit_event "$event"
}

check_socket_inbox() {
  local inbox_dir="$BASE_DIR/state/envoy/socket-inbox"
  [[ -d "$inbox_dir" ]] || return 0

  for inbox_file in "$inbox_dir"/*.json; do
    [[ -f "$inbox_file" ]] || continue

    local event
    event=$(cat "$inbox_file")
    local type channel user_id text ts thread_ts
    type=$(echo "$event" | jq -r '.type')
    channel=$(echo "$event" | jq -r '.channel')
    user_id=$(echo "$event" | jq -r '.user_id')
    text=$(echo "$event" | jq -r '.text')
    ts=$(echo "$event" | jq -r '.ts')
    thread_ts=$(echo "$event" | jq -r '.thread_ts // empty')

    case "$type" in
      message)
        local event_id
        event_id=$(emit_socket_message_event "slack.channel.message" "evt-slack-msg" "$channel" "$user_id" "$text" "$ts")
        log "[EVENT] [envoy] DM message (socket): $event_id"
        ;;
      app_mention)
        local event_id
        event_id=$(emit_socket_message_event "slack.app_mention" "evt-slack-mention" "$channel" "$user_id" "$text" "$ts")
        log "[EVENT] [envoy] App mention (socket): $event_id"
        ;;
      thread_reply)
        [[ -n "$thread_ts" ]] || { rm -f "$inbox_file"; continue; }

        local matched=false
        if [[ -f "$AWAITING_FILE" ]]; then
          local awaiting_match
          awaiting_match=$(jq -r --arg tts "$thread_ts" \
            '.[] | select(.thread_ts == $tts) | .task_id' "$AWAITING_FILE" 2>/dev/null | head -1)
          if [[ -n "$awaiting_match" ]]; then
            local reply_ctx
            reply_ctx=$(jq -c --arg tts "$thread_ts" \
              '.[] | select(.thread_ts == $tts) | .reply_context // {}' "$AWAITING_FILE" 2>/dev/null | head -1)
            [[ -z "$reply_ctx" || "$reply_ctx" == "null" ]] && reply_ctx='{}'
            emit_thread_reply_event "$text" "$channel" "$thread_ts" "$reply_ctx"
            remove_awaiting_response "$awaiting_match"
            log "[EVENT] [envoy] Thread reply (awaiting, socket): $awaiting_match"
            matched=true
          fi
        fi

        if [[ "$matched" != "true" && -f "$CONV_FILE" ]]; then
          local conv_match
          conv_match=$(jq -r --arg tts "$thread_ts" '.[$tts] // empty' "$CONV_FILE" 2>/dev/null)
          if [[ -n "$conv_match" ]]; then
            local reply_ctx
            reply_ctx=$(echo "$conv_match" | jq -c '.reply_context // {}')
            emit_thread_reply_event "$text" "$channel" "$thread_ts" "$reply_ctx"
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

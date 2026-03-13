#!/usr/bin/env bash
# Slack API wrapper functions
# Socket Mode 전용: outbox 파일 기반 (bridge.js가 실제 API 호출)

SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"

# --- Outbox helpers (Socket Mode) ---

_next_outbox_id() {
  printf 'ob-%s-%s-%04d\n' "$$" "$(date +%s)" "$RANDOM"
}

_outbox_send() {
  local action="$1"
  local channel="$2"
  local text="${3:-}"
  local thread_ts="${4:-}"
  local emoji="${5:-}"
  local message_ts="${6:-}"

  local outbox_dir="$BASE_DIR/state/envoy/outbox"
  local results_dir="$BASE_DIR/state/envoy/outbox-results"
  local msg_id
  msg_id=$(_next_outbox_id)

  local outbox_json
  outbox_json=$(jq -n \
    --arg mid "$msg_id" --arg action "$action" \
    --arg channel "$channel" --arg text "$text" \
    --arg thread_ts "$thread_ts" --arg emoji "$emoji" \
    --arg message_ts "$message_ts" \
    '{msg_id: $mid, action: $action, channel: $channel,
      text: $text, thread_ts: $thread_ts,
      emoji: $emoji, message_ts: $message_ts}')

  # Atomic write to outbox
  echo "$outbox_json" > "$outbox_dir/.tmp-${msg_id}.json"
  mv "$outbox_dir/.tmp-${msg_id}.json" "$outbox_dir/${msg_id}.json"

  # Wait for result (100ms x 150 = 15s timeout)
  local attempts=0
  local result_file="$results_dir/${msg_id}.json"
  while [[ ! -f "$result_file" ]] && (( attempts < 150 )); do
    sleep 0.1
    attempts=$((attempts + 1))
  done

  if [[ -f "$result_file" ]]; then
    local result
    result=$(cat "$result_file")
    rm -f "$result_file"

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    if [[ "$ok" != "true" ]]; then
      local error
      error=$(echo "$result" | jq -r '.error // "unknown"')
      log "[ERROR] [envoy] Outbox $action failed: $error"
      return 1
    fi

    echo "$result"
  else
    log "[ERROR] [envoy] Outbox $action timeout: $msg_id"
    return 1
  fi
}

send_message() {
  local channel="$1"
  local text="$2"
  _outbox_send "send_message" "$channel" "$text"
}

send_thread_reply() {
  local channel="$1"
  local thread_ts="$2"
  local text="$3"

  _outbox_send "send_reply" "$channel" "$text" "$thread_ts"
}

add_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"

  _outbox_send "add_reaction" "$channel" "" "" "$emoji" "$timestamp"
}

remove_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"

  _outbox_send "remove_reaction" "$channel" "" "" "$emoji" "$timestamp" || true
}

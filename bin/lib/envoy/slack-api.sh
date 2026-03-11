#!/usr/bin/env bash
# Slack API wrapper functions
# Socket Mode 활성 시: outbox 파일 기반 (bridge.js가 실제 API 호출)
# Socket Mode 비활성 시: curl 직접 호출 (기존 방식)

SLACK_API="https://slack.com/api"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"

# Socket Mode 여부는 envoy.sh에서 SOCKET_MODE_ENABLED 변수로 설정
# 여기서는 기본값 false

# --- Outbox helpers (Socket Mode) ---

_outbox_seq=0

_next_outbox_id() {
  _outbox_seq=$((_outbox_seq + 1))
  echo "ob-$$-${_outbox_seq}"
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

  # Wait for result (100ms x 50 = 5s timeout)
  local attempts=0
  local result_file="$results_dir/${msg_id}.json"
  while [[ ! -f "$result_file" ]] && (( attempts < 50 )); do
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

# --- Legacy curl functions (Socket Mode disabled) ---

_curl_slack_api() {
  local method="$1"
  local data="$2"
  local http_method="${3:-POST}"

  local response
  if [[ "$http_method" == "GET" ]]; then
    local query_string
    query_string=$(echo "$data" | jq -r 'to_entries | map(select(.value | length > 0) | "\(.key)=\(.value | @uri)") | join("&")')
    response=$(curl -s -w "\n%{http_code}" "$SLACK_API/$method?$query_string" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN")
  else
    response=$(curl -s -w "\n%{http_code}" -X POST "$SLACK_API/$method" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data")
  fi

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "429" ]]; then
    local retry_after
    retry_after=$(echo "$body" | jq -r '.retry_after // 30')
    log "[WARN] [envoy] Rate limited. Retry after ${retry_after}s"
    sleep "$retry_after"
    return 1
  elif [[ "$http_code" != "200" ]]; then
    log "[ERROR] [envoy] Slack API $method failed: HTTP $http_code"
    return 1
  fi

  local ok
  ok=$(echo "$body" | jq -r '.ok')
  if [[ "$ok" != "true" ]]; then
    local error
    error=$(echo "$body" | jq -r '.error')
    log "[ERROR] [envoy] Slack API $method error: $error"
    return 1
  fi

  echo "$body"
}

# --- Public API (dispatches based on SOCKET_MODE_ENABLED) ---

slack_api() {
  if [[ "${SOCKET_MODE_ENABLED:-false}" == "true" ]]; then
    log "[WARN] [envoy] slack_api() called in socket mode — use typed functions instead"
    return 1
  fi
  _curl_slack_api "$@"
}

send_message() {
  local channel="$1"
  local text="$2"

  if [[ "${SOCKET_MODE_ENABLED:-false}" == "true" ]]; then
    _outbox_send "send_message" "$channel" "$text"
  else
    _curl_slack_api "chat.postMessage" \
      "$(jq -n --arg c "$channel" --arg t "$text" '{channel: $c, text: $t}')"
  fi
}

send_thread_reply() {
  local channel="$1"
  local thread_ts="$2"
  local text="$3"

  if [[ "${SOCKET_MODE_ENABLED:-false}" == "true" ]]; then
    _outbox_send "send_reply" "$channel" "$text" "$thread_ts"
  else
    _curl_slack_api "chat.postMessage" \
      "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg t "$text" \
        '{channel: $c, thread_ts: $ts, text: $t}')"
  fi
}

read_channel_messages() {
  local channel="$1" oldest="$2"
  # Socket Mode에서는 bridge가 inbox로 직접 전달하므로 이 함수는 레거시 전용
  _curl_slack_api "conversations.history" \
    "$(jq -n --arg c "$channel" --arg o "$oldest" '{channel: $c, oldest: $o, limit: "20"}')" "GET"
}

read_thread_replies() {
  local channel="$1"
  local thread_ts="$2"
  local oldest="$3"
  # Socket Mode에서는 bridge가 inbox로 직접 전달하므로 이 함수는 레거시 전용
  _curl_slack_api "conversations.replies" \
    "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg o "$oldest" \
      '{channel: $c, ts: $ts, oldest: $o, limit: "20"}')" "GET"
}

add_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"

  if [[ "${SOCKET_MODE_ENABLED:-false}" == "true" ]]; then
    _outbox_send "add_reaction" "$channel" "" "" "$emoji" "$timestamp"
  else
    _curl_slack_api "reactions.add" \
      "$(jq -n --arg c "$channel" --arg ts "$timestamp" --arg e "$emoji" \
        '{channel: $c, timestamp: $ts, name: $e}')"
  fi
}

remove_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"

  if [[ "${SOCKET_MODE_ENABLED:-false}" == "true" ]]; then
    _outbox_send "remove_reaction" "$channel" "" "" "$emoji" "$timestamp" || true
  else
    _curl_slack_api "reactions.remove" \
      "$(jq -n --arg c "$channel" --arg ts "$timestamp" --arg e "$emoji" \
        '{channel: $c, timestamp: $ts, name: $e}')" || true
  fi
}

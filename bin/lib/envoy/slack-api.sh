#!/usr/bin/env bash
# Slack API wrapper functions

SLACK_API="https://slack.com/api"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"

slack_api() {
  local method="$1"
  local data="$2"
  local http_method="${3:-POST}"  # POST (default) or GET

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

send_message() {
  local channel="$1"
  local text="$2"
  slack_api "chat.postMessage" \
    "$(jq -n --arg c "$channel" --arg t "$text" '{channel: $c, text: $t}')"
}

send_thread_reply() {
  local channel="$1"
  local thread_ts="$2"
  local text="$3"
  slack_api "chat.postMessage" \
    "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg t "$text" \
      '{channel: $c, thread_ts: $ts, text: $t}')"
}

read_channel_messages() {
  local channel="$1" oldest="$2"
  slack_api "conversations.history" \
    "$(jq -n --arg c "$channel" --arg o "$oldest" '{channel: $c, oldest: $o, limit: "20"}')" "GET"
}

read_thread_replies() {
  local channel="$1"
  local thread_ts="$2"
  local oldest="$3"
  slack_api "conversations.replies" \
    "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg o "$oldest" \
      '{channel: $c, ts: $ts, oldest: $o, limit: "20"}')" "GET"
}

add_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"
  slack_api "reactions.add" \
    "$(jq -n --arg c "$channel" --arg ts "$timestamp" --arg e "$emoji" \
      '{channel: $c, timestamp: $ts, name: $e}')"
}

remove_reaction() {
  local channel="$1" timestamp="$2" emoji="$3"
  slack_api "reactions.remove" \
    "$(jq -n --arg c "$channel" --arg ts "$timestamp" --arg e "$emoji" \
      '{channel: $c, timestamp: $ts, name: $e}')" || true
}

#!/usr/bin/env bash
# Kingdom Envoy - Slack Communication Manager
# Slack으로 메시지 발송 + 사람 응답 수집

set -uo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/envoy/slack-api.sh"
source "$BASE_DIR/bin/lib/envoy/thread-manager.sh"

RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [envoy] Shutting down..."; exit 0' SIGTERM SIGINT

LAST_OUTBOUND=0
LAST_THREAD_CHECK=0
OUTBOUND_INTERVAL=$(get_config "envoy" "intervals.outbound_seconds" "5")
THREAD_CHECK_INTERVAL=$(get_config "envoy" "intervals.thread_check_seconds" "30")

log "[SYSTEM] [envoy] Started."

# --- Message Processors ---

process_thread_start() {
  local msg="$1"
  local task_id channel content
  task_id=$(echo "$msg" | jq -r '.task_id')
  channel=$(echo "$msg" | jq -r '.channel // "'"$(get_config "envoy" "slack.default_channel")"'"')
  content=$(echo "$msg" | jq -r '.content')

  local response
  response=$(send_message "$channel" "$content") || return 1
  local thread_ts
  thread_ts=$(echo "$response" | jq -r '.ts')

  save_thread_mapping "$task_id" "$thread_ts" "$channel"
  emit_internal_event "message.sent" "envoy" \
    "$(jq -n -c --arg mid "$(echo "$msg" | jq -r '.id')" --arg tid "$task_id" --arg ch "$channel" \
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
  local mapping
  mapping=$(get_thread_mapping "$task_id")

  if [[ -n "$mapping" ]]; then
    local thread_ts channel
    thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
    channel=$(echo "$mapping" | jq -r '.channel')
    send_thread_reply "$channel" "$thread_ts" "$content" || return 1
    add_awaiting_response "$task_id" "$thread_ts" "$channel"
    log "[EVENT] [envoy] Human input requested for task: $task_id"
  else
    log "[WARN] [envoy] No thread mapping for task: $task_id (human_input_request)"
  fi
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

      if echo "$content" | grep -qE '^(✅|❌)'; then
        remove_thread_mapping "$task_id"
        remove_awaiting_response "$task_id"
        log "[EVENT] [envoy] Thread closed for task: $task_id"
      fi
    else
      local channel
      channel=$(echo "$msg" | jq -r '.channel // "'"$(get_config "envoy" "slack.default_channel")"'"')
      send_message "$channel" "$content" || return 1
      log "[WARN] [envoy] No thread mapping for task: $task_id, sent to channel"
    fi
  else
    local channel
    channel=$(echo "$msg" | jq -r '.channel // "'"$(get_config "envoy" "slack.default_channel")"'"')
    send_message "$channel" "$content" || return 1
  fi
}

process_report() {
  local msg="$1"
  local channel content
  channel=$(echo "$msg" | jq -r '.channel // "'"$(get_config "envoy" "slack.default_channel")"'"')
  content=$(echo "$msg" | jq -r '.content')
  send_message "$channel" "$content" || return 1
  log "[EVENT] [envoy] Report sent"
}

# --- Outbound Queue Processing ---

process_outbound_queue() {
  local pending_dir="$BASE_DIR/queue/messages/pending"
  local sent_dir="$BASE_DIR/queue/messages/sent"

  for msg_file in "$pending_dir"/*.json; do
    [[ -f "$msg_file" ]] || continue

    local msg msg_type
    msg=$(cat "$msg_file")
    msg_type=$(echo "$msg" | jq -r '.type')

    case "$msg_type" in
      thread_start)       process_thread_start "$msg" ;;
      thread_update)      process_thread_update "$msg" ;;
      human_input_request) process_human_input_request "$msg" ;;
      notification)       process_notification "$msg" ;;
      report)             process_report "$msg" ;;
      *)                  log "[EVENT] [envoy] Unknown message type: $msg_type" ;;
    esac

    mv "$msg_file" "$sent_dir/"
  done
}

# --- Awaiting Responses Check ---

check_awaiting_responses() {
  [[ -f "$AWAITING_FILE" ]] || return 0
  local count
  count=$(jq 'length' "$AWAITING_FILE")
  [[ "$count" -gt 0 ]] || return 0

  jq -c '.[]' "$AWAITING_FILE" | while read -r entry; do
    local task_id thread_ts channel asked_at
    task_id=$(echo "$entry" | jq -r '.task_id')
    thread_ts=$(echo "$entry" | jq -r '.thread_ts')
    channel=$(echo "$entry" | jq -r '.channel')
    asked_at=$(echo "$entry" | jq -r '.asked_at')

    local replies
    replies=$(read_thread_replies "$channel" "$thread_ts" "$asked_at") || continue

    local human_reply
    human_reply=$(echo "$replies" | jq -r \
      '.messages[]? | select(.bot_id == null and .ts != "'"$thread_ts"'") | .text' | head -1)

    if [[ -n "$human_reply" ]]; then
      local event_id="evt-slack-response-${task_id}-$(date +%s)"
      local event
      event=$(jq -n \
        --arg id "$event_id" \
        --arg task_id "$task_id" \
        --arg response "$human_reply" \
        '{
          id: $id,
          type: "slack.human_response",
          source: "slack",
          repo: null,
          payload: { task_id: $task_id, human_response: $response },
          priority: "high",
          created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
          status: "pending"
        }')

      emit_event "$event"
      remove_awaiting_response "$task_id"
      emit_internal_event "message.human_response" "envoy" \
        "$(jq -n -c --arg tid "$task_id" --arg ts "$thread_ts" '{task_id: $tid, thread_ts: $ts}')"
      log "[EVENT] [envoy] Human responded for task: $task_id"
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

  sleep 5
done

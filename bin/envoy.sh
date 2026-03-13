#!/usr/bin/env bash
# Kingdom Envoy - Slack Communication Manager

set -uo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/envoy/thread-manager.sh"

SOCKET_MODE_ENABLED=$(get_config "envoy" "socket_mode.enabled" "false")
export SOCKET_MODE_ENABLED

source "$BASE_DIR/bin/lib/envoy/slack-api.sh"
source "$BASE_DIR/bin/lib/envoy/bridge-lifecycle.sh"
source "$BASE_DIR/bin/lib/envoy/message-processors.sh"
source "$BASE_DIR/bin/lib/envoy/outbound.sh"
source "$BASE_DIR/bin/lib/envoy/socket-inbox.sh"
source "$BASE_DIR/bin/lib/envoy/legacy-inbox.sh"

RUNNING=true
trap 'RUNNING=false; stop_bridge; stop_heartbeat_daemon; rm -f /tmp/kingdom-wake-$$.fifo; log "[SYSTEM] [envoy] Shutting down..."; exit 0' SIGTERM SIGINT

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
CHANNEL_FOR_HISTORY=""
resolve_history_channel

log "[SYSTEM] [envoy] Started. socket_mode=$SOCKET_MODE_ENABLED channel_for_history=${CHANNEL_FOR_HISTORY:-none}"

start_heartbeat_daemon "envoy"
if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
  start_bridge
fi

while $RUNNING; do
  now=$(date +%s)

  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    check_socket_inbox
  fi

  if (( now - LAST_OUTBOUND >= OUTBOUND_INTERVAL )); then
    process_outbound_queue
    LAST_OUTBOUND=$now
  fi

  if [[ "$SOCKET_MODE_ENABLED" == "true" ]]; then
    if (( now - LAST_CONV_EXPIRE >= 60 )); then
      expire_conversations
      LAST_CONV_EXPIRE=$now
    fi

    if (( now - LAST_BRIDGE_CHECK >= 30 )); then
      check_bridge_health
      LAST_BRIDGE_CHECK=$now
    fi
  else
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
    sleep_or_wake 5 "$BASE_DIR/state/envoy/socket-inbox" "$BASE_DIR/queue/messages/pending"
  else
    sleep_or_wake 5 "$BASE_DIR/queue/messages/pending"
  fi
done

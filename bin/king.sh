#!/usr/bin/env bash
# bin/king.sh — King main loop
# Central coordinator: event→task routing, result processing, schedule management

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/king/router.sh"
source "$BASE_DIR/bin/lib/king/resource-check.sh"
source "$BASE_DIR/bin/lib/king/functions.sh"
source "$BASE_DIR/bin/lib/king/petition.sh"

# --- Main Guard: only run main loop when executed directly ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

  # --- Graceful Shutdown ---
  RUNNING=true
  trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [king] Shutting down..."; exit 0' SIGTERM SIGINT

  # --- Load General Manifests ---
  load_general_manifests

  # --- Sequence Files ---
  TASK_SEQ_FILE="$BASE_DIR/state/king/task-seq"
  MSG_SEQ_FILE="$BASE_DIR/state/king/msg-seq"
  SCHEDULE_SENT_FILE="$BASE_DIR/state/king/schedule-sent.json"

  # --- Timer intervals (from config) ---
  EVENT_CHECK_INTERVAL=$(get_config "king" "intervals.event_check_seconds" "10")
  RESULT_CHECK_INTERVAL=$(get_config "king" "intervals.result_check_seconds" "10")
  SCHEDULE_CHECK_INTERVAL=$(get_config "king" "intervals.schedule_check_seconds" "60")
  PETITION_CHECK_INTERVAL=$(get_config "king" "intervals.petition_check_seconds" "5")
  LOOP_TICK=$(get_config "king" "intervals.loop_tick_seconds" "5")

  LAST_EVENT_CHECK=0
  LAST_RESULT_CHECK=0
  LAST_SCHEDULE_CHECK=0
  LAST_PETITION_CHECK=0

  log "[SYSTEM] [king] Started. $(get_routing_table_count) event types registered."

  start_heartbeat_daemon "king"

  while $RUNNING; do
    now=$(date +%s)

    # 1. Event consumption
    if (( now - LAST_EVENT_CHECK >= EVENT_CHECK_INTERVAL )); then
      process_pending_events
      LAST_EVENT_CHECK=$now
    fi

    # 1.5 Petition result processing (상소 심의)
    if (( now - LAST_PETITION_CHECK >= PETITION_CHECK_INTERVAL )); then
      process_petition_results
      LAST_PETITION_CHECK=$now
    fi

    # 2. Result check
    if (( now - LAST_RESULT_CHECK >= RESULT_CHECK_INTERVAL )); then
      check_task_results
      LAST_RESULT_CHECK=$now
    fi

    # 3. Schedule check
    if (( now - LAST_SCHEDULE_CHECK >= SCHEDULE_CHECK_INTERVAL )); then
      check_general_schedules
      LAST_SCHEDULE_CHECK=$now
    fi

    sleep "$LOOP_TICK"
  done

fi

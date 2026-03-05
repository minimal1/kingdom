#!/usr/bin/env bash
# bin/chamberlain.sh — Chamberlain (System Monitor) entry point
BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"

source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/chamberlain/metrics-collector.sh"
source "$BASE_DIR/bin/lib/chamberlain/session-checker.sh"
source "$BASE_DIR/bin/lib/chamberlain/event-consumer.sh"
source "$BASE_DIR/bin/lib/chamberlain/auto-recovery.sh"
source "$BASE_DIR/bin/lib/chamberlain/log-rotation.sh"

INTERVAL=$(get_config "chamberlain" "monitoring.interval_seconds" 30)

RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [chamberlain] Shutting down..."; exit 0' SIGTERM SIGINT

emit_internal_event "system.startup" "chamberlain" '{"component": "chamberlain"}'
log "[SYSTEM] [chamberlain] Started."

start_heartbeat_daemon "chamberlain"

while $RUNNING; do

  # 1. Collect system metrics
  collect_metrics

  # 2. Evaluate health + update resources.json
  prev_health=$(get_current_health)
  curr_health=$(evaluate_health)
  update_resources_json "$curr_health"

  if [ "$prev_health" != "$curr_health" ]; then
    emit_internal_event "system.health_changed" "chamberlain" \
      "$(jq -n --arg from "$prev_health" --arg to "$curr_health" '{from: $from, to: $to}')"
  fi

  # 3. Heartbeat monitoring
  check_heartbeats

  # 4. Session cleanup
  check_and_clean_sessions

  # 5. Internal event consumption
  consume_internal_events

  # 6. Threshold checks + auto-recovery
  check_thresholds_and_act "$curr_health"

  # 7. Periodic tasks (log rotation, cleanup, report)
  run_periodic_tasks

  sleep "$INTERVAL"
done

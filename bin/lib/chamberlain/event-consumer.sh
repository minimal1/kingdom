#!/usr/bin/env bash
# Chamberlain Event Consumer — internal event processing + anomaly detection

# --- Event Consumption ---

consume_internal_events() {
  local events_file="$BASE_DIR/logs/events.log"
  [ -f "$events_file" ] || return 0

  local last_offset
  last_offset=$(cat "$BASE_DIR/state/chamberlain/events-offset" 2>/dev/null || echo 0)
  local total_lines
  total_lines=$(wc -l < "$events_file" | tr -d ' ')

  # No new events
  (( total_lines <= last_offset )) && return 0

  # Extract new events (valid JSON only)
  local new_events
  new_events=$(tail -n +$((last_offset + 1)) "$events_file" | jq -c '.' 2>/dev/null || true)

  if [ -z "$new_events" ]; then
    log "[WARN] [chamberlain] events.log parse error at offset $last_offset, skipping"
    echo "$total_lines" > "$BASE_DIR/state/chamberlain/events-offset"
    return 0
  fi

  # Aggregate metrics
  aggregate_metrics "$new_events"

  # Detect anomalies
  detect_anomalies "$new_events"

  # Update offset (at-least-once: update after processing)
  echo "$total_lines" > "$BASE_DIR/state/chamberlain/events-offset"
}

# --- Metrics Aggregation ---

aggregate_metrics() {
  local events="$1"
  local stats_file="$BASE_DIR/logs/analysis/stats.json"

  local task_completed task_failed soldier_spawned soldier_timeout
  # grep -c outputs "0" on no match but exits 1; || true suppresses exit without adding output
  task_completed=$(echo "$events" | grep -c '"type":"task.completed"' || true)
  task_failed=$(echo "$events" | grep -c '"type":"task.failed"' || true)
  soldier_spawned=$(echo "$events" | grep -c '"type":"soldier.spawned"' || true)
  soldier_timeout=$(echo "$events" | grep -c '"type":"soldier.timeout"' || true)

  local prev
  prev=$(cat "$stats_file" 2>/dev/null || echo '{}')

  echo "$prev" | jq \
    --argjson tc "$task_completed" \
    --argjson tf "$task_failed" \
    --argjson ss "$soldier_spawned" \
    --argjson st "$soldier_timeout" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      updated_at: $ts,
      totals: {
        task_completed: ((.totals.task_completed // 0) + $tc),
        task_failed: ((.totals.task_failed // 0) + $tf),
        soldier_spawned: ((.totals.soldier_spawned // 0) + $ss),
        soldier_timeout: ((.totals.soldier_timeout // 0) + $st)
      }
    }' > "${stats_file}.tmp"

  mv "${stats_file}.tmp" "$stats_file"
}

# --- Anomaly Detection ---

detect_anomalies() {
  local events="$1"

  # Pattern 1: Consecutive failures per actor (threshold: 3)
  local failure_threshold
  failure_threshold=$(get_config "chamberlain" "anomaly.consecutive_failures" 3)

  local failed_lines
  failed_lines=$(echo "$events" | grep '"type":"task.failed"' || true)

  if [ -n "$failed_lines" ]; then
    # Count failures per actor
    echo "$failed_lines" | jq -r '.actor // empty' 2>/dev/null | sort | uniq -c | while read -r count actor; do
      count=$(echo "$count" | tr -d ' ')
      if [ -n "$count" ] && [ -n "$actor" ] && (( count >= failure_threshold )); then
        create_alert_message "[이상 감지] $actor 가 ${count}회 연속 실패"
      fi
    done
  fi

  # Pattern 2: Soldier timeout spike (5+ in batch)
  local timeout_threshold
  timeout_threshold=$(get_config "chamberlain" "anomaly.timeout_spike" 5)

  local recent_timeouts
  recent_timeouts=$(echo "$events" | grep -c '"type":"soldier.timeout"' || true)

  if (( recent_timeouts >= timeout_threshold )); then
    create_alert_message "[이상 감지] 병사 타임아웃 ${recent_timeouts}회 — 시스템 과부하 의심"
  fi
}

#!/usr/bin/env bash
# Chamberlain Log Rotation — periodic tasks, cleanup, daily report

# --- Periodic Task Dispatcher ---

run_periodic_tasks() {
  local now_hour
  now_hour=$(date +%H)
  local now_min
  now_min=$(date +%M)

  # Log rotation (every loop, size-based)
  rotate_logs_if_needed

  # Expired file cleanup (daily 03:00)
  if [ "$now_hour" = "03" ] && [ "$now_min" = "00" ] && should_run_daily "cleanup"; then
    cleanup_expired_files
  fi

  # Daily report (daily 09:00)
  if [ "$now_hour" = "09" ] && [ "$now_min" = "00" ] && should_run_daily "daily-report"; then
    generate_daily_report
  fi

  # Events log rotation (daily 00:00)
  if [ "$now_hour" = "00" ] && [ "$now_min" = "00" ] && should_run_daily "events-rotation"; then
    rotate_events_log
  fi
}

# --- Daily Dedup ---

should_run_daily() {
  local task_name="$1"
  local marker="$BASE_DIR/state/chamberlain/daily-${task_name}"
  local today
  today=$(date +%Y-%m-%d)

  local last_run
  last_run=$(cat "$marker" 2>/dev/null || echo "")
  if [ "$last_run" = "$today" ]; then
    return 1
  fi

  echo "$today" > "$marker"
  return 0
}

# --- Log Rotation ---

rotate_logs_if_needed() {
  local max_mb
  max_mb=$(get_config "chamberlain" "retention.log_max_mb" 100)
  local max_bytes=$((max_mb * 1024 * 1024))

  for logfile in "$BASE_DIR/logs/"*.log; do
    [ -f "$logfile" ] || continue
    # Skip daily event split files
    [[ "$(basename "$logfile")" == events-*.log ]] && continue

    local size
    if is_macos; then
      size=$(stat -f %z "$logfile" 2>/dev/null || true)
    else
      size=$(stat -c %s "$logfile" 2>/dev/null || true)
    fi

    if (( size > max_bytes )); then
      local base
      base=$(basename "$logfile")
      mv "$logfile" "${logfile}.old"
      touch "$logfile"

      local size_mb=$((size / 1024 / 1024))
      emit_internal_event "recovery.log_rotated" "chamberlain" \
        "$(jq -n --arg file "$base" --argjson size_mb "$size_mb" \
                 '{file: $file, size_mb: $size_mb}')"

      log "[ROTATION] [chamberlain] Rotated: $base (${size_mb}MB → .old)"
    fi
  done
}

# --- Expired File Cleanup ---

cleanup_expired_files() {
  local log_days result_days queue_days prompt_days session_log_days seen_days
  log_days=$(get_config "chamberlain" "retention.logs_days" 7)
  result_days=$(get_config "chamberlain" "retention.results_days" 7)
  queue_days=$(get_config "chamberlain" "retention.queue_days" 7)
  prompt_days=$(get_config "chamberlain" "retention.prompts_days" 3)
  session_log_days=$(get_config "chamberlain" "retention.session_logs_days" 7)
  seen_days=$(get_config "chamberlain" "retention.seen_days" 30)

  local total=0
  local count

  # Rotated log files (.old)
  count=$(find "$BASE_DIR/logs/" -maxdepth 1 -name "*.old" -mtime +"$log_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  # Daily event split files (events-YYYYMMDD.log)
  count=$(find "$BASE_DIR/logs/" -maxdepth 1 -name "events-*.log" -mtime +"$log_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  # Soldier session logs
  count=$(find "$BASE_DIR/logs/sessions/" -name "*.log" -mtime +"$session_log_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  # Result files
  count=$(find "$BASE_DIR/state/results/" -type f -mtime +"$result_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  # Prompt files
  count=$(find "$BASE_DIR/state/prompts/" -type f -mtime +"$prompt_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  # Completed queue files
  for subdir in "events/completed" "tasks/completed" "messages/sent"; do
    count=$(find "$BASE_DIR/queue/$subdir/" -type f -mtime +"$queue_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
    total=$((total + count))
  done

  # Sentinel seen index
  count=$(find "$BASE_DIR/state/sentinel/seen/" -type f -mtime +"$seen_days" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + count))

  if (( total > 0 )); then
    emit_internal_event "recovery.files_cleaned" "chamberlain" \
      "$(jq -n --argjson count "$total" '{deleted_count: $count}')"
    log "[CLEANUP] [chamberlain] Deleted $total expired files"
  fi
}

# --- Events Log Rotation ---

rotate_events_log() {
  local events_file="$BASE_DIR/logs/events.log"
  [ -f "$events_file" ] || return 0

  local yesterday
  if is_macos; then
    yesterday=$(date -v-1d +%Y%m%d)
  else
    yesterday=$(date -d 'yesterday' +%Y%m%d)
  fi

  mv "$events_file" "$BASE_DIR/logs/events-${yesterday}.log"
  touch "$events_file"

  # Reset offset (new file starts at 0)
  echo "0" > "$BASE_DIR/state/chamberlain/events-offset"

  log "[ROTATION] [chamberlain] Events log rotated: events-${yesterday}.log"
}

# --- Daily Report ---

generate_daily_report() {
  local yesterday
  if is_macos; then
    yesterday=$(date -v-1d +%Y-%m-%d)
  else
    yesterday=$(date -d 'yesterday' +%Y-%m-%d)
  fi

  local events_file="$BASE_DIR/logs/events.log"

  # Filter yesterday's events by timestamp prefix
  local yesterday_events
  yesterday_events=$(grep "\"ts\":\"${yesterday}" "$events_file" 2>/dev/null || echo "")

  local tasks_created tasks_completed tasks_failed tasks_needs_human soldiers_spawned soldiers_timeout
  tasks_created=$(echo "$yesterday_events" | grep -c '"type":"task.created"' 2>/dev/null || true)
  tasks_completed=$(echo "$yesterday_events" | grep -c '"type":"task.completed"' 2>/dev/null || true)
  tasks_failed=$(echo "$yesterday_events" | grep -c '"type":"task.failed"' 2>/dev/null || true)
  tasks_needs_human=$(echo "$yesterday_events" | grep -c '"type":"task.needs_human"' 2>/dev/null || true)
  soldiers_spawned=$(echo "$yesterday_events" | grep -c '"type":"soldier.spawned"' 2>/dev/null || true)
  soldiers_timeout=$(echo "$yesterday_events" | grep -c '"type":"soldier.timeout"' 2>/dev/null || true)

  local report
  report=$(jq -n \
    --arg date "$yesterday" \
    --argjson tc "$tasks_created" \
    --argjson tcomp "$tasks_completed" \
    --argjson tf "$tasks_failed" \
    --argjson tn "$tasks_needs_human" \
    --argjson ss "$soldiers_spawned" \
    --argjson st "$soldiers_timeout" \
    '{
      report_type: "daily",
      date: $date,
      tasks: {created: $tc, completed: $tcomp, failed: $tf, needs_human: $tn},
      soldiers: {spawned: $ss, timeout: $st}
    }')

  local msg_id="msg-daily-report-$(date +%s)"
  jq -n \
    --arg id "$msg_id" \
    --arg content "$report" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      type: "report",
      task_id: null,
      content: $content,
      urgency: "low",
      created_at: $ts
    }' > "$BASE_DIR/queue/messages/pending/${msg_id}.json"

  log "[REPORT] [chamberlain] Daily report generated for $yesterday"
}

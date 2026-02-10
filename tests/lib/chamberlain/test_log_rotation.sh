#!/usr/bin/env bats
# log-rotation.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  cp "${BATS_TEST_DIRNAME}/../../../config/chamberlain.yaml" "$BASE_DIR/config/"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/auto-recovery.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/event-consumer.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/log-rotation.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- should_run_daily ---

@test "log-rotation: should_run_daily returns true on first run" {
  should_run_daily "test-task"
  # Should succeed (return 0)
  local marker
  marker=$(cat "$BASE_DIR/state/chamberlain/daily-test-task")
  [ "$marker" = "$(date +%Y-%m-%d)" ]
}

@test "log-rotation: should_run_daily returns false on second run" {
  should_run_daily "test-task"

  run should_run_daily "test-task"
  assert_failure
}

@test "log-rotation: should_run_daily resets on new day" {
  echo "2026-02-09" > "$BASE_DIR/state/chamberlain/daily-test-task"

  should_run_daily "test-task"
  # Should succeed because marker has yesterday's date
  local marker
  marker=$(cat "$BASE_DIR/state/chamberlain/daily-test-task")
  [ "$marker" = "$(date +%Y-%m-%d)" ]
}

# --- rotate_logs_if_needed ---

@test "log-rotation: rotate_logs_if_needed rotates large file" {
  # Create a file larger than threshold (use small threshold for test)
  # Default is 100MB, but we can create a small file and test with a modified config
  # Instead, create system.log with known size and set config to 0 (always rotate)
  echo "test log line" > "$BASE_DIR/logs/system.log"

  # Override config to rotate at 1 byte
  cat > "$BASE_DIR/config/chamberlain.yaml" << 'EOF'
retention:
  log_max_mb: 0
EOF

  rotate_logs_if_needed

  assert [ -f "$BASE_DIR/logs/system.log.old" ]
  assert [ -f "$BASE_DIR/logs/system.log" ]
  # New system.log should be empty (or contain rotation log message)
}

@test "log-rotation: rotate_logs_if_needed skips small file" {
  echo "small" > "$BASE_DIR/logs/system.log"

  rotate_logs_if_needed

  assert [ ! -f "$BASE_DIR/logs/system.log.old" ]
}

@test "log-rotation: rotate_logs_if_needed skips event split files" {
  # events-20260207.log should not be rotated (handled by rotate_events_log)
  echo "test" > "$BASE_DIR/logs/events-20260207.log"

  cat > "$BASE_DIR/config/chamberlain.yaml" << 'EOF'
retention:
  log_max_mb: 0
EOF

  rotate_logs_if_needed

  assert [ ! -f "$BASE_DIR/logs/events-20260207.log.old" ]
}

# --- cleanup_expired_files ---

@test "log-rotation: cleanup_expired_files deletes old files" {
  # Create files with very old mtime
  touch "$BASE_DIR/logs/system.log.old"
  touch "$BASE_DIR/state/results/old-result.json"
  touch "$BASE_DIR/state/prompts/old-prompt.md"
  touch "$BASE_DIR/queue/events/completed/old-event.json"
  touch "$BASE_DIR/state/sentinel/seen/old-seen"
  touch "$BASE_DIR/logs/sessions/old-soldier.log"

  # Set mtime to 40 days ago
  local old_time
  if [[ "$(uname -s)" == "Darwin" ]]; then
    old_time=$(date -v-40d +%Y%m%d%H%M.%S)
  else
    old_time=$(date -d '40 days ago' +%Y%m%d%H%M.%S)
  fi
  touch -t "$old_time" "$BASE_DIR/logs/system.log.old"
  touch -t "$old_time" "$BASE_DIR/state/results/old-result.json"
  touch -t "$old_time" "$BASE_DIR/state/prompts/old-prompt.md"
  touch -t "$old_time" "$BASE_DIR/queue/events/completed/old-event.json"
  touch -t "$old_time" "$BASE_DIR/state/sentinel/seen/old-seen"
  touch -t "$old_time" "$BASE_DIR/logs/sessions/old-soldier.log"

  cleanup_expired_files

  assert [ ! -f "$BASE_DIR/logs/system.log.old" ]
  assert [ ! -f "$BASE_DIR/state/results/old-result.json" ]
  assert [ ! -f "$BASE_DIR/state/prompts/old-prompt.md" ]
  assert [ ! -f "$BASE_DIR/queue/events/completed/old-event.json" ]
  assert [ ! -f "$BASE_DIR/state/sentinel/seen/old-seen" ]
  assert [ ! -f "$BASE_DIR/logs/sessions/old-soldier.log" ]
}

@test "log-rotation: cleanup_expired_files keeps recent files" {
  # Create fresh files
  touch "$BASE_DIR/logs/system.log.old"
  touch "$BASE_DIR/state/results/fresh-result.json"
  touch "$BASE_DIR/state/sentinel/seen/fresh-seen"

  cleanup_expired_files

  assert [ -f "$BASE_DIR/logs/system.log.old" ]
  assert [ -f "$BASE_DIR/state/results/fresh-result.json" ]
  assert [ -f "$BASE_DIR/state/sentinel/seen/fresh-seen" ]
}

# --- rotate_events_log ---

@test "log-rotation: rotate_events_log moves and resets offset" {
  echo '{"ts":"2026-02-07T10:00:00Z","type":"test","actor":"test","data":{}}' > "$BASE_DIR/logs/events.log"
  echo "1" > "$BASE_DIR/state/chamberlain/events-offset"

  rotate_events_log

  # Original events.log should be empty (fresh)
  local size
  if [[ "$(uname -s)" == "Darwin" ]]; then
    size=$(stat -f %z "$BASE_DIR/logs/events.log" 2>/dev/null)
  else
    size=$(stat -c %s "$BASE_DIR/logs/events.log" 2>/dev/null)
  fi
  [ "$size" -eq 0 ]

  # Offset should be reset to 0
  local offset
  offset=$(cat "$BASE_DIR/state/chamberlain/events-offset")
  [ "$offset" = "0" ]

  # Rotated file should exist
  local rotated_count
  rotated_count=$(ls "$BASE_DIR/logs/events-"*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$rotated_count" -eq 1 ]
}

# --- generate_daily_report ---

@test "log-rotation: generate_daily_report creates message" {
  # Write events with yesterday's date
  local yesterday
  if [[ "$(uname -s)" == "Darwin" ]]; then
    yesterday=$(date -v-1d +%Y-%m-%d)
  else
    yesterday=$(date -d 'yesterday' +%Y-%m-%d)
  fi

  echo "{\"ts\":\"${yesterday}T10:00:00Z\",\"type\":\"task.completed\",\"actor\":\"gen-pr\",\"data\":{}}" >> "$BASE_DIR/logs/events.log"
  echo "{\"ts\":\"${yesterday}T11:00:00Z\",\"type\":\"task.created\",\"actor\":\"king\",\"data\":{}}" >> "$BASE_DIR/logs/events.log"

  generate_daily_report

  # Should create a report message
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"msg-daily-report-*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]

  run jq -r '.type' "$msg_file"
  assert_output "report"
  run jq -r '.urgency' "$msg_file"
  assert_output "low"
}

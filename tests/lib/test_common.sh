#!/usr/bin/env bats
# bin/lib/common.sh unit tests

setup() {
  load '../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../bin/lib/common.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- is_macos / is_linux ---

@test "common: is_macos returns true on Darwin" {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    run is_macos
    assert_success
  else
    run is_macos
    assert_failure
  fi
}

@test "common: is_linux returns true on Linux" {
  if [[ "$(uname -s)" == "Linux" ]]; then
    run is_linux
    assert_success
  else
    run is_linux
    assert_failure
  fi
}

# --- log ---

@test "common: log creates system.log with timestamp format" {
  log "[SYSTEM] [test] hello world"
  assert [ -f "$BASE_DIR/logs/system.log" ]
  run cat "$BASE_DIR/logs/system.log"
  # [YYYY-MM-DD HH:MM:SS] 포맷 확인
  assert_output --regexp '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]'
  assert_output --partial "[SYSTEM] [test] hello world"
}

@test "common: log appends multiple lines" {
  log "[SYSTEM] [test] line1"
  log "[TASK] [king] line2"
  run wc -l < "$BASE_DIR/logs/system.log"
  assert_output --partial "2"
}

# --- get_config ---

@test "common: get_config reads yaml value" {
  cat > "$BASE_DIR/config/test.yaml" << 'EOF'
interval: 30
nested:
  key: value
EOF
  run get_config "test" "interval"
  assert_output "30"
}

@test "common: get_config reads nested yaml value" {
  cat > "$BASE_DIR/config/test.yaml" << 'EOF'
nested:
  key: deep_value
EOF
  run get_config "test" "nested.key"
  assert_output "deep_value"
}

@test "common: get_config returns default for missing key" {
  cat > "$BASE_DIR/config/test.yaml" << 'EOF'
existing: yes
EOF
  run get_config "test" "nonexistent" "fallback"
  assert_output "fallback"
}

@test "common: get_config returns default for missing file" {
  run get_config "nonexistent_config" "key" "default_val"
  assert_output "default_val"
}

# --- update_heartbeat ---

@test "common: update_heartbeat creates heartbeat file" {
  mkdir -p "$BASE_DIR/state/king"
  update_heartbeat "king"
  assert [ -f "$BASE_DIR/state/king/heartbeat" ]
}

@test "common: update_heartbeat updates mtime" {
  mkdir -p "$BASE_DIR/state/king"
  touch -t 202001010000 "$BASE_DIR/state/king/heartbeat"
  local old_mtime
  old_mtime=$(get_mtime "$BASE_DIR/state/king/heartbeat")
  sleep 1
  update_heartbeat "king"
  local new_mtime
  new_mtime=$(get_mtime "$BASE_DIR/state/king/heartbeat")
  [ "$new_mtime" -gt "$old_mtime" ]
}

# --- emit_event ---

@test "common: emit_event creates json file in pending" {
  local event_json='{"id":"evt-test-001","type":"test.event","source":"test","priority":"normal","created_at":"2026-02-07T10:00:00Z","data":{}}'
  emit_event "$event_json"
  # pending/ 디렉토리에 파일이 생겨야 함
  local count
  count=$(ls "$BASE_DIR/queue/events/pending/" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "common: emit_event file is valid json" {
  local event_json='{"id":"evt-test-002","type":"test.event","source":"test","priority":"normal","created_at":"2026-02-07T10:00:00Z","data":{}}'
  emit_event "$event_json"
  local file
  file=$(ls "$BASE_DIR/queue/events/pending/"*.json | head -1)
  run jq -r '.id' "$file"
  assert_output "evt-test-002"
}

@test "common: emit_event leaves no tmp files" {
  local event_json='{"id":"evt-test-003","type":"test.event","source":"test","priority":"normal","created_at":"2026-02-07T10:00:00Z","data":{}}'
  emit_event "$event_json"
  local tmp_count
  tmp_count=$(ls "$BASE_DIR/queue/events/pending/"*.tmp 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]
}

# --- emit_internal_event ---

@test "common: emit_internal_event appends to events.log" {
  emit_internal_event "task.created" "king" '{"task_id":"task-001"}'
  assert [ -f "$BASE_DIR/logs/events.log" ]
  run wc -l < "$BASE_DIR/logs/events.log"
  assert_output --partial "1"
}

@test "common: emit_internal_event writes valid JSONL" {
  emit_internal_event "task.created" "king" '{"task_id":"task-001"}'
  run jq -r '.type' "$BASE_DIR/logs/events.log"
  assert_output "task.created"
}

@test "common: emit_internal_event includes all fields" {
  emit_internal_event "event.detected" "sentinel" '{"event_id":"evt-123","source":"github"}'
  run jq -r '.actor' "$BASE_DIR/logs/events.log"
  assert_output "sentinel"
  run jq -r '.data.event_id' "$BASE_DIR/logs/events.log"
  assert_output "evt-123"
  # ts 필드 존재 확인
  run jq -r '.ts' "$BASE_DIR/logs/events.log"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "common: emit_internal_event defaults data to empty object" {
  emit_internal_event "system.startup" "system"
  run jq -r '.data' "$BASE_DIR/logs/events.log"
  assert_output "{}"
}

# --- portable_date ---

@test "common: portable_date outputs ISO8601 format" {
  run portable_date "+%Y-%m-%dT%H:%M:%SZ"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

@test "common: portable_date outputs date-only format" {
  run portable_date "+%Y-%m-%d"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

# --- get_mtime ---

@test "common: get_mtime returns numeric value" {
  local tmpfile="$BASE_DIR/test_mtime"
  touch "$tmpfile"
  run get_mtime "$tmpfile"
  assert_output --regexp '^[0-9]+$'
}

# --- portable_flock ---

# --- heartbeat daemon ---

@test "common: start_heartbeat_daemon creates heartbeat file" {
  start_heartbeat_daemon "test-role" 1
  sleep 2
  stop_heartbeat_daemon
  assert [ -f "$BASE_DIR/state/test-role/heartbeat" ]
}

@test "common: stop_heartbeat_daemon kills background process" {
  start_heartbeat_daemon "test-role" 1
  local pid="$_HEARTBEAT_PID"
  assert [ -n "$pid" ]
  stop_heartbeat_daemon
  # 프로세스가 종료되었는지 확인
  ! kill -0 "$pid" 2>/dev/null
}

@test "common: heartbeat daemon updates mtime continuously" {
  start_heartbeat_daemon "test-role" 1
  sleep 2
  local mtime1
  mtime1=$(get_mtime "$BASE_DIR/state/test-role/heartbeat")
  sleep 2
  local mtime2
  mtime2=$(get_mtime "$BASE_DIR/state/test-role/heartbeat")
  stop_heartbeat_daemon
  assert [ "$mtime2" -gt "$mtime1" ]
}

# --- portable_flock ---

@test "common: portable_flock executes command" {
  local lockfile="$BASE_DIR/test.lock"
  local outfile="$BASE_DIR/flock_out"
  portable_flock "$lockfile" "echo locked > '$outfile'"
  assert [ -f "$outfile" ]
  run cat "$outfile"
  assert_output "locked"
}

#!/usr/bin/env bats
# session-checker.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  cp "${BATS_TEST_DIRNAME}/../../../config/chamberlain.yaml" "$BASE_DIR/config/"
  # Need general manifests for check_heartbeats
  install_test_general "gen-pr"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/auto-recovery.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/session-checker.sh"

  # Initialize sessions.json
  echo '[]' > "$BASE_DIR/state/sessions.json"
}

teardown() {
  teardown_kingdom_env
}

# --- check_heartbeats ---

@test "session: check_heartbeats skips missing heartbeat" {
  # No heartbeat file → should not log any warning about missed heartbeat
  check_heartbeats

  # No error about missed heartbeat
  if [ -f "$BASE_DIR/logs/system.log" ]; then
    run grep "Heartbeat missed" "$BASE_DIR/logs/system.log"
    assert_failure
  fi
}

@test "session: check_heartbeats fresh heartbeat no alert" {
  # Create fresh heartbeat
  mkdir -p "$BASE_DIR/state/sentinel"
  touch "$BASE_DIR/state/sentinel/heartbeat"

  check_heartbeats

  # No alert messages created
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 0 ]
}

@test "session: check_heartbeats stale heartbeat triggers warning" {
  # Create heartbeat with old mtime (200 seconds ago)
  mkdir -p "$BASE_DIR/state/sentinel"
  touch "$BASE_DIR/state/sentinel/heartbeat"
  local old_time
  old_time=$(date -v-200S +%Y%m%d%H%M.%S 2>/dev/null || date -d '200 seconds ago' +%Y%m%d%H%M.%S)
  touch -t "$old_time" "$BASE_DIR/state/sentinel/heartbeat"

  check_heartbeats

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Heartbeat missed"
  assert_output --partial "sentinel"
}

# --- handle_dead_role ---

@test "session: handle_dead_role sentinel restarts" {
  handle_dead_role "sentinel"

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Restarting sentinel"
}

@test "session: handle_dead_role king creates high alert" {
  handle_dead_role "king"

  # Should create alert message
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]

  run jq -r '.urgency' "$msg_file"
  assert_output "high"
  run jq -r '.content' "$msg_file"
  assert_output --partial "king"
}

@test "session: handle_dead_role gen-pr creates alert" {
  handle_dead_role "gen-pr"

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]

  run jq -r '.content' "$msg_file"
  assert_output --partial "gen-pr"
  assert_output --partial "병사 정리"
}

# --- kill_soldiers_of_dead_general ---

@test "session: kill_soldiers_of_dead_general kills matching soldiers" {
  # Create in_progress task for gen-pr
  cat > "$BASE_DIR/queue/tasks/in_progress/task-001.json" << 'EOF'
{"id":"task-001","target_general":"gen-pr"}
EOF
  echo "soldier-test-123" > "$BASE_DIR/state/results/task-001-soldier-id"

  # Set mock tmux to recognize the soldier
  export MOCK_TMUX_SESSIONS="soldier-test-123"

  kill_soldiers_of_dead_general "gen-pr"

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Killed orphan soldier"
  assert_output --partial "soldier-test-123"
}

@test "session: kill_soldiers_of_dead_general ignores other generals" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-002.json" << 'EOF'
{"id":"task-002","target_general":"gen-briefing"}
EOF
  echo "soldier-other-456" > "$BASE_DIR/state/results/task-002-soldier-id"
  export MOCK_TMUX_SESSIONS="soldier-other-456"

  kill_soldiers_of_dead_general "gen-pr"

  # Should not log any kill
  if [ -f "$BASE_DIR/logs/system.log" ]; then
    run grep "Killed orphan soldier" "$BASE_DIR/logs/system.log"
    assert_failure
  fi
}

# --- check_and_clean_sessions ---

@test "session: check_and_clean_sessions removes dead sessions" {
  cat > "$BASE_DIR/state/sessions.json" << 'EOF'
[{"id":"soldier-dead","task_id":"task-001","started_at":"2026-02-07T10:00:00Z"}]
EOF
  # No MOCK_TMUX_SESSIONS → soldier is dead
  unset MOCK_TMUX_SESSIONS

  check_and_clean_sessions

  run jq 'length' "$BASE_DIR/state/sessions.json"
  assert_output "0"
  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Removed dead session"
}

@test "session: check_and_clean_sessions keeps alive sessions" {
  cat > "$BASE_DIR/state/sessions.json" << 'EOF'
[{"id":"soldier-alive","task_id":"task-002","started_at":"2026-02-07T10:00:00Z"}]
EOF
  export MOCK_TMUX_SESSIONS="soldier-alive"

  check_and_clean_sessions

  run jq 'length' "$BASE_DIR/state/sessions.json"
  assert_output "1"
  run jq -r '.[0].id' "$BASE_DIR/state/sessions.json"
  assert_output "soldier-alive"
}

@test "session: check_and_clean_sessions handles empty array" {
  echo '[]' > "$BASE_DIR/state/sessions.json"

  check_and_clean_sessions

  run jq 'length' "$BASE_DIR/state/sessions.json"
  assert_output "0"
}

@test "session: check_and_clean_sessions mixed alive and dead" {
  cat > "$BASE_DIR/state/sessions.json" << 'EOF'
[
  {"id":"soldier-alive","task_id":"task-001","started_at":"2026-02-07T10:00:00Z"},
  {"id":"soldier-dead","task_id":"task-002","started_at":"2026-02-07T10:05:00Z"}
]
EOF
  export MOCK_TMUX_SESSIONS="soldier-alive"

  check_and_clean_sessions

  run jq 'length' "$BASE_DIR/state/sessions.json"
  assert_output "1"
  run jq -r '.[0].id' "$BASE_DIR/state/sessions.json"
  assert_output "soldier-alive"
}

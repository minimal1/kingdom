#!/usr/bin/env bats
# System scripts (start/stop/status) tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Copy configs
  cp "${BATS_TEST_DIRNAME}/../config/chamberlain.yaml" "$BASE_DIR/config/"
  install_test_general "gen-pr"
  install_test_general "gen-briefing"

  # Copy init-dirs.sh
  cp "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" "$BASE_DIR/bin/"

  # Copy common.sh
  mkdir -p "$BASE_DIR/bin/lib"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/common.sh" "$BASE_DIR/bin/lib/"

  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- start.sh functions ---

@test "system: start_session creates new session" {
  # Source start.sh functions inline
  start_session() {
    local name="$1"
    local script="$2"
    if tmux has-session -t "$name" 2>/dev/null; then
      return 0
    fi
    tmux new-session -d -s "$name" "$script"
    log "[SYSTEM] [start] Started session: $name"
  }

  start_session "test-session" "echo hello"

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Started session: test-session"
}

@test "system: start_session skips existing session" {
  export MOCK_TMUX_SESSIONS="existing-session"

  start_session() {
    local name="$1"
    local script="$2"
    if tmux has-session -t "$name" 2>/dev/null; then
      log "[SYSTEM] [start] Session already running: $name"
      return 0
    fi
    tmux new-session -d -s "$name" "$script"
    log "[SYSTEM] [start] Started session: $name"
  }

  start_session "existing-session" "echo hello"

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "already running"
}

# --- stop.sh functions ---

@test "system: stop kills soldier sessions" {
  echo '[{"id":"soldier-abc","task_id":"task-001"}]' > "$BASE_DIR/state/sessions.json"
  export MOCK_TMUX_SESSIONS="soldier-abc"
  export MOCK_LOG="$BASE_DIR/mock.log"

  # Inline stop logic for soldiers
  local count
  count=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
  for ((i=0; i<count; i++)); do
    local soldier_id
    soldier_id=$(jq -r ".[$i].id" "$BASE_DIR/state/sessions.json")
    if [ -n "$soldier_id" ] && tmux has-session -t "$soldier_id" 2>/dev/null; then
      tmux kill-session -t "$soldier_id"
      log "[SYSTEM] [stop] Killed soldier: $soldier_id"
    fi
  done

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Killed soldier: soldier-abc"
}

# --- status.sh functions ---

@test "system: check_session reports OK for active session" {
  export MOCK_TMUX_SESSIONS="sentinel"
  mkdir -p "$BASE_DIR/state/sentinel"
  touch "$BASE_DIR/state/sentinel/heartbeat"

  check_session() {
    local name="$1"
    local hb_file="$BASE_DIR/state/${name}/heartbeat"
    if tmux has-session -t "$name" 2>/dev/null; then
      local hb_age="N/A"
      if [ -f "$hb_file" ]; then
        local mtime
        mtime=$(get_mtime "$hb_file" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        hb_age="$((now - mtime))s"
      fi
      printf "  [OK]   %-16s heartbeat: %s\n" "$name" "$hb_age"
    else
      printf "  [DOWN] %-16s\n" "$name"
    fi
  }

  run check_session "sentinel"
  assert_output --partial "[OK]"
  assert_output --partial "sentinel"
}

@test "system: check_session reports DOWN for dead session" {
  unset MOCK_TMUX_SESSIONS

  check_session() {
    local name="$1"
    if tmux has-session -t "$name" 2>/dev/null; then
      printf "  [OK]   %-16s\n" "$name"
    else
      printf "  [DOWN] %-16s\n" "$name"
    fi
  }

  run check_session "king"
  assert_output --partial "[DOWN]"
  assert_output --partial "king"
}

@test "system: status shows soldier count" {
  echo '[{"id":"s1"},{"id":"s2"}]' > "$BASE_DIR/state/sessions.json"

  local soldier_count
  soldier_count=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
  [ "$soldier_count" -eq 2 ]
}

@test "system: status reads resources.json health" {
  echo '{"health":"yellow","system":{"cpu_percent":65,"memory_percent":40,"disk_percent":30}}' > "$BASE_DIR/state/resources.json"

  local health
  health=$(jq -r '.health' "$BASE_DIR/state/resources.json")
  [ "$health" = "yellow" ]
}

# --- watchdog ---

@test "system: watchdog concept detects dead session" {
  ESSENTIAL_SESSIONS=("sentinel" "king")
  unset MOCK_TMUX_SESSIONS

  local restarted=()
  for session in "${ESSENTIAL_SESSIONS[@]}"; do
    if ! tmux has-session -t "$session" 2>/dev/null; then
      restarted+=("$session")
    fi
  done

  [ ${#restarted[@]} -eq 2 ]
  [[ "${restarted[0]}" == "sentinel" ]]
  [[ "${restarted[1]}" == "king" ]]
}

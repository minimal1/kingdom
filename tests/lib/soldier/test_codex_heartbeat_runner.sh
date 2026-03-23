#!/usr/bin/env bats

setup() {
  load '../../test_helper'
  setup_kingdom_env
}

teardown() {
  teardown_kingdom_env
}

@test "soldier: codex heartbeat runner updates heartbeat on stream activity" {
  local mock_bin
  mock_bin="$(mktemp -d)"
  cat > "$mock_bin/codex" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"type":"tool_use","message":"step1"}\n'
sleep 2
printf '{"session_id":"sess-codex","type":"result","message":"done"}\n'
EOF
  chmod +x "$mock_bin/codex"

  local prompt_file="$BASE_DIR/state/prompts/task-001.md"
  local stdout_file="$BASE_DIR/logs/sessions/codex-heartbeat.json"
  local stderr_file="$BASE_DIR/logs/sessions/codex-heartbeat.err"
  local session_file="$BASE_DIR/state/results/task-001-session-id"
  local heartbeat_file="$BASE_DIR/state/results/task-001-heartbeat"
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  echo "prompt" > "$prompt_file"

  export PATH="$mock_bin:$PATH"
  export KINGDOM_RESULT_PATH="$BASE_DIR/state/results/task-001-raw.json"

  "${BATS_TEST_DIRNAME}/../../../bin/lib/soldier/codex-heartbeat-runner.sh" \
    "$BASE_DIR/workspace/gen-pr" \
    "$prompt_file" \
    "$stdout_file" \
    "$stderr_file" \
    "$session_file" \
    "" \
    "" \
    "codex" &
  local runner_pid=$!

  sleep 1
  assert [ -f "$heartbeat_file" ]
  local hb1
  hb1=$(stat -f %m "$heartbeat_file")

  sleep 3
  local hb2
  hb2=$(stat -f %m "$heartbeat_file")

  wait "$runner_pid"

  [ "$hb2" -gt "$hb1" ]
  run cat "$session_file"
  assert_output "sess-codex"
}

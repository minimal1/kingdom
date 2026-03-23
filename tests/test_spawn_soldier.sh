#!/usr/bin/env bats
# spawn-soldier.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Ensure common.sh is available at the expected path
  mkdir -p "$BASE_DIR/bin/lib"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/common.sh" "$BASE_DIR/bin/lib/"
  mkdir -p "$BASE_DIR/bin/lib/runtime"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/runtime/engine.sh" "$BASE_DIR/bin/lib/runtime/"

  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/runtime/engine.sh"
}

teardown() {
  teardown_kingdom_env
}

@test "spawn-soldier: creates soldier-id file" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-001.md"
  echo "test prompt" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-001" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  assert [ -f "$BASE_DIR/state/results/task-001-soldier-id" ]
  local soldier_id
  soldier_id=$(cat "$BASE_DIR/state/results/task-001-soldier-id")
  [[ "$soldier_id" == soldier-* ]]
}

@test "spawn-soldier: soldier-id has correct format" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-002.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-002" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  local soldier_id
  soldier_id=$(cat "$BASE_DIR/state/results/task-002-soldier-id")
  # soldier-{epoch}-{pid}
  [[ "$soldier_id" =~ ^soldier-[0-9]+-[0-9]+$ ]]
}

@test "spawn-soldier: logs spawn event" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-003.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-003" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "Spawned"
  assert_output --partial "task-003"
}

@test "spawn-soldier: exports KINGDOM_TASK_ID in tmux command" {
  export MOCK_LOG="$(mktemp)"
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-004.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-004" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  run cat "$MOCK_LOG"
  assert_output --partial "KINGDOM_TASK_ID='task-004'"
  rm -f "$MOCK_LOG"
}

@test "spawn-soldier: exports KINGDOM_RESULT_PATH in tmux command" {
  export MOCK_LOG="$(mktemp)"
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-005.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-005" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  run cat "$MOCK_LOG"
  assert_output --partial "KINGDOM_RESULT_PATH="
  rm -f "$MOCK_LOG"
}

@test "spawn-soldier: does not use --json-schema" {
  run grep -- '--json-schema' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_failure
}

@test "spawn-soldier: stdout goes to json, stderr to err" {
  run grep 'logs/sessions/' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
  # stdout → .json (session_id extraction), stderr → .err
  run grep '\.json' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
  run grep '\.err' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
}

@test "spawn-soldier: claude runtime uses --output-format json" {
  local cmd
  cmd=$(runtime_prepare_command "claude" "/tmp/prompt.md" "/tmp/work" "/tmp/out.json" "/tmp/err" "/tmp/session" "")
  [[ "$cmd" == *"--output-format json"* ]]
}

@test "spawn-soldier: extracts session_id from output" {
  run grep 'session_id' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
}

@test "spawn-soldier: accepts optional resume session_id" {
  run grep 'RESUME_SESSION_ID' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
  local cmd
  cmd=$(runtime_prepare_command "claude" "/tmp/prompt.md" "/tmp/work" "/tmp/out.json" "/tmp/err" "/tmp/session" "sess-123")
  [[ "$cmd" == *"--resume 'sess-123'"* ]]
  local codex_cmd
  codex_cmd=$(runtime_prepare_command "codex" "/tmp/prompt.md" "/tmp/work" "/tmp/out.json" "/tmp/err" "/tmp/session" "sess-456")
  [[ "$codex_cmd" == *"exec resume --json"* ]]
  [[ "$codex_cmd" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$codex_cmd" == *"'sess-456' -"* ]]
}

@test "spawn-soldier: supports codex runtime command" {
  local cmd
  cmd=$(runtime_prepare_command "codex" "/tmp/prompt.md" "/tmp/work" "/tmp/out.json" "/tmp/err" "/tmp/session" "")
  [[ "$cmd" == *"codex exec"* ]]
  [[ "$cmd" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
  run grep 'runtime_prepare_command' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
}

@test "spawn-soldier: runs with codex engine when configured" {
  mkdir -p "$BASE_DIR/workspace/gen-pr" "$BASE_DIR/config"
  local prompt_file="$BASE_DIR/state/prompts/task-codex.md"
  echo "test prompt" > "$prompt_file"
  export MOCK_LOG="$(mktemp)"
  export KINGDOM_RUNTIME_ENGINE="codex"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-codex" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  run cat "$MOCK_LOG"
  assert_output --partial "codex exec"
  unset KINGDOM_RUNTIME_ENGINE
  rm -f "$MOCK_LOG"
}

#!/usr/bin/env bats
# spawn-soldier.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Ensure common.sh is available at the expected path
  mkdir -p "$BASE_DIR/bin/lib"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/common.sh" "$BASE_DIR/bin/lib/"

  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
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

@test "spawn-soldier: creates .kingdom-task.json in work dir" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-004.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-004" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  assert [ -f "$BASE_DIR/workspace/gen-pr/.kingdom-task.json" ]
}

@test "spawn-soldier: .kingdom-task.json contains task_id and result_path" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-005.md"
  echo "test" > "$prompt_file"

  "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh" "task-005" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  local ctx="$BASE_DIR/workspace/gen-pr/.kingdom-task.json"
  run jq -r '.task_id' "$ctx"
  assert_output "task-005"
  run jq -r '.result_path' "$ctx"
  assert_output "$BASE_DIR/state/results/task-005-raw.json"
}

@test "spawn-soldier: does not use --json-schema" {
  run grep -- '--json-schema' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_failure
}

@test "spawn-soldier: stdout goes to session log" {
  run grep 'logs/sessions/' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
  # stdout+stderr both go to log (2>&1)
  run grep '2>&1' "${BATS_TEST_DIRNAME}/../bin/spawn-soldier.sh"
  assert_success
}

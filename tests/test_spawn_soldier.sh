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

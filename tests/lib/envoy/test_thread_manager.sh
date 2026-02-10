#!/usr/bin/env bats
# thread-manager.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/envoy/thread-manager.sh"
  # 초기 상태 파일
  echo '{}' > "$BASE_DIR/state/envoy/thread-mappings.json"
  echo '[]' > "$BASE_DIR/state/envoy/awaiting-responses.json"
}

teardown() {
  teardown_kingdom_env
}

# --- Thread Mapping ---

@test "thread-manager: save and get thread mapping" {
  save_thread_mapping "task-001" "1707300000.000100" "C123"
  run get_thread_mapping "task-001"
  assert_success
  run jq -r '.thread_ts' <<< "$(get_thread_mapping "task-001")"
  assert_output "1707300000.000100"
}

@test "thread-manager: get mapping returns empty for unknown task" {
  run get_thread_mapping "task-nonexistent"
  assert_output ""
}

@test "thread-manager: remove thread mapping" {
  save_thread_mapping "task-002" "1707300001.000200" "C456"
  remove_thread_mapping "task-002"
  run get_thread_mapping "task-002"
  assert_output ""
}

@test "thread-manager: multiple mappings coexist" {
  save_thread_mapping "task-A" "ts-A" "C1"
  save_thread_mapping "task-B" "ts-B" "C2"
  run jq -r '.["task-A"].thread_ts' "$BASE_DIR/state/envoy/thread-mappings.json"
  assert_output "ts-A"
  run jq -r '.["task-B"].thread_ts' "$BASE_DIR/state/envoy/thread-mappings.json"
  assert_output "ts-B"
}

# --- Awaiting Response ---

@test "thread-manager: add awaiting response" {
  add_awaiting_response "task-001" "ts-001" "C123"
  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
}

@test "thread-manager: awaiting response has asked_at field" {
  add_awaiting_response "task-001" "ts-001" "C123"
  run jq -r '.[0].asked_at' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "thread-manager: remove awaiting response" {
  add_awaiting_response "task-001" "ts-001" "C123"
  add_awaiting_response "task-002" "ts-002" "C456"
  remove_awaiting_response "task-001"
  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
  run jq -r '.[0].task_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "task-002"
}

@test "thread-manager: remove from empty awaiting is safe" {
  run remove_awaiting_response "task-nonexistent"
  assert_success
}

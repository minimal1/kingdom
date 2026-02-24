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
  echo '{}' > "$BASE_DIR/state/envoy/conversation-threads.json"
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
  add_awaiting_response "task-001" "ts-001" "C123" '{}'
  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
}

@test "thread-manager: awaiting response has asked_at field" {
  add_awaiting_response "task-001" "ts-001" "C123" '{}'
  run jq -r '.[0].asked_at' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "thread-manager: remove awaiting response" {
  add_awaiting_response "task-001" "ts-001" "C123" '{}'
  add_awaiting_response "task-002" "ts-002" "C456" '{}'
  remove_awaiting_response "task-001"
  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
  run jq -r '.[0].task_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "task-002"
}

@test "thread-manager: awaiting response stores reply_context" {
  local rc='{"general":"gen-pr","session_id":"sess-abc","repo":"querypie/frontend"}'
  add_awaiting_response "task-001" "ts-001" "C123" "$rc"
  run jq -r '.[0].reply_context.general' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "gen-pr"
  run jq -r '.[0].reply_context.session_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "sess-abc"
}

@test "thread-manager: awaiting response default reply_context is empty object" {
  add_awaiting_response "task-001" "ts-001" "C123"
  run jq -r '.[0].reply_context' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "{}"
}

@test "thread-manager: remove from empty awaiting is safe" {
  run remove_awaiting_response "task-nonexistent"
  assert_success
}

# --- Conversation Threads ---

@test "thread-manager: save and get conversation thread" {
  local rc='{"general":"gen-pr","session_id":"sess-abc"}'
  save_conversation_thread "1234.5678" "task-001" "D08XXX" "$rc" "3600"
  local result
  result=$(get_conversation_thread "1234.5678")
  run jq -r '.task_id' <<< "$result"
  assert_output "task-001"
  run jq -r '.channel' <<< "$result"
  assert_output "D08XXX"
  run jq -r '.reply_context.general' <<< "$result"
  assert_output "gen-pr"
}

@test "thread-manager: conversation thread has expires_at" {
  save_conversation_thread "1234.5678" "task-001" "D08XXX" '{}' "3600"
  local result
  result=$(get_conversation_thread "1234.5678")
  run jq -r '.expires_at' <<< "$result"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "thread-manager: conversation thread last_reply_ts defaults to thread_ts" {
  save_conversation_thread "1234.5678" "task-001" "D08XXX" '{}' "3600"
  local result
  result=$(get_conversation_thread "1234.5678")
  run jq -r '.last_reply_ts' <<< "$result"
  assert_output "1234.5678"
}

@test "thread-manager: update conversation thread last_reply_ts" {
  save_conversation_thread "1234.5678" "task-001" "D08XXX" '{}' "3600"
  update_conversation_thread "1234.5678" "1234.9999"
  local result
  result=$(get_conversation_thread "1234.5678")
  run jq -r '.last_reply_ts' <<< "$result"
  assert_output "1234.9999"
}

@test "thread-manager: remove conversation thread" {
  save_conversation_thread "1234.5678" "task-001" "D08XXX" '{}' "3600"
  remove_conversation_thread "1234.5678"
  run get_conversation_thread "1234.5678"
  assert_output ""
}

@test "thread-manager: get nonexistent conversation thread returns empty" {
  run get_conversation_thread "nonexistent.ts"
  assert_output ""
}

@test "thread-manager: multiple conversation threads coexist" {
  save_conversation_thread "ts-A" "task-A" "D01" '{"general":"gen-pr"}' "3600"
  save_conversation_thread "ts-B" "task-B" "D02" '{"general":"gen-briefing"}' "3600"
  run jq 'length' "$BASE_DIR/state/envoy/conversation-threads.json"
  assert_output "2"
  run jq -r '.["ts-A"].task_id' "$BASE_DIR/state/envoy/conversation-threads.json"
  assert_output "task-A"
  run jq -r '.["ts-B"].task_id' "$BASE_DIR/state/envoy/conversation-threads.json"
  assert_output "task-B"
}

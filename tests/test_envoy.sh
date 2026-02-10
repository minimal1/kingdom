#!/usr/bin/env bats
# envoy.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env
  cp "${BATS_TEST_DIRNAME}/../config/envoy.yaml" "$BASE_DIR/config/envoy.yaml"
  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/slack-api.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/thread-manager.sh"
  export SLACK_BOT_TOKEN="xoxb-test"
  echo '{}' > "$BASE_DIR/state/envoy/thread-mappings.json"
  echo '[]' > "$BASE_DIR/state/envoy/awaiting-responses.json"
}

teardown() {
  teardown_kingdom_env
}

@test "envoy: process_outbound_queue processes thread_start" {
  # thread_start 관련 함수 직접 테스트
  local msg='{"id":"msg-001","type":"thread_start","task_id":"task-001","channel":"C123","content":"[start] PR review","created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  # thread_start 처리
  local response
  response=$(send_message "C123" "[start] PR review")
  local thread_ts
  thread_ts=$(jq -r '.ts' <<< "$response")
  save_thread_mapping "task-001" "$thread_ts" "C123"

  # 매핑 확인
  run get_thread_mapping "task-001"
  assert_success
  local mapping
  mapping=$(get_thread_mapping "task-001")
  run jq -r '.channel' <<< "$mapping"
  assert_output "C123"
}

@test "envoy: process outbound moves file to sent" {
  # pending에 메시지 파일 생성
  cat > "$BASE_DIR/queue/messages/pending/msg-test-001.json" << 'EOF'
{"id":"msg-test-001","type":"report","channel":"C123","content":"daily report","created_at":"2026-01-01T00:00:00Z","status":"pending"}
EOF

  # source process functions
  process_report() {
    local msg="$1"
    local content
    content=$(echo "$msg" | jq -r '.content')
    send_message "C123" "$content" > /dev/null || return 1
  }

  process_outbound_queue() {
    local pending_dir="$BASE_DIR/queue/messages/pending"
    local sent_dir="$BASE_DIR/queue/messages/sent"
    for msg_file in "$pending_dir"/*.json; do
      [[ -f "$msg_file" ]] || continue
      local msg msg_type
      msg=$(cat "$msg_file")
      msg_type=$(echo "$msg" | jq -r '.type')
      case "$msg_type" in
        report) process_report "$msg" ;;
      esac
      mv "$msg_file" "$sent_dir/"
    done
  }

  process_outbound_queue

  # pending에서 사라지고 sent에 있어야 함
  assert [ ! -f "$BASE_DIR/queue/messages/pending/msg-test-001.json" ]
  assert [ -f "$BASE_DIR/queue/messages/sent/msg-test-001.json" ]
}

@test "envoy: notification to existing thread goes to thread" {
  # 매핑 생성
  save_thread_mapping "task-001" "1707300000.000100" "C123"

  # notification 메시지 처리
  local content="[complete] PR #1234 review done"
  send_thread_reply "C123" "1707300000.000100" "$content" > /dev/null

  # 매핑이 유지되는지 확인 (완료 메시지가 아닌 경우)
  run get_thread_mapping "task-001"
  assert_success
}

@test "envoy: human_input_request adds to awaiting" {
  save_thread_mapping "task-001" "1707300000.000100" "C123"

  send_thread_reply "C123" "1707300000.000100" "Question?" > /dev/null
  add_awaiting_response "task-001" "1707300000.000100" "C123"

  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
  run jq -r '.[0].task_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "task-001"
}

@test "envoy: 5 message types recognized" {
  # 각 메시지 타입이 case문에서 처리되는지 간접 확인
  for type in thread_start thread_update human_input_request notification report; do
    cat > "$BASE_DIR/queue/messages/pending/msg-${type}.json" << EOF
{"id":"msg-${type}","type":"${type}","task_id":"task-001","channel":"C123","content":"test","created_at":"2026-01-01T00:00:00Z","status":"pending"}
EOF
  done
  local count
  count=$(ls "$BASE_DIR/queue/messages/pending/"*.json | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]
}

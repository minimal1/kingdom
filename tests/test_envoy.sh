#!/usr/bin/env bats
# envoy.sh integration tests (Socket Mode only)

setup() {
  load 'test_helper'
  setup_kingdom_env
  cp "${BATS_TEST_DIRNAME}/../config/envoy.yaml" "$BASE_DIR/config/envoy.yaml"
  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/slack-api.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/thread-manager.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/message-processors.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/outbound.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/socket-inbox.sh"
  export SLACK_BOT_TOKEN="xoxb-test"
  DEFAULT_CHANNEL="C_DEFAULT"
  CONV_TTL=3600
  echo '{}' > "$BASE_DIR/state/envoy/thread-mappings.json"
  echo '[]' > "$BASE_DIR/state/envoy/awaiting-responses.json"
  mkdir -p "$BASE_DIR/state/envoy/socket-inbox"
  mkdir -p "$BASE_DIR/state/envoy/outbox"
  mkdir -p "$BASE_DIR/state/envoy/outbox-results"
  echo '{}' > "$BASE_DIR/state/envoy/conversation-threads.json"
  CONV_FILE="$BASE_DIR/state/envoy/conversation-threads.json"
  AWAITING_FILE="$BASE_DIR/state/envoy/awaiting-responses.json"
}

teardown() {
  teardown_kingdom_env
}

respond_outbox_at() {
  local ordinal="$1"
  local result_json="$2"
  (
    local outbox_file=""
    local attempts=0
    while :; do
      outbox_file=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' | sort | sed -n "${ordinal}p")
      [ -n "$outbox_file" ] && break
      attempts=$((attempts + 1))
      [ "$attempts" -ge 100 ] && exit 1
      sleep 0.05
    done
    local msg_id
    msg_id=$(jq -r '.msg_id' "$outbox_file")
    printf '%s\n' "$result_json" | jq --arg mid "$msg_id" '.msg_id = $mid' > "$BASE_DIR/state/envoy/outbox-results/${msg_id}.json"
  ) &
}

@test "envoy: process_outbound_queue processes thread_start" {
  cat > "$BASE_DIR/queue/messages/pending/msg-001.json" << 'EOF'
{"id":"msg-001","type":"thread_start","task_id":"task-001","channel":"U_TEST_USER","content":"[start] PR review","created_at":"2026-01-01T00:00:00Z","status":"pending"}
EOF

  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000100","channel":"D_MOCK_DM"}'
  respond_outbox_at 2 '{"ok":true,"channel":"D_MOCK_DM"}'

  process_outbound_queue

  assert [ -f "$BASE_DIR/queue/messages/sent/msg-001.json" ]
  local mapping
  mapping=$(get_thread_mapping "task-001")
  run jq -r '.channel' <<< "$mapping"
  assert_output "D_MOCK_DM"
}

@test "envoy: human_input_request adds to awaiting" {
  save_thread_mapping "task-001" "1707300000.000100" "C123"
  local msg='{"id":"msg-human","type":"human_input_request","task_id":"task-001","content":"Question?","reply_context":{"general":"gen-pr"},"created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000101","channel":"C123"}'
  run process_human_input_request "$msg"
  assert_success

  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
}

@test "envoy: human_input_request DM fallback uses message channel/thread_ts" {
  local msg='{"id":"msg-dm-human","type":"human_input_request","task_id":"task-dm-001","channel":"D999","thread_ts":"1707300000.000200","content":"[question] 리뷰할 PR 번호를 지정해주세요.","reply_context":{"general":"gen-pr","session_id":"sess-dm","repo":"chequer/qp"},"created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000201","channel":"D999"}'
  run process_human_input_request "$msg"
  assert_success

  run jq -r '.[0].channel' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "D999"
}

@test "envoy: update_source_reactions removes eyes and adds final emoji" {
  local msg='{"source_ref":{"channel":"D999","message_ts":"1707300000.000100"},"content":"test"}'
  respond_outbox_at 1 '{"ok":true,"channel":"D999"}'
  respond_outbox_at 2 '{"ok":true,"channel":"D999"}'

  run update_source_reactions "$msg" "white_check_mark"
  assert_success
  local actions
  actions=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' -print0 | xargs -0 jq -r '.action' | sort)
  echo "$actions" | grep -q '^add_reaction$'
  echo "$actions" | grep -q '^remove_reaction$'
}

@test "envoy: thread_start with existing thread_ts creates mapping" {
  local msg='{"id":"msg-dm-start","type":"thread_start","task_id":"task-dm-mapping","channel":"D08XXX","thread_ts":"1234.5678","content":"📋 gen-herald | task-dm-mapping","created_at":"2026-01-01T00:00:00Z","status":"pending"}'
  respond_outbox_at 1 '{"ok":true,"ts":"1234.5679","channel":"D08XXX"}'

  run process_thread_start "$msg"
  assert_success

  local mapping
  mapping=$(get_thread_mapping "task-dm-mapping")
  run jq -r '.thread_ts' <<< "$mapping"
  assert_output "1234.5678"
}

@test "envoy: notification success updates thread parent reaction" {
  save_thread_mapping "task-react-002" "1707300000.000200" "C123"
  local msg='{"id":"msg-notif-001","type":"notification","task_id":"task-react-002","content":"✅ 작업 완료","created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000201","channel":"C123"}'
  respond_outbox_at 2 '{"ok":true,"channel":"C123"}'
  respond_outbox_at 3 '{"ok":true,"channel":"C123"}'

  run process_notification "$msg"
  assert_success
  local actions
  actions=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' -print0 | xargs -0 jq -r '.action' | sort)
  echo "$actions" | grep -q '^add_reaction$'
  echo "$actions" | grep -q '^remove_reaction$'
}

@test "envoy: check_socket_inbox processes message events" {
  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-001.json" << 'EOF'
{"type":"message","channel":"D123","user_id":"U_USER","text":"hello kingdom","ts":"1707300000.000100","event_ts":"1707300000.000100"}
EOF
  respond_outbox_at 1 '{"ok":true,"channel":"D123"}'

  check_socket_inbox

  local evt_file="$BASE_DIR/queue/events/pending/evt-slack-msg-1707300000-000100.json"
  assert [ -f "$evt_file" ]
  run jq -r '.type' "$evt_file"
  assert_output "slack.channel.message"
}

@test "envoy: check_socket_inbox processes app_mention events" {
  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-mention.json" << 'EOF'
{"type":"app_mention","channel":"C123","user_id":"U_USER","text":"@kingdom hello","ts":"1707300000.000200","event_ts":"1707300000.000200"}
EOF
  respond_outbox_at 1 '{"ok":true,"channel":"C123"}'

  check_socket_inbox

  local evt_file="$BASE_DIR/queue/events/pending/evt-slack-mention-1707300000-000200.json"
  assert [ -f "$evt_file" ]
  run jq -r '.type' "$evt_file"
  assert_output "slack.app_mention"
}

@test "envoy: check_socket_inbox matches thread_reply to awaiting" {
  add_awaiting_response "task-123" "1707300000.000300" "C123" '{"general":"gen-pr","session_id":"sess-123"}'

  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-reply.json" << 'EOF'
{"type":"thread_reply","channel":"C123","user_id":"U_USER","text":"include it","ts":"1707300001.000000","thread_ts":"1707300000.000300","event_ts":"1707300001.000000"}
EOF

  check_socket_inbox

  local evt_file
  evt_file=$(ls "$BASE_DIR/queue/events/pending"/evt-slack-reply-*.json | head -1)
  assert [ -f "$evt_file" ]
  run jq -r '.payload.reply_context.general' "$evt_file"
  assert_output "gen-pr"
}

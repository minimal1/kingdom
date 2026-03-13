#!/usr/bin/env bats
# slack-api.sh unit tests (Socket Mode only)

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/envoy/slack-api.sh"
  export SLACK_BOT_TOKEN="xoxb-test-token"
  mkdir -p "$BASE_DIR/state/envoy/outbox" "$BASE_DIR/state/envoy/outbox-results"
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

@test "slack-api: send_message writes outbox action and returns result" {
  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000100","channel":"C123"}'

  local result
  result=$(send_message "C123" "hello world")

  run jq -r '.ok' <<< "$result"
  assert_output "true"
  local outbox_file
  outbox_file=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' | head -1)
  run jq -r '.action' "$outbox_file"
  assert_output "send_message"
}

@test "slack-api: send_message returns ts" {
  respond_outbox_at 1 '{"ok":true,"ts":"1707300000.000100","channel":"C123"}'

  local result
  result=$(send_message "C123" "hello")
  run jq -r '.ts' <<< "$result"
  assert_output "1707300000.000100"
}

@test "slack-api: send_thread_reply includes thread_ts in outbox" {
  respond_outbox_at 1 '{"ok":true,"ts":"1707300001.000100","channel":"C123"}'

  send_thread_reply "C123" "1707300000.000100" "reply text" > /dev/null
  local outbox_file
  outbox_file=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' | head -1)
  run jq -r '.thread_ts' "$outbox_file"
  assert_output "1707300000.000100"
}

@test "slack-api: add_reaction writes emoji and timestamp to outbox" {
  respond_outbox_at 1 '{"ok":true,"channel":"D999"}'

  add_reaction "D999" "1707300000.000100" "white_check_mark" > /dev/null
  local outbox_file
  outbox_file=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' | head -1)
  run jq -r '.emoji' "$outbox_file"
  assert_output "white_check_mark"
  run jq -r '.message_ts' "$outbox_file"
  assert_output "1707300000.000100"
}

@test "slack-api: remove_reaction writes remove action to outbox" {
  respond_outbox_at 1 '{"ok":true,"channel":"D999"}'

  run remove_reaction "D999" "1707300000.000100" "eyes"
  assert_success
  local outbox_file
  outbox_file=$(find "$BASE_DIR/state/envoy/outbox" -maxdepth 1 -name '*.json' ! -name '.tmp-*' | head -1)
  run jq -r '.action' "$outbox_file"
  assert_output "remove_reaction"
}

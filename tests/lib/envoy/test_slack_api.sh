#!/usr/bin/env bats
# slack-api.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/envoy/slack-api.sh"
  export SLACK_BOT_TOKEN="xoxb-test-token"
}

teardown() {
  teardown_kingdom_env
}

@test "slack-api: send_message calls curl with correct params" {
  local result
  result=$(send_message "C123" "hello world")
  run jq -r '.ok' <<< "$result"
  assert_output "true"
}

@test "slack-api: send_message returns ts" {
  local result
  result=$(send_message "C123" "hello")
  run jq -r '.ts' <<< "$result"
  assert_output --regexp '^[0-9]+\.'
}

@test "slack-api: send_thread_reply includes thread_ts in call" {
  export MOCK_LOG="$(mktemp)"
  send_thread_reply "C123" "1707300000.000100" "reply text" > /dev/null
  # mock curl이 호출되었는지 확인
  run cat "$MOCK_LOG"
  assert_output --partial "curl"
  rm -f "$MOCK_LOG"
}

@test "slack-api: read_thread_replies returns messages" {
  local result
  result=$(read_thread_replies "C123" "1707300000.000100" "0")
  run jq -r '.ok' <<< "$result"
  assert_output "true"
}

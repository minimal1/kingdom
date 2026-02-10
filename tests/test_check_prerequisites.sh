#!/usr/bin/env bats
# check-prerequisites.sh tests

setup() {
  load 'test_helper'
  export MOCK_LOG="$(mktemp)"
}

teardown() {
  rm -f "$MOCK_LOG"
}

@test "check-prerequisites: full script runs with mocks" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  export GH_TOKEN="ghp_test"
  export JIRA_API_TOKEN="test"
  export JIRA_URL="https://chequer.atlassian.net"
  export SLACK_BOT_TOKEN="xoxb-test"
  # claude mock은 PATH에 있으므로 OK가 나옴
  run "${BATS_TEST_DIRNAME}/../bin/check-prerequisites.sh"
  assert_output --partial "Kingdom Prerequisites Check"
  assert_output --partial "[OK]"
  assert_output --partial "jq"
}

@test "check-prerequisites: jq version detected" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  export GH_TOKEN="ghp_test"
  export JIRA_API_TOKEN="test"
  export JIRA_URL="https://chequer.atlassian.net"
  export SLACK_BOT_TOKEN="xoxb-test"
  run "${BATS_TEST_DIRNAME}/../bin/check-prerequisites.sh"
  # jq가 실제로 설치되어 있으므로 OK + 버전이 출력
  assert_output --partial "[OK]   jq"
}

@test "check-prerequisites: Jira mock returns Eddy" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  export JIRA_API_TOKEN="test-token"
  export JIRA_URL="https://chequer.atlassian.net"
  run bash -c 'curl -s -u "eddy@chequer.io:test" "$JIRA_URL/rest/api/3/myself" | jq -r ".displayName"'
  assert_output "Eddy"
}

@test "check-prerequisites: Slack mock returns ok=true" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  export SLACK_BOT_TOKEN="xoxb-test"
  run bash -c 'curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test | jq -r ".ok"'
  assert_output "true"
}

@test "check-prerequisites: missing env shows FAIL for Jira" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  export GH_TOKEN="ghp_test"
  unset JIRA_API_TOKEN 2>/dev/null || true
  unset JIRA_URL 2>/dev/null || true
  export SLACK_BOT_TOKEN="xoxb-test"
  run "${BATS_TEST_DIRNAME}/../bin/check-prerequisites.sh" || true
  assert_output --partial "[FAIL]"
  assert_output --partial "Jira"
}

@test "check-prerequisites: exit code 1 when something fails" {
  export PATH="${BATS_TEST_DIRNAME}/mocks:$PATH"
  unset JIRA_API_TOKEN JIRA_URL SLACK_BOT_TOKEN GH_TOKEN 2>/dev/null || true
  run "${BATS_TEST_DIRNAME}/../bin/check-prerequisites.sh"
  assert_failure
}

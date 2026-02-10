#!/usr/bin/env bats
# jira-watcher.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/sentinel/watcher-common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/sentinel/jira-watcher.sh"
  cp "${BATS_TEST_DIRNAME}/../../../config/sentinel.yaml" "$BASE_DIR/config/sentinel.yaml"
}

teardown() {
  teardown_kingdom_env
}

@test "jira: parse converts search result to events" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq 'length' <<< "$events"
  assert_output "2"
}

@test "jira: parse first-seen ticket becomes assigned type" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].type' <<< "$events"
  assert_output "jira.ticket.assigned"
}

@test "jira: parse known ticket with status change becomes updated" {
  save_state "jira" '{"known_issues":{"QP-1234":{"status":"To Do"}}}'
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].type' <<< "$events"
  assert_output "jira.ticket.updated"
}

@test "jira: parse event ID pattern is evt-jira-{key}-{ts}" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].id' <<< "$events"
  assert_output --regexp '^evt-jira-QP-1234-[0-9]+$'
}

@test "jira: parse includes payload fields" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].payload.ticket_key' <<< "$events"
  assert_output "QP-1234"
  run jq -r '.[0].payload.summary' <<< "$events"
  assert_output "Implement dark mode for settings page"
}

@test "jira: parse sets priority to normal" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].priority' <<< "$events"
  assert_output "normal"
}

@test "jira: parse updates known_issues state" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  jira_parse "$raw" > /dev/null
  local state
  state=$(load_state "jira")
  run jq -r '.known_issues["QP-1234"].status' <<< "$state"
  assert_output "In Progress"
}

@test "jira: parse returns empty for zero results" {
  run jira_parse '{"issues":[],"total":0}'
  assert_output "[]"
}

@test "jira: parse includes url in payload" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")
  run jq -r '.[0].payload.url' <<< "$events"
  assert_output "https://chequer.atlassian.net/browse/QP-1234"
}

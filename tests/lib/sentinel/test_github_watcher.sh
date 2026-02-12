#!/usr/bin/env bats
# github-watcher.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/sentinel/watcher-common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/sentinel/github-watcher.sh"
  cp "${BATS_TEST_DIRNAME}/../../../config/sentinel.yaml" "$BASE_DIR/config/sentinel.yaml"
}

teardown() {
  teardown_kingdom_env
}

@test "github: parse converts notification to event" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].id' <<< "$events"
  assert_output "evt-github-12345678"
}

@test "github: parse maps review_requested to correct type" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].type' <<< "$events"
  assert_output "github.pr.review_requested"
}

@test "github: parse maps assign to correct type" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[1].type' <<< "$events"
  assert_output "github.issue.assigned"
}

@test "github: parse sets correct priority" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].priority' <<< "$events"
  assert_output "normal"
}

@test "github: parse includes repo in output" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].repo' <<< "$events"
  assert_output "chequer-io/querypie-frontend"
}

@test "github: parse filters by scope repos" {
  cat > "$BASE_DIR/config/sentinel.yaml" << 'EOF'
polling:
  github:
    interval_seconds: 60
    scope:
      repos:
        - chequer-io/other-repo
      filter_reasons:
        - review_requested
        - assign
EOF
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq 'length' <<< "$events"
  assert_output "0"
}

@test "github: parse returns empty for empty input" {
  run github_parse "[]"
  assert_output "[]"
}

@test "github: parse includes payload fields" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].payload.subject_title' <<< "$events"
  assert_output "feat: add user authentication"
}

@test "github: event ID pattern is evt-github-{id}" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].id' <<< "$events"
  assert_output --regexp '^evt-github-[0-9]+$'
}

@test "github: parse extracts pr_number from PullRequest URL" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].payload.pr_number' <<< "$events"
  assert_output "1234"
}

@test "github: parse extracts pr_number from Issue URL" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[1].payload.pr_number' <<< "$events"
  assert_output "999"
}

@test "github: parse PullRequest gets github.pr.* type" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[0].type' <<< "$events"
  assert_output --regexp '^github\.pr\.'
}

@test "github: parse Issue gets github.issue.* type" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/../../fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")
  run jq -r '.[1].type' <<< "$events"
  assert_output --regexp '^github\.issue\.'
}

# --- post_emit ---

@test "github: post_emit clears pending_read_ids" {
  # Setup: pending_read_ids in state
  save_state "github" '{"etag":"W/\"abc\"","pending_read_ids":["111","222"]}'

  # gh mock for PATCH (mark as read)
  gh() { return 0; }
  export -f gh

  github_post_emit

  local state
  state=$(load_state "github")
  run jq 'has("pending_read_ids")' <<< "$state"
  assert_output "false"
}

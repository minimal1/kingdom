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
  assert_output "github.pr.assigned"
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

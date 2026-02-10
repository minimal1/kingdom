#!/usr/bin/env bats
# sentinel.sh integration test (single loop iteration with mocks)

setup() {
  load 'test_helper'
  setup_kingdom_env
  cp "${BATS_TEST_DIRNAME}/../config/sentinel.yaml" "$BASE_DIR/config/sentinel.yaml"
  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/sentinel/watcher-common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/sentinel/github-watcher.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/sentinel/jira-watcher.sh"
}

teardown() {
  teardown_kingdom_env
}

@test "sentinel: github events emitted to pending queue" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")

  echo "$events" | jq -c '.[]' | while read -r event; do
    local event_id
    event_id=$(jq -r '.id' <<< "$event")
    if ! is_duplicate "$event_id"; then
      sentinel_emit_event "$event"
    fi
  done

  local count
  count=$(ls "$BASE_DIR/queue/events/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "sentinel: duplicate events are not re-emitted" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")

  # First pass
  echo "$events" | jq -c '.[]' | while read -r event; do
    local event_id
    event_id=$(jq -r '.id' <<< "$event")
    if ! is_duplicate "$event_id"; then
      sentinel_emit_event "$event"
    fi
  done

  # Second pass
  echo "$events" | jq -c '.[]' | while read -r event; do
    local event_id
    event_id=$(jq -r '.id' <<< "$event")
    if ! is_duplicate "$event_id"; then
      sentinel_emit_event "$event"
    fi
  done

  local count
  count=$(ls "$BASE_DIR/queue/events/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "sentinel: jira events emitted to pending queue" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/fixtures/jira-search-result.json")
  local events
  events=$(jira_parse "$raw")

  echo "$events" | jq -c '.[]' | while read -r event; do
    local event_id
    event_id=$(jq -r '.id' <<< "$event")
    if ! is_duplicate "$event_id"; then
      sentinel_emit_event "$event"
    fi
  done

  local count
  count=$(ls "$BASE_DIR/queue/events/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "sentinel: seen markers created for all emitted events" {
  local raw
  raw=$(cat "${BATS_TEST_DIRNAME}/fixtures/github-notification.json")
  local events
  events=$(github_parse "$raw")

  echo "$events" | jq -c '.[]' | while read -r event; do
    local event_id
    event_id=$(jq -r '.id' <<< "$event")
    if ! is_duplicate "$event_id"; then
      sentinel_emit_event "$event"
    fi
  done

  assert [ -f "$BASE_DIR/state/sentinel/seen/evt-github-12345678" ]
  assert [ -f "$BASE_DIR/state/sentinel/seen/evt-github-12345679" ]
}

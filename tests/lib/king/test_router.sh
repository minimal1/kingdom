#!/usr/bin/env bats
# router.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  # Copy general manifests
  install_test_general "gen-pr"
  install_test_general "gen-jira"
  install_test_general "gen-test"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/king/router.sh"
}

teardown() {
  # Clean up temp files
  [ -n "$ROUTING_TABLE_FILE" ] && rm -f "$ROUTING_TABLE_FILE"
  [ -n "$SCHEDULES_FILE" ] && rm -f "$SCHEDULES_FILE"
  teardown_kingdom_env
}

# --- load_general_manifests ---

@test "router: load_general_manifests builds routing table" {
  load_general_manifests
  run find_general "github.pr.review_requested"
  assert_success
  assert_output "gen-pr"
}

@test "router: routing table contains jira events" {
  load_general_manifests
  run find_general "jira.ticket.assigned"
  assert_success
  assert_output "gen-jira"

  run find_general "jira.ticket.updated"
  assert_success
  assert_output "gen-jira"
}

@test "router: routing table counts all event types" {
  load_general_manifests
  # gen-pr: 3 (review_requested, mentioned, assigned), gen-jira: 2 (assigned, updated) = 5
  run get_routing_table_count
  assert_output "5"
}

@test "router: schedules loaded from gen-test" {
  load_general_manifests
  local schedules
  schedules=$(get_schedules)
  [ -n "$schedules" ]
  [[ "$schedules" == gen-test\|* ]]
}

@test "router: duplicate subscription logs warning" {
  # Create a duplicate manifest
  cat > "$BASE_DIR/config/generals/gen-dup.yaml" << 'EOF'
name: gen-dup
subscribes:
  - github.pr.review_requested
schedules: []
EOF

  load_general_manifests
  run cat "$BASE_DIR/logs/system.log"
  assert_output --partial "already claimed"
}

# --- find_general ---

@test "router: find_general exact match" {
  load_general_manifests
  run find_general "github.pr.review_requested"
  assert_success
  assert_output "gen-pr"
}

@test "router: find_general jira match" {
  load_general_manifests
  run find_general "jira.ticket.assigned"
  assert_success
  assert_output "gen-jira"
}

@test "router: find_general no match returns failure" {
  load_general_manifests
  run find_general "unknown.event.type"
  assert_failure
}

# --- collect_and_sort_events ---

@test "router: collect_and_sort_events sorts by priority" {
  echo '{"id":"evt-1","priority":"low"}' > "$BASE_DIR/queue/events/pending/evt-1.json"
  echo '{"id":"evt-2","priority":"high"}' > "$BASE_DIR/queue/events/pending/evt-2.json"
  echo '{"id":"evt-3","priority":"normal"}' > "$BASE_DIR/queue/events/pending/evt-3.json"

  local result
  result=$(collect_and_sort_events "$BASE_DIR/queue/events/pending")

  local first
  first=$(echo "$result" | head -1)
  [[ "$first" == *"evt-2.json" ]]

  local last
  last=$(echo "$result" | tail -1)
  [[ "$last" == *"evt-1.json" ]]
}

@test "router: collect_and_sort_events empty dir returns empty" {
  local result
  result=$(collect_and_sort_events "$BASE_DIR/queue/events/pending")
  [ -z "$result" ]
}

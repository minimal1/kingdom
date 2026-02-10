#!/usr/bin/env bats
# resource-check.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/king/resource-check.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- get_resource_health ---

@test "resource-check: green when resources.json has green" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"green\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"
  run get_resource_health
  assert_output "green"
}

@test "resource-check: yellow when resources.json has yellow" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"yellow\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"
  run get_resource_health
  assert_output "yellow"
}

@test "resource-check: green when resources.json missing" {
  rm -f "$BASE_DIR/state/resources.json"
  run get_resource_health
  assert_output "green"
}

@test "resource-check: green when no timestamp field" {
  echo '{"health":"yellow"}' > "$BASE_DIR/state/resources.json"
  run get_resource_health
  assert_output "green"
}

@test "resource-check: orange when timestamp stale (>120s)" {
  # Set timestamp to 200 seconds ago
  local old_ts
  if [[ "$(uname -s)" == "Darwin" ]]; then
    old_ts=$(date -u -v-200S +%Y-%m-%dT%H:%M:%SZ)
  else
    old_ts=$(date -u -d '200 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  fi
  echo "{\"health\":\"green\",\"timestamp\":\"$old_ts\"}" > "$BASE_DIR/state/resources.json"
  run get_resource_health
  assert_output "orange"
}

# --- can_accept_task ---

@test "resource-check: green accepts all priorities" {
  run can_accept_task "green" "low"
  assert_success
  run can_accept_task "green" "normal"
  assert_success
  run can_accept_task "green" "high"
  assert_success
}

@test "resource-check: yellow accepts only high" {
  run can_accept_task "yellow" "high"
  assert_success
  run can_accept_task "yellow" "normal"
  assert_failure
  run can_accept_task "yellow" "low"
  assert_failure
}

@test "resource-check: orange rejects all" {
  run can_accept_task "orange" "high"
  assert_failure
  run can_accept_task "orange" "normal"
  assert_failure
}

@test "resource-check: red rejects all" {
  run can_accept_task "red" "high"
  assert_failure
  run can_accept_task "red" "low"
  assert_failure
}

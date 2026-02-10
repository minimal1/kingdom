#!/usr/bin/env bats
# init-dirs.sh tests

setup() {
  load 'test_helper'
  export BASE_DIR="$(mktemp -d)"
  export KINGDOM_BASE_DIR="$BASE_DIR"
}

teardown() {
  if [[ -n "$BASE_DIR" && "$BASE_DIR" == /tmp/* ]]; then
    rm -rf "$BASE_DIR"
  fi
}

@test "init-dirs: creates queue/events directories" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_success
  assert [ -d "$BASE_DIR/queue/events/pending" ]
  assert [ -d "$BASE_DIR/queue/events/dispatched" ]
  assert [ -d "$BASE_DIR/queue/events/completed" ]
}

@test "init-dirs: creates queue/tasks directories" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_success
  assert [ -d "$BASE_DIR/queue/tasks/pending" ]
  assert [ -d "$BASE_DIR/queue/tasks/in_progress" ]
  assert [ -d "$BASE_DIR/queue/tasks/completed" ]
}

@test "init-dirs: creates queue/messages directories" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_success
  assert [ -d "$BASE_DIR/queue/messages/pending" ]
  assert [ -d "$BASE_DIR/queue/messages/sent" ]
}

@test "init-dirs: creates state directories" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_success
  assert [ -d "$BASE_DIR/state/king" ]
  assert [ -d "$BASE_DIR/state/sentinel/seen" ]
  assert [ -d "$BASE_DIR/state/envoy" ]
  assert [ -d "$BASE_DIR/state/chamberlain" ]
  assert [ -d "$BASE_DIR/state/results" ]
  assert [ -d "$BASE_DIR/state/prompts" ]
}

@test "init-dirs: creates memory directories" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_success
  assert [ -d "$BASE_DIR/memory/shared" ]
  assert [ -d "$BASE_DIR/memory/generals/gen-pr" ]
  assert [ -d "$BASE_DIR/memory/generals/gen-jira" ]
  assert [ -d "$BASE_DIR/memory/generals/gen-test" ]
}

@test "init-dirs: creates initial state files" {
  "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" > /dev/null
  assert [ -f "$BASE_DIR/state/sessions.json" ]
  assert [ -f "$BASE_DIR/state/resources.json" ]
  assert [ -f "$BASE_DIR/state/king/task-seq" ]
  assert [ -f "$BASE_DIR/state/king/msg-seq" ]
  assert [ -f "$BASE_DIR/state/king/schedule-sent.json" ]
  assert [ -f "$BASE_DIR/state/envoy/thread-mappings.json" ]
  assert [ -f "$BASE_DIR/state/envoy/awaiting-responses.json" ]
  assert [ -f "$BASE_DIR/state/chamberlain/events-offset" ]
}

@test "init-dirs: resources.json has correct schema" {
  "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" > /dev/null
  run jq -r '.health' "$BASE_DIR/state/resources.json"
  assert_output "green"
  run jq -r '.updated_at' "$BASE_DIR/state/resources.json"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "init-dirs: king sequences start at 0" {
  "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" > /dev/null
  run cat "$BASE_DIR/state/king/task-seq"
  assert_output "0"
  run cat "$BASE_DIR/state/king/msg-seq"
  assert_output "0"
}

@test "init-dirs: is idempotent" {
  "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" > /dev/null
  # Modify a state file
  echo "5" > "$BASE_DIR/state/king/task-seq"
  # Run again
  "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh" > /dev/null
  # Should NOT overwrite existing file
  run cat "$BASE_DIR/state/king/task-seq"
  assert_output "5"
}

@test "init-dirs: output message" {
  run "${BATS_TEST_DIRNAME}/../bin/init-dirs.sh"
  assert_output --partial "Kingdom directories initialized"
}

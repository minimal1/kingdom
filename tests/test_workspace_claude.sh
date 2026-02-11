#!/usr/bin/env bats
# workspace CLAUDE.md tests

setup() {
  load 'test_helper'
}

@test "workspace-claude: CLAUDE.md source exists in config" {
  assert [ -f "${BATS_TEST_DIRNAME}/../config/workspace-claude.md" ]
}

@test "workspace-claude: CLAUDE.md contains result schema instructions" {
  run grep 'status.*success.*failed.*needs_human' "${BATS_TEST_DIRNAME}/../config/workspace-claude.md"
  assert_success
}

@test "workspace-claude: CLAUDE.md references .kingdom-task.json" {
  run grep '.kingdom-task.json' "${BATS_TEST_DIRNAME}/../config/workspace-claude.md"
  assert_success
}

@test "workspace-claude: CLAUDE.md requires task_id, status, summary" {
  run grep 'task_id, status, summary' "${BATS_TEST_DIRNAME}/../config/workspace-claude.md"
  assert_success
}

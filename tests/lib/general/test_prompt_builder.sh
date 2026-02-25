#!/usr/bin/env bats
# prompt-builder.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  cp -r "${BATS_TEST_DIRNAME}/../../../config/generals/templates" "$BASE_DIR/config/generals/"
  install_test_general "gen-pr"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"

  GENERAL_DOMAIN="gen-pr"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/general/prompt-builder.sh"
}

teardown() {
  teardown_kingdom_env
}

@test "prompt-builder: build_prompt uses domain template" {
  local task='{"id":"task-001","type":"github.pr.review_requested","repo":"chequer/qp","payload":{"pr_number":123}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"task-001"* ]] || [[ "$result" == *"123"* ]]
}

@test "prompt-builder: build_prompt replaces basic placeholders" {
  # Use a template with {{TASK_ID}} and {{REPO}}
  echo '# Task: {{TASK_ID}} for {{REPO}}' > "$BASE_DIR/config/generals/templates/gen-pr.md"

  local task='{"id":"task-001","type":"github.pr.review_requested","repo":"chequer/qp","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"task-001"* ]]
  [[ "$result" == *"chequer/qp"* ]]
}

@test "prompt-builder: build_prompt substitutes payload fields" {
  echo '/friday:review-pr {{payload.pr_number}}' > "$BASE_DIR/config/generals/templates/gen-pr.md"

  local task='{"id":"task-002","type":"test","repo":"","payload":{"pr_number":456}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"/friday:review-pr 456"* ]]
}

@test "prompt-builder: build_prompt substitutes multiple payload fields" {
  echo '{{payload.key1}} and {{payload.key2}}' > "$BASE_DIR/config/generals/templates/gen-pr.md"

  local task='{"id":"task-003","type":"test","repo":"","payload":{"key1":"hello","key2":"world"}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"hello"* ]]
  [[ "$result" == *"world"* ]]
}

@test "prompt-builder: build_prompt skips payload dump when template uses payload placeholders" {
  echo '/cmd {{payload.pr_number}}' > "$BASE_DIR/config/generals/templates/gen-pr.md"

  local task='{"id":"task-004","type":"test","repo":"","payload":{"pr_number":789}}'

  local result
  result=$(build_prompt "$task" "" "")
  # Should NOT contain the payload dump section
  [[ "$result" != *"## Task Payload"* ]]
}

@test "prompt-builder: build_prompt includes payload dump for templates without payload placeholders" {
  echo '# Task: {{TASK_ID}}' > "$BASE_DIR/config/generals/templates/gen-pr.md"

  local task='{"id":"task-005","type":"test","repo":"","payload":{"key":"value"}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"## Task Payload"* ]]
}

@test "prompt-builder: build_prompt does not include memory section (CLAUDE.md path guide)" {
  local task='{"id":"task-006","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task")
  [[ "$result" != *"Domain Memory"* ]]
}

@test "prompt-builder: build_prompt does not include repo context (CLAUDE.md path guide)" {
  local task='{"id":"task-007","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task")
  [[ "$result" != *"Repository Context"* ]]
}

@test "prompt-builder: build_prompt does not include output requirements" {
  local task='{"id":"task-008","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  # Output requirements removed (handled by --json-schema in spawn-soldier.sh)
  [[ "$result" != *"Output Requirements"* ]]
}

@test "prompt-builder: build_prompt falls back to default template" {
  GENERAL_DOMAIN="gen-nonexistent"
  local task='{"id":"task-009","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  # Should use default.md template
  [[ "$result" == *"task-009"* ]]
}

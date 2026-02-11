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
  local task='{"id":"task-001","type":"github.pr.review_requested","repo":"chequer/qp","payload":{"pr":123}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"task-001"* ]]
}

@test "prompt-builder: build_prompt replaces placeholders" {
  local task='{"id":"task-001","type":"github.pr.review_requested","repo":"chequer/qp","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"task-001"* ]]
  [[ "$result" == *"chequer/qp"* ]]
}

@test "prompt-builder: build_prompt includes payload section" {
  local task='{"id":"task-002","type":"test","repo":"","payload":{"key":"value"}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"Payload"* ]]
}

@test "prompt-builder: build_prompt includes memory section" {
  local task='{"id":"task-003","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "remember: no barrel exports" "")
  [[ "$result" == *"barrel exports"* ]]
}

@test "prompt-builder: build_prompt includes repo context" {
  local task='{"id":"task-004","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "TypeScript strict mode")
  [[ "$result" == *"TypeScript strict mode"* ]]
}

@test "prompt-builder: build_prompt includes output requirements" {
  local task='{"id":"task-005","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  [[ "$result" == *"raw.json"* ]]
}

@test "prompt-builder: build_prompt falls back to default template" {
  GENERAL_DOMAIN="gen-nonexistent"
  local task='{"id":"task-006","type":"test","repo":"","payload":{}}'

  local result
  result=$(build_prompt "$task" "" "")
  # Should use default.md template
  [[ "$result" == *"task-006"* ]]
}

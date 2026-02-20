#!/usr/bin/env bats
# metrics-collector.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  cp "${BATS_TEST_DIRNAME}/../../../config/chamberlain.yaml" "$BASE_DIR/config/"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/metrics-collector.sh"

  # Initialize sessions.json
  echo '[]' > "$BASE_DIR/state/sessions.json"

  # Initialize token-related variables (used by update_resources_json)
  ESTIMATED_DAILY_COST="0.00"
  TOKEN_STATUS="ok"
  DAILY_INPUT_TOKENS=0
  DAILY_OUTPUT_TOKENS=0
}

teardown() {
  teardown_kingdom_env
}

# --- get_current_health ---

@test "metrics: get_current_health returns green by default" {
  local result
  result=$(get_current_health)
  [ "$result" = "green" ]
}

@test "metrics: get_current_health reads from resources.json" {
  echo '{"health":"yellow"}' > "$BASE_DIR/state/resources.json"
  local result
  result=$(get_current_health)
  [ "$result" = "yellow" ]
}

@test "metrics: get_current_health returns green on missing file" {
  rm -f "$BASE_DIR/state/resources.json"
  local result
  result=$(get_current_health)
  [ "$result" = "green" ]
}

# --- evaluate_health ---

@test "metrics: evaluate_health returns green for low values" {
  CPU_PERCENT="30.0"
  MEMORY_PERCENT="40.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "green" ]
}

@test "metrics: evaluate_health returns yellow for medium CPU" {
  CPU_PERCENT="65.0"
  MEMORY_PERCENT="40.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "yellow" ]
}

@test "metrics: evaluate_health returns yellow for medium memory" {
  CPU_PERCENT="30.0"
  MEMORY_PERCENT="70.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "yellow" ]
}

@test "metrics: evaluate_health returns orange for high CPU" {
  CPU_PERCENT="85.0"
  MEMORY_PERCENT="40.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "orange" ]
}

@test "metrics: evaluate_health returns orange for high memory" {
  CPU_PERCENT="30.0"
  MEMORY_PERCENT="82.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "orange" ]
}

@test "metrics: evaluate_health returns red for very high CPU" {
  CPU_PERCENT="95.0"
  MEMORY_PERCENT="40.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "red" ]
}

@test "metrics: evaluate_health returns red for very high memory" {
  CPU_PERCENT="30.0"
  MEMORY_PERCENT="92.0"

  local result
  result=$(evaluate_health)
  [ "$result" = "red" ]
}

# --- update_resources_json ---

@test "metrics: update_resources_json creates valid JSON" {
  CPU_PERCENT="45.0"
  MEMORY_PERCENT="60.0"
  DISK_PERCENT="35"
  LOAD_AVG="1.2,0.8,0.6"

  update_resources_json "green"

  assert [ -f "$BASE_DIR/state/resources.json" ]
  run jq -r '.health' "$BASE_DIR/state/resources.json"
  assert_output "green"
  # jq tonumber preserves decimals: "45.0" → 45 (int-like floats become int)
  run jq '.system.cpu_percent >= 45' "$BASE_DIR/state/resources.json"
  assert_output "true"
  run jq '.system.memory_percent >= 60' "$BASE_DIR/state/resources.json"
  assert_output "true"
}

@test "metrics: update_resources_json no tmp file remains" {
  CPU_PERCENT="50.0"
  MEMORY_PERCENT="50.0"
  DISK_PERCENT="30"
  LOAD_AVG="1.0,0.5,0.3"

  update_resources_json "yellow"

  assert [ ! -f "$BASE_DIR/state/resources.json.tmp" ]
}

@test "metrics: update_resources_json includes sessions info" {
  echo '[{"id":"soldier-1","task_id":"task-001"}]' > "$BASE_DIR/state/sessions.json"
  CPU_PERCENT="30.0"
  MEMORY_PERCENT="30.0"
  DISK_PERCENT="20"
  LOAD_AVG="0.5,0.3,0.2"

  update_resources_json "green"

  run jq -r '.sessions.soldiers_active' "$BASE_DIR/state/resources.json"
  assert_output "1"
}

# --- collect_metrics ---

@test "metrics: collect_metrics sets numeric variables" {
  collect_metrics

  # All should be numeric (or "0" fallback)
  [[ "$CPU_PERCENT" =~ ^[0-9]+\.?[0-9]*$ ]]
  [[ "$MEMORY_PERCENT" =~ ^[0-9]+\.?[0-9]*$ ]]
  [[ "$DISK_PERCENT" =~ ^[0-9]+$ ]]
}

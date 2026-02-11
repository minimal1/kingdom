#!/usr/bin/env bats
# watcher-common.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/sentinel/watcher-common.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- is_duplicate ---

@test "watcher-common: is_duplicate false when event not seen" {
  run is_duplicate "evt-test-new"
  assert_failure
}

@test "watcher-common: is_duplicate true when in pending" {
  echo '{}' > "$BASE_DIR/queue/events/pending/evt-test-001.json"
  run is_duplicate "evt-test-001"
  assert_success
}

@test "watcher-common: is_duplicate true when in dispatched" {
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-test-002.json"
  run is_duplicate "evt-test-002"
  assert_success
}

@test "watcher-common: is_duplicate true when in seen" {
  touch "$BASE_DIR/state/sentinel/seen/evt-test-003"
  run is_duplicate "evt-test-003"
  assert_success
}

# --- sentinel_emit_event ---

@test "watcher-common: sentinel_emit_event creates file in pending" {
  local event='{"id":"evt-test-010","type":"test.event","source":"test","priority":"normal","created_at":"2026-01-01T00:00:00Z","data":{}}'
  sentinel_emit_event "$event"
  assert [ -f "$BASE_DIR/queue/events/pending/evt-test-010.json" ]
}

@test "watcher-common: sentinel_emit_event creates seen marker" {
  local event='{"id":"evt-test-011","type":"test.event","source":"test","priority":"normal","created_at":"2026-01-01T00:00:00Z","data":{}}'
  sentinel_emit_event "$event"
  assert [ -f "$BASE_DIR/state/sentinel/seen/evt-test-011" ]
}

@test "watcher-common: sentinel_emit_event writes internal event" {
  local event='{"id":"evt-test-012","type":"test.event","source":"test","priority":"normal","created_at":"2026-01-01T00:00:00Z","data":{}}'
  sentinel_emit_event "$event"
  assert [ -f "$BASE_DIR/logs/events.log" ]
  run jq -r '.type' "$BASE_DIR/logs/events.log"
  assert_output "event.detected"
}

# --- load_state / save_state ---

@test "watcher-common: load_state returns empty obj for missing file" {
  run load_state "nonexistent"
  assert_output "{}"
}

@test "watcher-common: save_state and load_state roundtrip" {
  save_state "test-watcher" '{"etag":"abc123"}'
  run load_state "test-watcher"
  assert_output '{"etag":"abc123"}'
}

@test "watcher-common: get_interval reads config" {
  # sentinel.yaml에 github interval이 60으로 설정되어야 함
  cp "${BATS_TEST_DIRNAME}/../../../config/sentinel.yaml" "$BASE_DIR/config/sentinel.yaml"
  run get_interval "github"
  assert_output "60"
}

@test "watcher-common: get_interval reads jira config" {
  # jira가 활성화된 별도 yaml을 사용 (실제 config에서는 주석 처리됨)
  cat > "$BASE_DIR/config/sentinel.yaml" <<'EOF'
polling:
  github:
    interval_seconds: 60
  jira:
    interval_seconds: 300
EOF
  run get_interval "jira"
  assert_output "300"
}

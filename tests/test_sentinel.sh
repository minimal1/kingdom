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

@test "sentinel: no hardcoded WATCHERS array" {
  # sentinel.sh에 WATCHERS=("github" "jira") 같은 하드코딩이 없어야 함
  run grep -E 'WATCHERS=\(' "${BATS_TEST_DIRNAME}/../bin/sentinel.sh"
  # grep 결과에 하드코딩된 watcher 이름이 포함되지 않아야 함
  refute_output --partial '"github"'
  refute_output --partial '"jira"'
}

@test "sentinel: loads watchers from sentinel.yaml" {
  # yaml에 github만 있을 때 github만 로드되는지 확인
  local yaml="$BASE_DIR/config/sentinel.yaml"
  cat > "$yaml" <<'EOF'
polling:
  github:
    interval_seconds: 60
    scope:
      repos:
        - chequer-io/querypie-frontend
EOF

  # watcher 스크립트를 테스트 환경에 복사
  mkdir -p "$BASE_DIR/bin/lib/sentinel"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/sentinel/"*-watcher.sh "$BASE_DIR/bin/lib/sentinel/"

  local watchers=()
  for key in $(yq eval '.polling | keys | .[]' "$yaml" 2>/dev/null); do
    if [ -f "$BASE_DIR/bin/lib/sentinel/${key}-watcher.sh" ]; then
      watchers+=("$key")
    fi
  done

  [ ${#watchers[@]} -eq 1 ]
  [ "${watchers[0]}" = "github" ]
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

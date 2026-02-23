#!/usr/bin/env bats
# event-consumer.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  cp "${BATS_TEST_DIRNAME}/../../../config/chamberlain.yaml" "$BASE_DIR/config/"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/auto-recovery.sh"
  source "${BATS_TEST_DIRNAME}/../../../bin/lib/chamberlain/event-consumer.sh"
}

teardown() {
  teardown_kingdom_env
}

# --- consume_internal_events ---

@test "event-consumer: processes new events after offset" {
  # Write 3 events
  echo '{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"
  echo '{"ts":"2026-02-07T10:01:00Z","type":"task.failed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"
  echo '{"ts":"2026-02-07T10:02:00Z","type":"soldier.spawned","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"

  # Set offset to 0 (start)
  echo "0" > "$BASE_DIR/state/chamberlain/events-offset"

  consume_internal_events

  # Stats should be updated
  assert [ -f "$BASE_DIR/logs/analysis/stats.json" ]
  run jq -r '.totals.task_completed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "1"
  run jq -r '.totals.task_failed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "1"
}

@test "event-consumer: updates offset after processing" {
  echo '{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"
  echo '{"ts":"2026-02-07T10:01:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"

  echo "0" > "$BASE_DIR/state/chamberlain/events-offset"

  consume_internal_events

  local offset
  offset=$(cat "$BASE_DIR/state/chamberlain/events-offset")
  [ "$offset" = "2" ]
}

@test "event-consumer: skips when no new events" {
  echo '{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"

  # Offset already at end
  echo "1" > "$BASE_DIR/state/chamberlain/events-offset"

  consume_internal_events

  # Offset should not change
  local offset
  offset=$(cat "$BASE_DIR/state/chamberlain/events-offset")
  [ "$offset" = "1" ]
}

@test "event-consumer: handles missing events file" {
  rm -f "$BASE_DIR/logs/events.log"

  consume_internal_events

  # Should not error
  assert [ ! -f "$BASE_DIR/logs/analysis/stats.json" ]
}

@test "event-consumer: processes only new events (incremental)" {
  # Write 2 events initially
  echo '{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"
  echo '{"ts":"2026-02-07T10:01:00Z","type":"task.completed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"

  echo "0" > "$BASE_DIR/state/chamberlain/events-offset"
  consume_internal_events

  # Add 1 more event
  echo '{"ts":"2026-02-07T10:02:00Z","type":"task.failed","actor":"gen-pr","data":{}}' >> "$BASE_DIR/logs/events.log"

  consume_internal_events

  # Should accumulate: 2 completed + 1 failed
  run jq -r '.totals.task_completed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "2"
  run jq -r '.totals.task_failed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "1"
}

# --- aggregate_metrics ---

@test "event-consumer: aggregate_metrics counts event types" {
  local events
  events='{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}
{"ts":"2026-02-07T10:01:00Z","type":"task.completed","actor":"gen-pr","data":{}}
{"ts":"2026-02-07T10:02:00Z","type":"task.failed","actor":"gen-pr","data":{}}'

  aggregate_metrics "$events"

  assert [ -f "$BASE_DIR/logs/analysis/stats.json" ]
  run jq -r '.totals.task_completed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "2"
  run jq -r '.totals.task_failed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "1"
}

@test "event-consumer: aggregate_metrics accumulates with existing" {
  # Pre-existing stats
  echo '{"totals":{"task_completed":5,"task_failed":1,"soldier_spawned":6,"soldier_timeout":0}}' > "$BASE_DIR/logs/analysis/stats.json"

  local events='{"ts":"2026-02-07T10:00:00Z","type":"task.completed","actor":"gen-pr","data":{}}'

  aggregate_metrics "$events"

  run jq -r '.totals.task_completed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "6"
  run jq -r '.totals.task_failed' "$BASE_DIR/logs/analysis/stats.json"
  assert_output "1"
}

# --- detect_anomalies ---

@test "event-consumer: detect_anomalies detects consecutive failures" {
  # 3 failures from same actor (threshold = 3)
  local events
  events='{"ts":"2026-02-07T10:00:00Z","type":"task.failed","actor":"gen-pr","data":{}}
{"ts":"2026-02-07T10:01:00Z","type":"task.failed","actor":"gen-pr","data":{}}
{"ts":"2026-02-07T10:02:00Z","type":"task.failed","actor":"gen-pr","data":{}}'

  detect_anomalies "$events"

  # Should create alert
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -ge 1 ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  run jq -r '.content' "$msg_file"
  assert_output --partial "이상 감지"
  assert_output --partial "gen-pr"
}

@test "event-consumer: detect_anomalies no alert below threshold" {
  # Only 2 failures (threshold = 3)
  local events
  events='{"ts":"2026-02-07T10:00:00Z","type":"task.failed","actor":"gen-pr","data":{}}
{"ts":"2026-02-07T10:01:00Z","type":"task.failed","actor":"gen-pr","data":{}}'

  detect_anomalies "$events"

  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 0 ]
}

@test "event-consumer: detect_anomalies detects timeout spike" {
  # 5 timeouts (threshold = 5)
  local events=""
  for i in 1 2 3 4 5; do
    events+='{"ts":"2026-02-07T10:0'$i':00Z","type":"soldier.timeout","actor":"gen-pr","data":{}}
'
  done

  detect_anomalies "$events"

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]
  run jq -r '.content' "$msg_file"
  assert_output --partial "타임아웃"
}

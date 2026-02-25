#!/usr/bin/env bats
# Integration: Event → King → Task creation

setup() {
  load '../test_helper'
  setup_kingdom_env
  load 'integration_helper'
  setup_integration_env
}

teardown() {
  [ -n "$ROUTING_TABLE_FILE" ] && rm -f "$ROUTING_TABLE_FILE"
  [ -n "$SCHEDULES_FILE" ] && rm -f "$SCHEDULES_FILE"
  teardown_kingdom_env
}

@test "integration: sentinel event → king creates task + message" {
  # Simulate sentinel emitting a GitHub PR event
  jq -n '{
    id: "evt-github-12345678-2026-02-07T10:00:00Z",
    type: "github.pr.review_requested",
    source: "github", priority: "normal",
    repo: "chequer/qp",
    payload: {pr_number: 42, title: "Add feature X"}
  }' > "$BASE_DIR/queue/events/pending/evt-github-12345678-2026-02-07T10:00:00Z.json"

  # King processes events
  process_pending_events

  # Event dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-github-12345678-2026-02-07T10:00:00Z.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-github-12345678-2026-02-07T10:00:00Z.json" ]

  # Task created targeting gen-pr
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
  run jq -r '.repo' "$task_file"
  assert_output "chequer/qp"
  run jq -r '.payload.pr_number' "$task_file"
  assert_output "42"

  # thread_start message created
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
}

@test "integration: unsubscribed jira event is discarded" {
  jq -n '{
    id: "evt-jira-QP-100", type: "jira.ticket.assigned",
    source: "jira", priority: "normal", repo: "chequer/qp",
    payload: {ticket_key: "QP-100"}
  }' > "$BASE_DIR/queue/events/pending/evt-jira-QP-100.json"

  process_pending_events

  # No matching general → event moved to completed (discarded)
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-jira-QP-100.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-jira-QP-100.json" ]

  # No task created
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

@test "integration: multiple events — subscribed dispatched, unsubscribed discarded" {
  jq -n '{id: "evt-1", type: "github.pr.review_requested", source: "github", priority: "low", repo: "chequer/qp", payload: {}}' \
    > "$BASE_DIR/queue/events/pending/evt-1.json"
  jq -n '{id: "evt-2", type: "jira.ticket.assigned", source: "jira", priority: "high", repo: "chequer/qp", payload: {}}' \
    > "$BASE_DIR/queue/events/pending/evt-2.json"

  process_pending_events

  # PR event dispatched (gen-pr subscribes)
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-1.json" ]
  # Jira event discarded (no subscriber)
  assert [ -f "$BASE_DIR/queue/events/completed/evt-2.json" ]

  # Only 1 task created (for PR event)
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 1 ]
}

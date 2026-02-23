#!/usr/bin/env bats
# Integration: Full pipeline — Event → King → General → Soldier → Result → Notification

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

@test "full pipeline: github PR event → task → soldier → success → notification" {
  # Phase 1: Sentinel emits event
  local today
  today=$(date +%Y%m%d)

  jq -n '{
    id: "evt-github-99887766",
    type: "github.pr.review_requested",
    source: "github", priority: "normal",
    repo: "chequer/qp",
    payload: {pr_number: 99, title: "Refactor auth module"}
  }' > "$BASE_DIR/queue/events/pending/evt-github-99887766.json"

  # Phase 2: King processes event → creates task + thread_start message
  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-github-99887766.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-github-99887766.json" ]

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  assert [ -f "$task_file" ]
  local task_id
  task_id=$(jq -r '.id' "$task_file")
  [[ "$task_id" == task-${today}-* ]]

  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
  run jq -r '.payload.pr_number' "$task_file"
  assert_output "99"

  # thread_start message should exist
  local thread_msg
  thread_msg=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$thread_msg"
  assert_output "thread_start"
  run jq -r '.content' "$thread_msg"
  assert_output --partial "github.pr.review_requested"

  # Phase 3: General picks task
  GENERAL_DOMAIN="gen-pr"
  local picked
  picked=$(pick_next_task "gen-pr")
  assert [ -f "$picked" ]

  local task
  task=$(cat "$picked")
  local picked_task_id
  picked_task_id=$(echo "$task" | jq -r '.id')
  [[ "$picked_task_id" == "$task_id" ]]

  # Move to in_progress (as general's main_loop would)
  mv "$picked" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"

  # Phase 4: Build prompt + spawn mock soldier
  local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
  build_prompt "$task" "" "" > "$prompt_file"
  assert [ -f "$prompt_file" ]

  mkdir -p "$BASE_DIR/workspace/gen-pr"
  spawn_soldier "$task_id" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  # Phase 5: General reports success to king
  report_to_king "$task_id" "success" "PR reviewed and approved" ""

  assert [ -f "$BASE_DIR/state/results/${task_id}.json" ]
  run jq -r '.status' "$BASE_DIR/state/results/${task_id}.json"
  assert_output "success"

  # Phase 6: King processes result → task completed + notification
  check_task_results

  # Task moved to completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/${task_id}.json" ]

  # Notification message created (in addition to thread_start)
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  # thread_start was already created, now notification added
  # (thread_start might still be in pending if envoy hasn't processed it)
  local notification_file
  notification_file=$(ls -t "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$notification_file"
  assert_output "notification"
  run jq -r '.content' "$notification_file"
  assert_output --partial "[complete]"
  assert_output --partial "PR reviewed and approved"
}

@test "full pipeline: github PR event → task → soldier → failure → notification" {
  local today
  today=$(date +%Y%m%d)

  jq -n '{
    id: "evt-github-QP-200", type: "github.pr.review_requested",
    source: "github", priority: "high",
    repo: "chequer/qp",
    payload: {pr_number: 200, title: "Fix login bug"}
  }' > "$BASE_DIR/queue/events/pending/evt-github-QP-200.json"

  # King processes event
  process_pending_events

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  local task_id
  task_id=$(jq -r '.id' "$task_file")

  # General picks + processes task
  GENERAL_DOMAIN="gen-pr"
  mv "$task_file" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"

  # General reports failure
  local raw_result="{\"task_id\":\"${task_id}\",\"status\":\"failed\",\"error\":\"compilation error in AuthService.java\"}"
  report_to_king "$task_id" "failed" "" "$raw_result"

  # King processes result
  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/${task_id}.json" ]

  # Notification contains failure info
  local notification_file
  notification_file=$(ls -t "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.content' "$notification_file"
  assert_output --partial "[failed]"
  assert_output --partial "compilation error"
}

@test "full pipeline: event dispatched event also moves to completed" {
  local today
  today=$(date +%Y%m%d)

  jq -n '{
    id: "evt-lifecycle-001", type: "github.pr.review_requested",
    source: "github", priority: "normal",
    repo: "chequer/qp",
    payload: {pr_number: 55}
  }' > "$BASE_DIR/queue/events/pending/evt-lifecycle-001.json"

  # King dispatches
  process_pending_events
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-lifecycle-001.json" ]

  # Get task ID
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  local task_id
  task_id=$(jq -r '.id' "$task_file")

  # General processes → success
  mv "$task_file" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  report_to_king "$task_id" "success" "Done" ""
  check_task_results

  # Event should move from dispatched → completed
  assert [ ! -f "$BASE_DIR/queue/events/dispatched/evt-lifecycle-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-lifecycle-001.json" ]
}

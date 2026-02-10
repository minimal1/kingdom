#!/usr/bin/env bats
# Integration: needs_human flow — Escalation → Human Input → Resume

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

@test "needs_human: general escalates → king creates human_input_request" {
  local today
  today=$(date +%Y%m%d)
  local task_id="task-${today}-050"

  # Task in in_progress
  cat > "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" << EOF
{"id":"${task_id}","event_id":"evt-050","target_general":"gen-pr","type":"github.pr.review_requested","repo":"chequer/qp","payload":{"pr_number":77},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-050.json"

  GENERAL_DOMAIN="gen-pr"

  # General's soldier returns needs_human result
  local raw_result
  raw_result=$(jq -n \
    --arg tid "$task_id" \
    --arg q "Should we use JWT or session-based auth?" \
    '{task_id: $tid, status: "needs_human", question: $q}')

  # General calls escalate_to_king
  escalate_to_king "$task_id" "$raw_result"

  # Checkpoint file created
  local checkpoint_file="$BASE_DIR/state/results/${task_id}-checkpoint.json"
  assert [ -f "$checkpoint_file" ]
  run jq -r '.target_general' "$checkpoint_file"
  assert_output "gen-pr"

  # Result file created with needs_human status
  local result_file="$BASE_DIR/state/results/${task_id}.json"
  assert [ -f "$result_file" ]
  run jq -r '.status' "$result_file"
  assert_output "needs_human"
  run jq -r '.checkpoint_path' "$result_file"
  assert_output "$checkpoint_file"

  # King processes result → creates human_input_request message
  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"
  run jq -r '.content' "$msg_file"
  assert_output --partial "[question]"
  assert_output --partial "JWT or session-based auth"
}

@test "needs_human: human responds → king creates resume task" {
  local today
  today=$(date +%Y%m%d)
  local original_task_id="task-${today}-060"

  # Original task already in in_progress (not yet moved — king skips if not in in_progress)
  cat > "$BASE_DIR/queue/tasks/in_progress/${original_task_id}.json" << EOF
{"id":"${original_task_id}","event_id":"evt-060","target_general":"gen-pr","type":"github.pr.review_requested","repo":"chequer/qp","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-060.json"

  # Checkpoint from previous escalation
  jq -n \
    --arg tid "$original_task_id" \
    '{task_id: $tid, target_general: "gen-pr", repo: "chequer/qp",
      payload: {pr_number: 77}, created_at: "2026-02-10T10:00:00Z"}' \
    > "$BASE_DIR/state/results/${original_task_id}-checkpoint.json"

  # Envoy detects human reply → emits slack.human_response event
  jq -n \
    --arg id "evt-slack-response-${original_task_id}-1739200000" \
    --arg tid "$original_task_id" \
    '{
      id: $id,
      type: "slack.human_response",
      source: "slack",
      repo: null,
      payload: {task_id: $tid, human_response: "Use JWT with refresh tokens"},
      priority: "high",
      created_at: "2026-02-10T10:05:00Z",
      status: "pending"
    }' > "$BASE_DIR/queue/events/pending/evt-slack-response-${original_task_id}-1739200000.json"

  # King processes the human_response event
  process_pending_events

  # Event dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-slack-response-${original_task_id}-1739200000.json" ]

  # Resume task created
  local resume_file
  resume_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$resume_file" ]
  run jq -r '.type' "$resume_file"
  assert_output "resume"
  run jq -r '.target_general' "$resume_file"
  assert_output "gen-pr"
  run jq -r '.priority' "$resume_file"
  assert_output "high"
  run jq -r '.payload.human_response' "$resume_file"
  assert_output "Use JWT with refresh tokens"
  run jq -r '.payload.original_task_id' "$resume_file"
  assert_output "$original_task_id"
}

@test "needs_human: full cycle — escalate → respond → resume → complete" {
  local today
  today=$(date +%Y%m%d)
  local task_id="task-${today}-070"

  # Setup: task in progress
  cat > "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" << EOF
{"id":"${task_id}","event_id":"evt-070","target_general":"gen-jira","type":"jira.ticket.assigned","repo":"chequer/qp","payload":{"ticket_key":"QP-300"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-070.json"

  GENERAL_DOMAIN="gen-jira"

  # Step 1: General escalates
  local raw_result
  raw_result=$(jq -n \
    --arg tid "$task_id" \
    --arg q "The DB schema is ambiguous. Which approach: normalize or denormalize?" \
    '{task_id: $tid, status: "needs_human", question: $q}')
  escalate_to_king "$task_id" "$raw_result"

  # Step 2: King processes needs_human → human_input_request message
  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$msg_file" ]
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"

  # Step 3: Human responds via Slack → event emitted
  jq -n \
    --arg id "evt-slack-response-${task_id}-1739201000" \
    --arg tid "$task_id" \
    '{
      id: $id,
      type: "slack.human_response",
      source: "slack", repo: null,
      payload: {task_id: $tid, human_response: "Go with denormalization for performance"},
      priority: "high",
      created_at: "2026-02-10T11:00:00Z",
      status: "pending"
    }' > "$BASE_DIR/queue/events/pending/evt-slack-response-${task_id}-1739201000.json"

  process_pending_events

  # Step 4: Resume task exists
  local resume_file
  resume_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | head -1)
  assert [ -f "$resume_file" ]
  local resume_task_id
  resume_task_id=$(jq -r '.id' "$resume_file")

  # Step 5: General picks up resume task, completes it
  mv "$resume_file" "$BASE_DIR/queue/tasks/in_progress/${resume_task_id}.json"
  report_to_king "$resume_task_id" "success" "Implemented with denormalized schema" ""

  check_task_results

  # Resume task completed
  assert [ -f "$BASE_DIR/queue/tasks/completed/${resume_task_id}.json" ]

  # Completion notification exists (find by type since other messages may also be pending)
  local notif_file=""
  for f in "$BASE_DIR/queue/messages/pending/"*.json; do
    [ -f "$f" ] || continue
    local t
    t=$(jq -r '.type' "$f")
    local c
    c=$(jq -r '.content' "$f")
    if [ "$t" = "notification" ] && echo "$c" | grep -q '\[complete\]'; then
      notif_file="$f"
      break
    fi
  done
  assert [ -n "$notif_file" ]
  run jq -r '.content' "$notif_file"
  assert_output --partial "[complete]"
  assert_output --partial "denormalized schema"
}

@test "needs_human: missing checkpoint → event moved to completed" {
  local today
  today=$(date +%Y%m%d)
  local fake_task_id="task-${today}-999"

  # Human response event referencing non-existent checkpoint
  jq -n \
    --arg id "evt-slack-orphan-001" \
    --arg tid "$fake_task_id" \
    '{
      id: $id,
      type: "slack.human_response",
      source: "slack", repo: null,
      payload: {task_id: $tid, human_response: "Some answer"},
      priority: "high",
      created_at: "2026-02-10T12:00:00Z",
      status: "pending"
    }' > "$BASE_DIR/queue/events/pending/evt-slack-orphan-001.json"

  # No checkpoint file exists for fake_task_id

  process_pending_events

  # Event should be moved to completed (not dispatched)
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-slack-orphan-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-slack-orphan-001.json" ]

  # No resume task created
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

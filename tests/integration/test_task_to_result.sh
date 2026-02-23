#!/usr/bin/env bats
# Integration: Task → General → Mock Soldier → Result

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

@test "integration: general picks task and spawns soldier" {
  # Create a task in pending
  local today
  today=$(date +%Y%m%d)
  cat > "$BASE_DIR/queue/tasks/pending/task-${today}-001.json" << EOF
{"id":"task-${today}-001","target_general":"gen-pr","type":"github.pr.review_requested","repo":"chequer/qp","payload":{"pr_number":42},"priority":"normal","status":"pending"}
EOF

  GENERAL_DOMAIN="gen-pr"

  # General picks the task
  local task_file
  task_file=$(pick_next_task "gen-pr")
  assert [ -f "$task_file" ]

  # Read task
  local task
  task=$(cat "$task_file")
  local task_id
  task_id=$(echo "$task" | jq -r '.id')
  [[ "$task_id" == "task-${today}-001" ]]

  # Move to in_progress (as general's main_loop would)
  mv "$task_file" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"

  # Build prompt
  local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
  build_prompt "$task" "" "" > "$prompt_file"
  assert [ -f "$prompt_file" ]
  # Prompt should be non-empty (command or long-form)
  local prompt_size
  prompt_size=$(wc -c < "$prompt_file" | tr -d ' ')
  (( prompt_size > 0 ))

  # Spawn mock soldier
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  spawn_soldier "$task_id" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  # Soldier ID recorded
  assert [ -f "$BASE_DIR/state/results/${task_id}-soldier-id" ]
  local soldier_id
  soldier_id=$(cat "$BASE_DIR/state/results/${task_id}-soldier-id")
  [[ "$soldier_id" == soldier-* ]]
}

@test "integration: general reports success to king" {
  local today
  today=$(date +%Y%m%d)
  local task_id="task-${today}-010"

  # Task in in_progress
  cat > "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" << EOF
{"id":"${task_id}","event_id":"evt-010","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-010.json"

  GENERAL_DOMAIN="gen-pr"

  # General reports success
  report_to_king "$task_id" "success" "PR reviewed and approved" ""

  # Result file created
  assert [ -f "$BASE_DIR/state/results/${task_id}.json" ]
  run jq -r '.status' "$BASE_DIR/state/results/${task_id}.json"
  assert_output "success"

  # King processes result
  check_task_results

  # Task completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/${task_id}.json" ]

  # Notification message created
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "notification"
  run jq -r '.content' "$msg_file"
  assert_output --partial "[complete]"
}

@test "integration: general reports failure to king" {
  local today
  today=$(date +%Y%m%d)
  local task_id="task-${today}-020"

  cat > "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" << EOF
{"id":"${task_id}","event_id":"evt-020","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-020.json"

  GENERAL_DOMAIN="gen-pr"
  local raw_result="{\"task_id\":\"${task_id}\",\"status\":\"failed\",\"error\":\"build failed\"}"
  report_to_king "$task_id" "failed" "" "$raw_result"

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/${task_id}.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.content' "$msg_file"
  assert_output --partial "[failed]"
}

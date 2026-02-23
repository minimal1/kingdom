#!/usr/bin/env bats
# king.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Copy configs
  cp "${BATS_TEST_DIRNAME}/../config/king.yaml" "$BASE_DIR/config/"
  install_test_general "gen-pr"
  install_test_general "gen-briefing"

  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/router.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/resource-check.sh"

  # Initialize state files
  TASK_SEQ_FILE="$BASE_DIR/state/king/task-seq"
  MSG_SEQ_FILE="$BASE_DIR/state/king/msg-seq"
  SCHEDULE_SENT_FILE="$BASE_DIR/state/king/schedule-sent.json"

  echo '0' > "$TASK_SEQ_FILE"
  echo '0' > "$MSG_SEQ_FILE"
  echo '{}' > "$SCHEDULE_SENT_FILE"
  echo '[]' > "$BASE_DIR/state/sessions.json"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"green\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  load_general_manifests

  # Source extracted king functions (no main loop!)
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/functions.sh"
}

teardown() {
  [ -n "$ROUTING_TABLE_FILE" ] && rm -f "$ROUTING_TABLE_FILE"
  [ -n "$SCHEDULES_FILE" ] && rm -f "$SCHEDULES_FILE"
  teardown_kingdom_env
}

# --- Task ID Generation ---

@test "king: next_task_id generates correct format" {
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-001" ]]
}

@test "king: next_task_id increments sequence" {
  next_task_id > /dev/null
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-002" ]]
}

@test "king: next_task_id resets on new date" {
  echo "20260101:050" > "$TASK_SEQ_FILE"
  local id
  id=$(next_task_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "task-${today}-001" ]]
}

@test "king: next_msg_id generates correct format" {
  local id
  id=$(next_msg_id)
  local today
  today=$(date +%Y%m%d)
  [[ "$id" == "msg-${today}-001" ]]
}

# --- Event Processing ---

@test "king: process_pending_events creates task from event" {
  cat > "$BASE_DIR/queue/events/pending/evt-001.json" << 'EOF'
{"id":"evt-001","type":"github.pr.review_requested","source":"github","priority":"normal","repo":"chequer/qp","payload":{"pr_number":123}}
EOF

  process_pending_events

  # Event moved to dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-001.json" ]

  # Task created in pending
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -ge 1 ]

  # Task has correct general
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
}

@test "king: process_pending_events creates thread_start message" {
  cat > "$BASE_DIR/queue/events/pending/evt-002.json" << 'EOF'
{"id":"evt-002","type":"github.pr.review_requested","source":"github","priority":"normal","repo":"chequer/qp","payload":{}}
EOF

  process_pending_events

  # Message created
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -ge 1 ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
}

@test "king: unmatched event moves to completed" {
  cat > "$BASE_DIR/queue/events/pending/evt-003.json" << 'EOF'
{"id":"evt-003","type":"unknown.event","source":"test","priority":"normal","payload":{}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-003.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-003.json" ]
}

@test "king: yellow health defers normal priority events" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"yellow\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  cat > "$BASE_DIR/queue/events/pending/evt-004.json" << 'EOF'
{"id":"evt-004","type":"github.pr.review_requested","source":"github","priority":"normal","payload":{}}
EOF

  process_pending_events

  # Event should stay in pending (deferred)
  assert [ -f "$BASE_DIR/queue/events/pending/evt-004.json" ]
}

@test "king: yellow health accepts high priority events" {
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"health\":\"yellow\",\"timestamp\":\"$now_ts\"}" > "$BASE_DIR/state/resources.json"

  cat > "$BASE_DIR/queue/events/pending/evt-005.json" << 'EOF'
{"id":"evt-005","type":"github.pr.review_requested","source":"github","priority":"high","payload":{}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-005.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-005.json" ]
}

# --- Result Processing ---

@test "king: handle_success completes task and creates notification" {
  # Setup: task in in_progress, event in dispatched
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-001.json" << 'EOF'
{"id":"task-20260210-001","event_id":"evt-010","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-010.json"

  # Result file
  cat > "$BASE_DIR/state/results/task-20260210-001.json" << 'EOF'
{"task_id":"task-20260210-001","status":"success","summary":"PR approved"}
EOF

  check_task_results

  # Task moved to completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-001.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-001.json" ]

  # Event moved to completed
  assert [ -f "$BASE_DIR/queue/events/completed/evt-010.json" ]

  # Notification message created
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "notification"
  run jq -r '.content' "$msg_file"
  assert_output --partial "✅ gen-pr"
}

@test "king: handle_failure completes task with error notification" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-002.json" << 'EOF'
{"id":"task-20260210-002","event_id":"evt-011","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-011.json"

  cat > "$BASE_DIR/state/results/task-20260210-002.json" << 'EOF'
{"task_id":"task-20260210-002","status":"failed","error":"build failed"}
EOF

  check_task_results

  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-002.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-002.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.content' "$msg_file"
  assert_output --partial "❌ gen-pr"
}

@test "king: handle_needs_human creates human_input_request message" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" << 'EOF'
{"id":"task-20260210-003","event_id":"evt-012","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF

  cat > "$BASE_DIR/state/results/task-20260210-003.json" << 'EOF'
{"task_id":"task-20260210-003","status":"needs_human","question":"Should I approve this PR?","checkpoint_path":"/tmp/cp.json"}
EOF

  check_task_results

  # Task stays in in_progress
  assert [ -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"
  run jq -r '.content' "$msg_file"
  assert_output --partial "[question]"
}

@test "king: skips checkpoint/raw/soldier-id result files" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-004.json" << 'EOF'
{"id":"task-20260210-004","event_id":"evt-013","status":"in_progress"}
EOF

  # These should be skipped
  echo '{"task_id":"task-20260210-004"}' > "$BASE_DIR/state/results/task-20260210-004-checkpoint.json"
  echo '{"task_id":"task-20260210-004"}' > "$BASE_DIR/state/results/task-20260210-004-raw.json"
  echo 'soldier-123' > "$BASE_DIR/state/results/task-20260210-004-soldier-id"

  check_task_results

  # Task should remain in_progress (no valid result file to process)
  assert [ -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-004.json" ]
}

# --- Human Response ---

@test "king: process_human_response creates resume task" {
  # Checkpoint for original task
  cat > "$BASE_DIR/state/results/task-20260210-010-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","repo":"chequer/qp","context":"some context"}
EOF

  # Human response event
  cat > "$BASE_DIR/queue/events/pending/evt-hr-001.json" << 'EOF'
{"id":"evt-hr-001","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-20260210-010","human_response":"Yes, approve it"}}
EOF

  process_pending_events

  # Event moved to dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-hr-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-hr-001.json" ]

  # Resume task created
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.type' "$task_file"
  assert_output "resume"
  run jq -r '.payload.human_response' "$task_file"
  assert_output "Yes, approve it"
  run jq -r '.priority' "$task_file"
  assert_output "high"
}

@test "king: process_human_response includes session_id from checkpoint" {
  # Checkpoint with session_id
  cat > "$BASE_DIR/state/results/task-20260210-011-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","repo":"chequer/qp","session_id":"sess-abc123","payload":{}}
EOF

  cat > "$BASE_DIR/queue/events/pending/evt-hr-sid.json" << 'EOF'
{"id":"evt-hr-sid","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-20260210-011","human_response":"Go ahead"}}
EOF

  process_pending_events

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.payload.session_id' "$task_file"
  assert_output "sess-abc123"
}

@test "king: process_human_response handles missing session_id gracefully" {
  # Checkpoint without session_id (legacy)
  cat > "$BASE_DIR/state/results/task-20260210-012-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","repo":"chequer/qp","payload":{}}
EOF

  cat > "$BASE_DIR/queue/events/pending/evt-hr-nosid.json" << 'EOF'
{"id":"evt-hr-nosid","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-20260210-012","human_response":"Do it"}}
EOF

  process_pending_events

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  # session_id should be empty string (fallback to new session)
  run jq -r '.payload.session_id' "$task_file"
  assert_output ""
}

@test "king: check_task_results skips session-id files" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-020.json" << 'EOF'
{"id":"task-20260210-020","event_id":"evt-020","status":"in_progress"}
EOF

  echo 'sess-xyz789' > "$BASE_DIR/state/results/task-20260210-020-session-id"

  check_task_results

  # Task should remain in_progress (session-id file is not a result)
  assert [ -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-020.json" ]
}

@test "king: human_response with missing checkpoint moves to completed" {
  cat > "$BASE_DIR/queue/events/pending/evt-hr-002.json" << 'EOF'
{"id":"evt-hr-002","type":"slack.human_response","source":"slack","priority":"high","payload":{"task_id":"task-nonexistent","human_response":"test"}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-hr-002.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-hr-002.json" ]
}

# --- Cron Matching ---

@test "king: cron_matches wildcard matches always" {
  run cron_matches "* * * * *"
  assert_success
}

@test "king: cron_matches exact mismatch fails" {
  run cron_matches "59 23 31 12 7"
  # This will almost certainly fail (unless it's Dec 31 at 23:59 on Sunday)
  assert_failure
}

@test "king: cron_matches range works" {
  local now_dow
  now_dow=$(date +%u)
  # Range 1-7 should always match
  run cron_matches "* * * * 1-7"
  assert_success
}

# --- Schedule ---

@test "king: already_triggered prevents duplicate" {
  mark_triggered "test-schedule"
  run already_triggered "test-schedule"
  assert_success
}

@test "king: untriggered schedule returns false" {
  run already_triggered "never-triggered"
  assert_failure
}

@test "king: handle_skipped completes task and creates skip notification" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-005.json" << 'EOF'
{"id":"task-20260210-005","event_id":"evt-014","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-014.json"

  cat > "$BASE_DIR/state/results/task-20260210-005.json" << 'EOF'
{"task_id":"task-20260210-005","status":"skipped","reason":"PR is outside frontend scope"}
EOF

  check_task_results

  # Task moved to completed
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-005.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-005.json" ]

  # Event moved to completed
  assert [ -f "$BASE_DIR/queue/events/completed/evt-014.json" ]

  # Notification message created with ⏭️ prefix
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 1 ]
  local content
  content=$(jq -r '.content' "$BASE_DIR/queue/messages/pending/"*.json)
  echo "$content" | grep -q '⏭️ gen-pr'
}

@test "king: max_soldiers defers events when full" {
  # Fill sessions.json with 3 entries (max_soldiers = 3)
  echo '[{"id":"s1"},{"id":"s2"},{"id":"s3"}]' > "$BASE_DIR/state/sessions.json"

  cat > "$BASE_DIR/queue/events/pending/evt-full.json" << 'EOF'
{"id":"evt-full","type":"github.pr.review_requested","source":"github","priority":"normal","payload":{}}
EOF

  process_pending_events

  # Event should stay in pending (deferred due to max soldiers)
  assert [ -f "$BASE_DIR/queue/events/pending/evt-full.json" ]
}

# --- Cron Step Pattern ---

@test "king: cron step */10 matches multiples" {
  run _cron_field_matches "*/10" "0"
  assert_success
  run _cron_field_matches "*/10" "20"
  assert_success
  run _cron_field_matches "*/10" "7"
  assert_failure
}

@test "king: cron step */5 matches multiples" {
  run _cron_field_matches "*/5" "0"
  assert_success
  run _cron_field_matches "*/5" "15"
  assert_success
  run _cron_field_matches "*/5" "3"
  assert_failure
}

# --- Minute-based Dedup ---

@test "king: already_triggered uses minute-based dedup" {
  mark_triggered "test-min"
  run already_triggered "test-min"
  assert_success
}

@test "king: different minute is not duplicate" {
  local old_key
  old_key=$(date -v-1M +%Y-%m-%dT%H:%M 2>/dev/null || date -d "1 minute ago" +%Y-%m-%dT%H:%M)
  echo "{}" | jq --arg n "test-old" --arg d "$old_key" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
  run already_triggered "test-old"
  assert_failure
}

# --- Schedule Dispatch E2E ---

@test "king: check_general_schedules dispatches task and message" {
  # Write a schedule that always matches (every minute)
  echo 'gen-briefing|{"name":"test-every-min","cron":"* * * * *","task_type":"test-sched","payload":{}}' > "$SCHEDULES_FILE"

  check_general_schedules

  # Task created in pending
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -ge 1 ]

  # Task has correct fields
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-briefing"
  run jq -r '.type' "$task_file"
  assert_output "test-sched"
  run jq -r '.event_id' "$task_file"
  assert_output "schedule-test-every-min"

  # Thread start message created
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -ge 1 ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
  run jq -r '.content' "$msg_file"
  assert_output --partial "gen-briefing"

  # Dedup: second call should NOT create another task
  check_general_schedules
  local task_count2
  task_count2=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count2" -eq "$task_count" ]
}

@test "king: check_general_schedules skips non-matching cron" {
  # Schedule that never matches (Feb 30 doesn't exist)
  echo 'gen-briefing|{"name":"test-never","cron":"0 0 30 2 *","task_type":"never","payload":{}}' > "$SCHEDULES_FILE"

  check_general_schedules

  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

# --- write_to_queue ---

@test "king: write_to_queue creates file atomically" {
  local test_dir="$BASE_DIR/queue/tasks/pending"
  write_to_queue "$test_dir" "test-atomic" '{"id":"test-atomic","data":"hello"}'

  assert [ -f "$test_dir/test-atomic.json" ]
  assert [ ! -f "$test_dir/.tmp-test-atomic.json" ]

  run jq -r '.id' "$test_dir/test-atomic.json"
  assert_output "test-atomic"
}

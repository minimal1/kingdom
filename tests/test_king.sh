#!/usr/bin/env bats
# king.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # Copy configs
  cp "${BATS_TEST_DIRNAME}/../config/king.yaml" "$BASE_DIR/config/"
  install_test_general "gen-pr"
  install_test_general "gen-briefing"
  install_test_general "gen-herald"

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
  source "${BATS_TEST_DIRNAME}/../bin/lib/king/petition.sh"
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

@test "king: thread_start message includes rich context for github PR" {
  cat > "$BASE_DIR/queue/events/pending/evt-rich-001.json" << 'EOF'
{"id":"evt-rich-001","type":"github.pr.review_requested","source":"github","priority":"normal","repo":"chequer-io/querypie-frontend","payload":{"pr_number":123,"subject_title":"Add authentication middleware"}}
EOF

  process_pending_events

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  local content
  content=$(jq -r '.content' "$msg_file")
  # Bold general name
  echo "$content" | grep -q '\*gen-pr\*'
  # GitHub link in Slack mrkdwn format
  echo "$content" | grep -q '<https://github.com/chequer-io/querypie-frontend/pull/123|#123 Add authentication middleware>'
  # Backtick-wrapped event type
  echo "$content" | grep -q '`github.pr.review_requested`'
}

@test "king: thread_start message falls back to event_type when no context" {
  cat > "$BASE_DIR/queue/events/pending/evt-noctx-001.json" << 'EOF'
{"id":"evt-noctx-001","type":"github.pr.review_requested","source":"github","priority":"normal","repo":"chequer/qp","payload":{}}
EOF

  process_pending_events

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  local content
  content=$(jq -r '.content' "$msg_file")
  # Backtick event type + repo fallback
  echo "$content" | grep -q '`github.pr.review_requested`'
  echo "$content" | grep -q 'chequer/qp'
}

@test "king: handle_success notification includes rich context" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-060.json" << 'EOF'
{"id":"task-20260210-060","event_id":"evt-060","target_general":"gen-pr","type":"github.pr.review_requested","repo":"chequer-io/querypie-frontend","payload":{"pr_number":456,"subject_title":"Fix login bug"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-060.json"

  cat > "$BASE_DIR/state/results/task-20260210-060.json" << 'EOF'
{"task_id":"task-20260210-060","status":"success","summary":"PR approved"}
EOF

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  local content
  content=$(jq -r '.content' "$msg_file")
  echo "$content" | grep -q '\*gen-pr\*'
  echo "$content" | grep -q '<https://github.com/chequer-io/querypie-frontend/pull/456|#456 Fix login bug>'
  echo "$content" | grep -q 'PR approved'
}

@test "king: format_task_context returns empty for unknown event types" {
  local ctx
  ctx=$(format_task_context "schedule.briefing" '{}')
  [ -z "$ctx" ]
}

@test "king: format_task_context builds jira link" {
  local ctx
  ctx=$(format_task_context "jira.ticket.created" '{"url":"https://jira.example.com/browse/PROJ-123","ticket_key":"PROJ-123","summary":"Fix performance issue"}')
  [ "$ctx" = '<https://jira.example.com/browse/PROJ-123|PROJ-123 Fix performance issue>' ]
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
  assert_output --partial "✅ *gen-pr*"
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
  assert_output --partial "❌ *gen-pr*"
}

@test "king: handle_needs_human completes task and includes reply_context" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" << 'EOF'
{"id":"task-20260210-003","event_id":"evt-012","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-012.json"

  # checkpoint 파일 생성 (handle_needs_human이 읽음)
  cat > "$BASE_DIR/state/results/task-20260210-003-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","session_id":"sess-abc","repo":"chequer/qp"}
EOF

  cat > "$BASE_DIR/state/results/task-20260210-003.json" << 'EOF'
{"task_id":"task-20260210-003","status":"needs_human","question":"Should I approve this PR?","checkpoint_path":"PLACEHOLDER"}
EOF
  # checkpoint_path를 실제 경로로 치환
  local cp_path="$BASE_DIR/state/results/task-20260210-003-checkpoint.json"
  jq --arg cp "$cp_path" '.checkpoint_path = $cp' "$BASE_DIR/state/results/task-20260210-003.json" > "$BASE_DIR/state/results/task-20260210-003.json.tmp"
  mv "$BASE_DIR/state/results/task-20260210-003.json.tmp" "$BASE_DIR/state/results/task-20260210-003.json"

  check_task_results

  # Task moved to completed (not staying in in_progress)
  assert [ ! -f "$BASE_DIR/queue/tasks/in_progress/task-20260210-003.json" ]
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-003.json" ]

  # Result file removed
  assert [ ! -f "$BASE_DIR/state/results/task-20260210-003.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"
  run jq -r '.content' "$msg_file"
  assert_output --partial "[question]"
  # reply_context 포함 확인
  run jq -r '.reply_context.general' "$msg_file"
  assert_output "gen-pr"
  run jq -r '.reply_context.session_id' "$msg_file"
  assert_output "sess-abc"
}

@test "king: handle_needs_human includes channel/thread_ts for DM tasks" {
  # DM 기반 task: payload에 channel + message_ts 있음
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-015.json" << 'EOF'
{"id":"task-20260210-015","event_id":"evt-dm-015","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"channel":"D999","message_ts":"1707300000.000200"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-dm-015.json"

  cat > "$BASE_DIR/state/results/task-20260210-015-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","session_id":"sess-dm","repo":"chequer/qp"}
EOF
  cat > "$BASE_DIR/state/results/task-20260210-015.json" << 'EOF'
{"task_id":"task-20260210-015","status":"needs_human","question":"리뷰할 PR 번호를 직접 지정해주세요.","checkpoint_path":"PLACEHOLDER"}
EOF
  local cp_path="$BASE_DIR/state/results/task-20260210-015-checkpoint.json"
  jq --arg cp "$cp_path" '.checkpoint_path = $cp' "$BASE_DIR/state/results/task-20260210-015.json" > "$BASE_DIR/state/results/task-20260210-015.json.tmp"
  mv "$BASE_DIR/state/results/task-20260210-015.json.tmp" "$BASE_DIR/state/results/task-20260210-015.json"

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "human_input_request"
  # DM 원본 channel/thread_ts가 메시지에 포함됨
  run jq -r '.channel' "$msg_file"
  assert_output "D999"
  run jq -r '.thread_ts' "$msg_file"
  assert_output "1707300000.000200"
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

# --- Thread Reply (통합 핸들러) ---

@test "king: process_thread_reply creates resume task from reply_context" {
  cat > "$BASE_DIR/queue/events/pending/evt-reply-001.json" << 'EOF'
{"id":"evt-reply-001","type":"slack.thread.reply","source":"slack","priority":"high","payload":{"text":"Yes, approve it","channel":"D08XXX","thread_ts":"1234.5678","reply_context":{"general":"gen-pr","session_id":"sess-abc123","repo":"chequer/qp"}}}
EOF

  process_pending_events

  # Event moved to dispatched
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-reply-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-reply-001.json" ]

  # Resume task created
  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.type' "$task_file"
  assert_output "resume"
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
  run jq -r '.payload.human_response' "$task_file"
  assert_output "Yes, approve it"
  run jq -r '.payload.session_id' "$task_file"
  assert_output "sess-abc123"
  run jq -r '.priority' "$task_file"
  assert_output "high"
}

@test "king: process_thread_reply without general discards event" {
  cat > "$BASE_DIR/queue/events/pending/evt-reply-no-gen.json" << 'EOF'
{"id":"evt-reply-no-gen","type":"slack.thread.reply","source":"slack","priority":"high","payload":{"text":"Hello","channel":"D08XXX","thread_ts":"1234.5678","reply_context":{}}}
EOF

  process_pending_events

  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-reply-no-gen.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-reply-no-gen.json" ]
  # No task should be created
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

@test "king: process_thread_reply handles empty session_id gracefully" {
  cat > "$BASE_DIR/queue/events/pending/evt-reply-nosid.json" << 'EOF'
{"id":"evt-reply-nosid","type":"slack.thread.reply","source":"slack","priority":"high","payload":{"text":"Do it","channel":"D08XXX","thread_ts":"1234.5678","reply_context":{"general":"gen-pr","session_id":"","repo":""}}}
EOF

  process_pending_events

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
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

# --- DM 메시지 이벤트: thread_start with existing thread_ts ---

@test "king: DM with petition disabled creates thread_start with existing thread_ts" {
  # petition 비활성화: YAML boolean false는 yq // 연산자에서 falsy 취급되므로 문자열 사용
  cat > "$BASE_DIR/config/king.yaml" << 'EOF'
slack:
  default_channel: "dev-eddy"
retry:
  max_attempts: 2
  backoff_seconds: 60
concurrency:
  max_soldiers: 3
petition:
  enabled: "false"
intervals:
  event_check_seconds: 10
  result_check_seconds: 10
  schedule_check_seconds: 60
  petition_check_seconds: 5
  loop_tick_seconds: 5
EOF

  cat > "$BASE_DIR/queue/events/pending/evt-dm-001.json" << 'EOF'
{"id":"evt-dm-001","type":"slack.channel.message","source":"slack","priority":"normal","repo":null,"payload":{"text":"hello","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  # 라우팅 테이블에 slack.channel.message → gen-pr 수동 추가
  local updated
  updated=$(jq '. + {"slack.channel.message": "gen-pr"}' "$ROUTING_TABLE_FILE")
  echo "$updated" > "$ROUTING_TABLE_FILE"

  process_pending_events

  # 이벤트 dispatched
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-dm-001.json" ]

  # thread_start 메시지가 기존 thread_ts를 포함하여 생성되어야 함
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 1 ]
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_start"
  run jq -r '.thread_ts' "$msg_file"
  assert_output "1234.5678"
  run jq -r '.channel' "$msg_file"
  assert_output "D08XXX"
}

# --- handle_success reply_to ---

@test "king: handle_success creates thread_reply when channel/thread_ts present" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-030.json" << 'EOF'
{"id":"task-20260210-030","event_id":"evt-030","target_general":"gen-pr","type":"slack.channel.message","payload":{"channel":"D08XXX","message_ts":"1234.5678"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-030.json"

  cat > "$BASE_DIR/state/results/task-20260210-030.json" << 'EOF'
{"task_id":"task-20260210-030","status":"success","summary":"Done!"}
EOF

  check_task_results

  # Task completed
  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-030.json" ]

  # thread_reply 메시지 생성 확인
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_reply"
  run jq -r '.channel' "$msg_file"
  assert_output "D08XXX"
  run jq -r '.thread_ts' "$msg_file"
  assert_output "1234.5678"
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
  echo "$content" | grep -q '⏭️ \*gen-pr\*'
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

@test "king: dispatch_scheduled_task includes repo when provided" {
  dispatch_scheduled_task "gen-briefing" "test-repo-sched" "test-type" '{}' "chequer-io/querypie-frontend"

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.repo' "$task_file"
  assert_output "chequer-io/querypie-frontend"
}

@test "king: dispatch_scheduled_task sets repo null when not provided" {
  dispatch_scheduled_task "gen-briefing" "test-no-repo" "test-type" '{}' ""

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.repo' "$task_file"
  assert_output "null"
}

@test "king: check_general_schedules passes repo from schedule config" {
  echo 'gen-briefing|{"name":"test-with-repo","cron":"* * * * *","task_type":"test-repo","repo":"chequer-io/querypie-frontend","payload":{}}' > "$SCHEDULES_FILE"

  check_general_schedules

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.repo' "$task_file"
  assert_output "chequer-io/querypie-frontend"
  run jq -r '.type' "$task_file"
  assert_output "test-repo"
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

# --- DM Petition ---

@test "king: DM with petition enabled moves event to petitioning" {
  cat > "$BASE_DIR/queue/events/pending/evt-petition-001.json" << 'EOF'
{"id":"evt-petition-001","type":"slack.channel.message","source":"slack","priority":"normal","repo":null,"payload":{"text":"PR #123 리뷰해줘","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  process_pending_events

  # 이벤트가 petitioning으로 이동
  assert [ ! -f "$BASE_DIR/queue/events/pending/evt-petition-001.json" ]
  assert [ -f "$BASE_DIR/queue/events/petitioning/evt-petition-001.json" ]

  # tmux mock이 호출되었는지 확인 (pending에 남지 않음)
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -eq 0 ]
}

@test "king: process_petition_results dispatches when general matched" {
  # petitioning에 이벤트 배치
  cat > "$BASE_DIR/queue/events/petitioning/evt-petition-002.json" << 'EOF'
{"id":"evt-petition-002","type":"slack.channel.message","source":"slack","priority":"normal","repo":null,"payload":{"text":"PR #123 리뷰해줘","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  # petition 결과 배치 (gen-pr 매칭)
  echo '{"general":"gen-pr","repo":"chequer/qp"}' > "$BASE_DIR/state/king/petition-results/evt-petition-002.json"

  process_petition_results

  # 이벤트가 dispatched로 이동
  assert [ ! -f "$BASE_DIR/queue/events/petitioning/evt-petition-002.json" ]
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-petition-002.json" ]

  # 태스크 생성 확인
  local task_count
  task_count=$(ls "$BASE_DIR/queue/tasks/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$task_count" -ge 1 ]

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
  # repo가 petition 결과에서 병합되었는지
  run jq -r '.repo' "$task_file"
  assert_output "chequer/qp"

  # 결과 파일 정리됨
  assert [ ! -f "$BASE_DIR/state/king/petition-results/evt-petition-002.json" ]
}

@test "king: process_petition_results handles direct_response" {
  cat > "$BASE_DIR/queue/events/petitioning/evt-petition-003.json" << 'EOF'
{"id":"evt-petition-003","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"장군 목록 알려줘","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  echo '{"general":null,"direct_response":"현재 활성 장군: gen-pr, gen-briefing"}' \
    > "$BASE_DIR/state/king/petition-results/evt-petition-003.json"

  process_petition_results

  # 이벤트가 completed로 이동
  assert [ ! -f "$BASE_DIR/queue/events/petitioning/evt-petition-003.json" ]
  assert [ -f "$BASE_DIR/queue/events/completed/evt-petition-003.json" ]

  # thread_reply 메시지 생성 확인
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_reply"
  run jq -r '.content' "$msg_file"
  assert_output --partial "활성 장군"
  run jq -r '.channel' "$msg_file"
  assert_output "D08XXX"
  run jq -r '.thread_ts' "$msg_file"
  assert_output "1234.5678"
}

@test "king: process_petition_results falls back to static routing" {
  # 라우팅 테이블에 slack.channel.message → gen-pr 추가
  local updated
  updated=$(jq '. + {"slack.channel.message": "gen-pr"}' "$ROUTING_TABLE_FILE")
  echo "$updated" > "$ROUTING_TABLE_FILE"

  cat > "$BASE_DIR/queue/events/petitioning/evt-petition-004.json" << 'EOF'
{"id":"evt-petition-004","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"something","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  # petition 결과: 매칭 불가 (general: null, direct_response 없음)
  echo '{"general":null}' > "$BASE_DIR/state/king/petition-results/evt-petition-004.json"

  process_petition_results

  # 정적 매핑으로 dispatched
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-petition-004.json" ]

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-pr"
}

@test "king: process_petition_results handles unroutable DM" {
  # gen-herald가 설치된 경우 catch-all이 작동하므로, 라우팅 테이블에서 제거
  local updated
  updated=$(jq 'del(.["slack.channel.message"])' "$ROUTING_TABLE_FILE")
  echo "$updated" > "$ROUTING_TABLE_FILE"

  cat > "$BASE_DIR/queue/events/petitioning/evt-petition-005.json" << 'EOF'
{"id":"evt-petition-005","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"뭔가 알 수 없는 요청","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  # petition도 실패, 정적 매핑도 없음
  echo '{"general":null}' > "$BASE_DIR/state/king/petition-results/evt-petition-005.json"

  process_petition_results

  # completed로 이동
  assert [ -f "$BASE_DIR/queue/events/completed/evt-petition-005.json" ]

  # 안내 메시지 생성
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_reply"
  run jq -r '.content' "$msg_file"
  assert_output --partial "처리할 수 있는 전문가가 없습니다"
}

@test "king: process_petition_results cleans orphan results" {
  # 결과만 있고 이벤트 파일이 없는 경우
  echo '{"general":"gen-pr"}' > "$BASE_DIR/state/king/petition-results/evt-orphan.json"

  process_petition_results

  # orphan 결과가 정리됨
  assert [ ! -f "$BASE_DIR/state/king/petition-results/evt-orphan.json" ]
}

# --- gen-herald catch-all ---

@test "king: gen-herald manifest registers slack.channel.message in routing table" {
  # load_general_manifests는 setup()에서 이미 실행됨
  run jq -r '.["slack.channel.message"]' "$ROUTING_TABLE_FILE"
  assert_output "gen-herald"
}

@test "king: petition failure falls back to gen-herald catch-all" {
  cat > "$BASE_DIR/queue/events/petitioning/evt-petition-herald.json" << 'EOF'
{"id":"evt-petition-herald","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"오늘 날씨 어때?","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  # petition 분류 실패 (general: null, direct_response 없음)
  echo '{"general":null}' > "$BASE_DIR/state/king/petition-results/evt-petition-herald.json"

  process_petition_results

  # 정적 매핑(gen-herald)으로 dispatched
  assert [ -f "$BASE_DIR/queue/events/dispatched/evt-petition-herald.json" ]

  local task_file
  task_file=$(ls "$BASE_DIR/queue/tasks/pending/"*.json | head -1)
  run jq -r '.target_general' "$task_file"
  assert_output "gen-herald"
}

# --- notify_channel ---

@test "king: handle_success with notify_channel sends to custom channel" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-040.json" << 'EOF'
{"id":"task-20260210-040","event_id":"evt-040","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-040.json"

  cat > "$BASE_DIR/state/results/task-20260210-040.json" << 'EOF'
{"task_id":"task-20260210-040","status":"success","summary":"Catchup done","notify_channel":"C_CUSTOM_CH"}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-040.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "notification"
  run jq -r '.channel' "$msg_file"
  assert_output "C_CUSTOM_CH"
  run jq -r '.content' "$msg_file"
  assert_output --partial "✅ *gen-pr*"
}

@test "king: handle_failure with notify_channel sends to custom channel" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-041.json" << 'EOF'
{"id":"task-20260210-041","event_id":"evt-041","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-041.json"

  cat > "$BASE_DIR/state/results/task-20260210-041.json" << 'EOF'
{"task_id":"task-20260210-041","status":"failed","error":"timeout","notify_channel":"C_FAIL_CH"}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-041.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.channel' "$msg_file"
  assert_output "C_FAIL_CH"
  run jq -r '.content' "$msg_file"
  assert_output --partial "❌ *gen-pr*"
}

@test "king: handle_skipped with notify_channel sends to custom channel" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-042.json" << 'EOF'
{"id":"task-20260210-042","event_id":"evt-042","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-042.json"

  cat > "$BASE_DIR/state/results/task-20260210-042.json" << 'EOF'
{"task_id":"task-20260210-042","status":"skipped","reason":"already merged","notify_channel":"C_SKIP_CH"}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-042.json" ]

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.channel' "$msg_file"
  assert_output "C_SKIP_CH"
  run jq -r '.content' "$msg_file"
  assert_output --partial "⏭️ *gen-pr*"
}

@test "king: create_notification_message defaults to default channel when no override" {
  create_notification_message "task-test-default" "test message"

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.channel' "$msg_file"
  # Should use default channel from config, not empty
  [ -n "$output" ]
  [ "$output" != "null" ]
}

# --- Proclamation ---

@test "king: handle_success queues proclamation message when present" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-050.json" << 'EOF'
{"id":"task-20260210-050","event_id":"evt-050","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-050.json"

  cat > "$BASE_DIR/state/results/task-20260210-050.json" << 'EOF'
{"task_id":"task-20260210-050","status":"success","summary":"PR News posted","proclamation":{"channel":"C0TEAMCH","message":"PR News\n1. repo-a"}}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-050.json" ]

  # 메시지 2개: notification + proclamation
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 2 ]

  # proclamation 메시지 확인 (task_id가 proclamation- 접두사)
  local proc_file
  proc_file=$(grep -l '"proclamation-task-20260210-050"' "$BASE_DIR/queue/messages/pending/"*.json)
  run jq -r '.channel' "$proc_file"
  assert_output "C0TEAMCH"
  run jq -r '.urgency' "$proc_file"
  assert_output "high"
  run jq -r '.content' "$proc_file"
  assert_output --partial "PR News"
}

@test "king: handle_failure queues proclamation message when present" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-051.json" << 'EOF'
{"id":"task-20260210-051","event_id":"evt-051","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-051.json"

  cat > "$BASE_DIR/state/results/task-20260210-051.json" << 'EOF'
{"task_id":"task-20260210-051","status":"failed","error":"canvas update failed","proclamation":{"channel":"C0TEAMCH","message":"Catchup partial result"}}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-051.json" ]

  # 메시지 2개: notification + proclamation
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 2 ]

  local proc_file
  proc_file=$(grep -l '"proclamation-task-20260210-051"' "$BASE_DIR/queue/messages/pending/"*.json)
  run jq -r '.channel' "$proc_file"
  assert_output "C0TEAMCH"
}

@test "king: handle_success no proclamation when field absent" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-052.json" << 'EOF'
{"id":"task-20260210-052","event_id":"evt-052","target_general":"gen-pr","type":"github.pr.review_requested","status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-052.json"

  cat > "$BASE_DIR/state/results/task-20260210-052.json" << 'EOF'
{"task_id":"task-20260210-052","status":"success","summary":"Regular task done"}
EOF

  check_task_results

  assert [ -f "$BASE_DIR/queue/tasks/completed/task-20260210-052.json" ]

  # 메시지 1개만 (notification only, no proclamation)
  local msg_count
  msg_count=$(ls "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$msg_count" -eq 1 ]

  # proclamation 메시지 없음 확인
  local proc_count
  proc_count=$(grep -l '"proclamation-' "$BASE_DIR/queue/messages/pending/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$proc_count" -eq 0 ]
}

@test "king: handle_success thread_reply includes source_ref for DM task" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-070.json" << 'EOF'
{"id":"task-20260210-070","event_id":"evt-070","target_general":"gen-pr","type":"slack.channel.message","payload":{"channel":"D999","message_ts":"1707300000.000100"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-070.json"

  cat > "$BASE_DIR/state/results/task-20260210-070.json" << 'EOF'
{"task_id":"task-20260210-070","status":"success","summary":"Done!"}
EOF

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_reply"
  # source_ref 포함 확인
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
  run jq -r '.source_ref.message_ts' "$msg_file"
  assert_output "1707300000.000100"
}

@test "king: handle_success notification includes source_ref for non-DM task with message_ts" {
  # notification 경로: payload에 channel/message_ts가 없는 일반 task + payload에 message_ts만
  # thread_ts도 없어야 notification 경로를 탐
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-071.json" << 'EOF'
{"id":"task-20260210-071","event_id":"evt-071","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"pr_number":999,"channel":"D999","message_ts":"1707300000.000100"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-071.json"

  cat > "$BASE_DIR/state/results/task-20260210-071.json" << 'EOF'
{"task_id":"task-20260210-071","status":"success","summary":"PR approved"}
EOF

  check_task_results

  # payload에 channel+message_ts 있으면 thread_reply 경로
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.type' "$msg_file"
  assert_output "thread_reply"
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
}

@test "king: handle_failure notification includes source_ref" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-072.json" << 'EOF'
{"id":"task-20260210-072","event_id":"evt-072","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"channel":"D999","message_ts":"1707300000.000200"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-072.json"

  cat > "$BASE_DIR/state/results/task-20260210-072.json" << 'EOF'
{"task_id":"task-20260210-072","status":"failed","error":"timeout"}
EOF

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
  run jq -r '.source_ref.message_ts' "$msg_file"
  assert_output "1707300000.000200"
}

@test "king: handle_skipped notification includes source_ref" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-073.json" << 'EOF'
{"id":"task-20260210-073","event_id":"evt-073","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"channel":"D999","message_ts":"1707300000.000300"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-073.json"

  cat > "$BASE_DIR/state/results/task-20260210-073.json" << 'EOF'
{"task_id":"task-20260210-073","status":"skipped","reason":"out of scope"}
EOF

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
}

@test "king: handle_needs_human includes source_ref" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-074.json" << 'EOF'
{"id":"task-20260210-074","event_id":"evt-074","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"channel":"D999","message_ts":"1707300000.000400"},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-074.json"

  cat > "$BASE_DIR/state/results/task-20260210-074-checkpoint.json" << 'EOF'
{"target_general":"gen-pr","session_id":"sess-xyz","repo":"chequer/qp"}
EOF
  cat > "$BASE_DIR/state/results/task-20260210-074.json" << 'EOF'
{"task_id":"task-20260210-074","status":"needs_human","question":"Approve?","checkpoint_path":"PLACEHOLDER"}
EOF
  local cp_path="$BASE_DIR/state/results/task-20260210-074-checkpoint.json"
  jq --arg cp "$cp_path" '.checkpoint_path = $cp' "$BASE_DIR/state/results/task-20260210-074.json" > "$BASE_DIR/state/results/task-20260210-074.json.tmp"
  mv "$BASE_DIR/state/results/task-20260210-074.json.tmp" "$BASE_DIR/state/results/task-20260210-074.json"

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
  run jq -r '.source_ref.message_ts' "$msg_file"
  assert_output "1707300000.000400"
}

@test "king: source_ref is null for non-DM tasks" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-20260210-075.json" << 'EOF'
{"id":"task-20260210-075","event_id":"evt-075","target_general":"gen-pr","type":"github.pr.review_requested","payload":{"pr_number":123},"status":"in_progress"}
EOF
  echo '{}' > "$BASE_DIR/queue/events/dispatched/evt-075.json"

  cat > "$BASE_DIR/state/results/task-20260210-075.json" << 'EOF'
{"task_id":"task-20260210-075","status":"success","summary":"Done"}
EOF

  check_task_results

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.source_ref' "$msg_file"
  assert_output "null"
}

@test "king: handle_direct_response includes source_ref" {
  cat > "$BASE_DIR/queue/events/pending/evt-dr-sr.json" << 'EOF'
{"id":"evt-dr-sr","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"test","channel":"D999","message_ts":"1707300000.000500"}}
EOF

  handle_direct_response \
    '{"id":"evt-dr-sr","payload":{"channel":"D999","message_ts":"1707300000.000500"}}' \
    "$BASE_DIR/queue/events/pending/evt-dr-sr.json" \
    "Direct reply"

  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.source_ref.channel' "$msg_file"
  assert_output "D999"
  run jq -r '.source_ref.message_ts' "$msg_file"
  assert_output "1707300000.000500"
}

@test "king: handle_unroutable_dm sends guidance and completes event" {
  cat > "$BASE_DIR/queue/events/pending/evt-unroutable.json" << 'EOF'
{"id":"evt-unroutable","type":"slack.channel.message","source":"slack","priority":"normal","payload":{"text":"hello","channel":"D08XXX","message_ts":"1234.5678"}}
EOF

  handle_unroutable_dm \
    '{"id":"evt-unroutable","payload":{"channel":"D08XXX","message_ts":"1234.5678"}}' \
    "$BASE_DIR/queue/events/pending/evt-unroutable.json"

  # 이벤트 completed
  assert [ -f "$BASE_DIR/queue/events/completed/evt-unroutable.json" ]

  # 안내 메시지 생성
  local msg_file
  msg_file=$(ls "$BASE_DIR/queue/messages/pending/"*.json | head -1)
  run jq -r '.content' "$msg_file"
  assert_output --partial "전문가가 없습니다"
}

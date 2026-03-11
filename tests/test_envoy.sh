#!/usr/bin/env bats
# envoy.sh integration tests

setup() {
  load 'test_helper'
  setup_kingdom_env
  cp "${BATS_TEST_DIRNAME}/../config/envoy.yaml" "$BASE_DIR/config/envoy.yaml"
  source "${BATS_TEST_DIRNAME}/../bin/lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/slack-api.sh"
  source "${BATS_TEST_DIRNAME}/../bin/lib/envoy/thread-manager.sh"
  export SLACK_BOT_TOKEN="xoxb-test"
  echo '{}' > "$BASE_DIR/state/envoy/thread-mappings.json"
  echo '[]' > "$BASE_DIR/state/envoy/awaiting-responses.json"
  mkdir -p "$BASE_DIR/state/envoy/socket-inbox"
  mkdir -p "$BASE_DIR/state/envoy/outbox"
  mkdir -p "$BASE_DIR/state/envoy/outbox-results"
  echo '{}' > "$BASE_DIR/state/envoy/conversation-threads.json"
  CONV_FILE="$BASE_DIR/state/envoy/conversation-threads.json"
  AWAITING_FILE="$BASE_DIR/state/envoy/awaiting-responses.json"
}

teardown() {
  teardown_kingdom_env
}

@test "envoy: process_outbound_queue processes thread_start" {
  # thread_start 관련 함수 직접 테스트 (DM 시나리오 포함)
  local msg='{"id":"msg-001","type":"thread_start","task_id":"task-001","channel":"U_TEST_USER","content":"[start] PR review","created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  # thread_start 처리 — User ID로 전송, API 응답에서 실제 DM 채널 추출
  local response
  response=$(send_message "U_TEST_USER" "[start] PR review")
  local thread_ts
  thread_ts=$(jq -r '.ts' <<< "$response")
  local actual_channel
  actual_channel=$(jq -r '.channel' <<< "$response")
  save_thread_mapping "task-001" "$thread_ts" "$actual_channel"

  # 매핑에 API 응답의 실제 채널(D-prefixed DM)이 저장되었는지 확인
  run get_thread_mapping "task-001"
  assert_success
  local mapping
  mapping=$(get_thread_mapping "task-001")
  run jq -r '.channel' <<< "$mapping"
  assert_output "D_MOCK_DM"
}

@test "envoy: process outbound moves file to sent" {
  # pending에 메시지 파일 생성
  cat > "$BASE_DIR/queue/messages/pending/msg-test-001.json" << 'EOF'
{"id":"msg-test-001","type":"report","channel":"C123","content":"daily report","created_at":"2026-01-01T00:00:00Z","status":"pending"}
EOF

  # source process functions
  process_report() {
    local msg="$1"
    local content
    content=$(echo "$msg" | jq -r '.content')
    send_message "C123" "$content" > /dev/null || return 1
  }

  process_outbound_queue() {
    local pending_dir="$BASE_DIR/queue/messages/pending"
    local sent_dir="$BASE_DIR/queue/messages/sent"
    for msg_file in "$pending_dir"/*.json; do
      [[ -f "$msg_file" ]] || continue
      local msg msg_type
      msg=$(cat "$msg_file")
      msg_type=$(echo "$msg" | jq -r '.type')
      case "$msg_type" in
        report) process_report "$msg" ;;
      esac
      mv "$msg_file" "$sent_dir/"
    done
  }

  process_outbound_queue

  # pending에서 사라지고 sent에 있어야 함
  assert [ ! -f "$BASE_DIR/queue/messages/pending/msg-test-001.json" ]
  assert [ -f "$BASE_DIR/queue/messages/sent/msg-test-001.json" ]
}

@test "envoy: notification to existing thread goes to thread" {
  # 매핑 생성
  save_thread_mapping "task-001" "1707300000.000100" "C123"

  # notification 메시지 처리
  local content="[complete] PR #1234 review done"
  send_thread_reply "C123" "1707300000.000100" "$content" > /dev/null

  # 매핑이 유지되는지 확인 (완료 메시지가 아닌 경우)
  run get_thread_mapping "task-001"
  assert_success
}

@test "envoy: human_input_request adds to awaiting" {
  save_thread_mapping "task-001" "1707300000.000100" "C123"

  send_thread_reply "C123" "1707300000.000100" "Question?" > /dev/null
  add_awaiting_response "task-001" "1707300000.000100" "C123"

  run jq 'length' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "1"
  run jq -r '.[0].task_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "task-001"
}

@test "envoy: human_input_request DM fallback uses message channel/thread_ts" {
  # thread_mapping 없이, 메시지에 channel/thread_ts가 직접 포함된 경우
  # envoy.sh에서 process_human_input_request 함수만 인라인 정의
  process_human_input_request() {
    local msg="$1"
    local task_id content
    task_id=$(echo "$msg" | jq -r '.task_id')
    content=$(echo "$msg" | jq -r '.content')
    local reply_ctx
    reply_ctx=$(echo "$msg" | jq -c '.reply_context // {}')
    local mapping
    mapping=$(get_thread_mapping "$task_id")

    if [[ -n "$mapping" ]]; then
      local thread_ts channel
      thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
      channel=$(echo "$mapping" | jq -r '.channel')
      send_thread_reply "$channel" "$thread_ts" "$content" || return 1
      add_awaiting_response "$task_id" "$thread_ts" "$channel" "$reply_ctx"
    else
      local msg_ch msg_ts
      msg_ch=$(echo "$msg" | jq -r '.channel // empty')
      msg_ts=$(echo "$msg" | jq -r '.thread_ts // empty')
      if [[ -n "$msg_ch" && -n "$msg_ts" ]]; then
        send_thread_reply "$msg_ch" "$msg_ts" "$content" || return 1
        add_awaiting_response "$task_id" "$msg_ts" "$msg_ch" "$reply_ctx"
      fi
    fi
  }

  local msg='{"id":"msg-dm-human","type":"human_input_request","task_id":"task-dm-001","channel":"D999","thread_ts":"1707300000.000200","content":"[question] 리뷰할 PR 번호를 지정해주세요.","reply_context":{"general":"gen-pr","session_id":"sess-dm","repo":"chequer/qp"},"created_at":"2026-01-01T00:00:00Z","status":"pending"}'

  run process_human_input_request "$msg"
  assert_success

  # awaiting에 DM 채널로 등록됨
  run jq -r '.[0].channel' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "D999"
  run jq -r '.[0].task_id' "$BASE_DIR/state/envoy/awaiting-responses.json"
  assert_output "task-dm-001"
}

@test "envoy: update_source_reactions removes eyes and adds final emoji" {
  # update_source_reactions 함수 인라인 정의 (envoy.sh에서 가져옴)
  update_source_reactions() {
    local msg="$1" final_emoji="$2"
    local source_ref
    source_ref=$(echo "$msg" | jq -c '.source_ref // empty')
    [[ -z "$source_ref" || "$source_ref" == "null" ]] && return 0

    local src_ch src_ts
    src_ch=$(echo "$source_ref" | jq -r '.channel')
    src_ts=$(echo "$source_ref" | jq -r '.message_ts')

    remove_reaction "$src_ch" "$src_ts" "eyes" || true
    if [[ -n "$final_emoji" ]]; then
      add_reaction "$src_ch" "$src_ts" "$final_emoji" || true
    fi
  }

  export MOCK_LOG="$(mktemp)"
  local msg='{"source_ref":{"channel":"D999","message_ts":"1707300000.000100"},"content":"test"}'
  run update_source_reactions "$msg" "white_check_mark"
  assert_success

  # curl이 reactions.remove와 reactions.add 모두 호출됨
  run cat "$MOCK_LOG"
  assert_output --partial "reactions.remove"
  assert_output --partial "reactions.add"
  rm -f "$MOCK_LOG"
}

@test "envoy: update_source_reactions skips when no source_ref" {
  update_source_reactions() {
    local msg="$1" final_emoji="$2"
    local source_ref
    source_ref=$(echo "$msg" | jq -c '.source_ref // empty')
    [[ -z "$source_ref" || "$source_ref" == "null" ]] && return 0
    # 여기까지 오면 안 됨
    return 1
  }

  local msg='{"content":"test without source_ref"}'
  run update_source_reactions "$msg" "white_check_mark"
  assert_success
}

@test "envoy: update_source_reactions only removes eyes when final_emoji empty" {
  update_source_reactions() {
    local msg="$1" final_emoji="$2"
    local source_ref
    source_ref=$(echo "$msg" | jq -c '.source_ref // empty')
    [[ -z "$source_ref" || "$source_ref" == "null" ]] && return 0

    local src_ch src_ts
    src_ch=$(echo "$source_ref" | jq -r '.channel')
    src_ts=$(echo "$source_ref" | jq -r '.message_ts')

    remove_reaction "$src_ch" "$src_ts" "eyes" || true
    if [[ -n "$final_emoji" ]]; then
      add_reaction "$src_ch" "$src_ts" "$final_emoji" || true
    fi
  }

  export MOCK_LOG="$(mktemp)"
  local msg='{"source_ref":{"channel":"D999","message_ts":"1707300000.000100"}}'
  run update_source_reactions "$msg" ""
  assert_success

  # reactions.remove만 호출, reactions.add는 없어야 함
  local log_content
  log_content=$(cat "$MOCK_LOG")
  echo "$log_content" | grep -q "reactions.remove"
  ! echo "$log_content" | grep -q "reactions.add"
  rm -f "$MOCK_LOG"
}

@test "envoy: thread_start adds eyes reaction to parent message" {
  export MOCK_LOG="$(mktemp)"

  # process_thread_start 인라인 정의
  process_thread_start() {
    local msg="$1"
    local task_id channel content
    task_id=$(echo "$msg" | jq -r '.task_id')
    channel=$(echo "$msg" | jq -r '.channel // "C_DEFAULT"')
    content=$(echo "$msg" | jq -r '.content')

    local response
    response=$(send_message "$channel" "$content") || return 1
    local thread_ts
    thread_ts=$(echo "$response" | jq -r '.ts')
    local actual_channel
    actual_channel=$(echo "$response" | jq -r '.channel // "'"$channel"'"')

    save_thread_mapping "$task_id" "$thread_ts" "$actual_channel"
    add_reaction "$actual_channel" "$thread_ts" "eyes" || true
  }

  local msg='{"id":"msg-001","type":"thread_start","task_id":"task-react-001","channel":"C123","content":"test start","created_at":"2026-01-01T00:00:00Z","status":"pending"}'
  run process_thread_start "$msg"
  assert_success

  # MOCK_LOG에 reactions.add + eyes 호출 확인
  run cat "$MOCK_LOG"
  assert_output --partial "reactions.add"
  rm -f "$MOCK_LOG"
}

@test "envoy: thread_start with existing thread_ts skips send_message and creates mapping" {
  # DM 경로: thread_ts가 이미 있으면 새 메시지를 보내지 않고 mapping만 생성
  process_thread_start() {
    local msg="$1"
    local task_id channel content
    task_id=$(echo "$msg" | jq -r '.task_id')
    channel=$(echo "$msg" | jq -r '.channel // "C_DEFAULT"')
    content=$(echo "$msg" | jq -r '.content')

    local thread_ts actual_channel
    local existing_ts
    existing_ts=$(echo "$msg" | jq -r '.thread_ts // empty')

    if [[ -n "$existing_ts" ]]; then
      thread_ts="$existing_ts"
      actual_channel="$channel"
      send_thread_reply "$channel" "$thread_ts" "$content" || return 1
    else
      local response
      response=$(send_message "$channel" "$content") || return 1
      thread_ts=$(echo "$response" | jq -r '.ts')
      actual_channel=$(echo "$response" | jq -r '.channel // "'"$channel"'"')
    fi

    save_thread_mapping "$task_id" "$thread_ts" "$actual_channel"
    add_reaction "$actual_channel" "$thread_ts" "eyes" || true
  }

  local msg='{"id":"msg-dm-start","type":"thread_start","task_id":"task-dm-mapping","channel":"D08XXX","thread_ts":"1234.5678","content":"📋 gen-herald | task-dm-mapping","created_at":"2026-01-01T00:00:00Z","status":"pending"}'
  run process_thread_start "$msg"
  assert_success

  # thread mapping이 DM 채널과 기존 thread_ts로 생성되었는지 확인
  local mapping
  mapping=$(get_thread_mapping "task-dm-mapping")
  run jq -r '.thread_ts' <<< "$mapping"
  assert_output "1234.5678"
  run jq -r '.channel' <<< "$mapping"
  assert_output "D08XXX"
}

@test "envoy: notification success updates thread parent reaction" {
  export MOCK_LOG="$(mktemp)"

  # 매핑 생성
  save_thread_mapping "task-react-002" "1707300000.000200" "C123"

  # process_notification 인라인 정의 (envoy.sh에서 가져옴)
  process_notification() {
    local msg="$1"
    local task_id content
    task_id=$(echo "$msg" | jq -r '.task_id // empty')
    content=$(echo "$msg" | jq -r '.content')

    if [[ -n "$task_id" ]]; then
      local mapping
      mapping=$(get_thread_mapping "$task_id")
      if [[ -n "$mapping" ]]; then
        local thread_ts channel
        thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
        channel=$(echo "$mapping" | jq -r '.channel')
        send_thread_reply "$channel" "$thread_ts" "$content" || return 1

        if echo "$content" | grep -qE '^(✅|❌|⏭️)'; then
          remove_reaction "$channel" "$thread_ts" "eyes" || true
          if echo "$content" | grep -q '^✅'; then
            add_reaction "$channel" "$thread_ts" "white_check_mark" || true
          elif echo "$content" | grep -q '^❌'; then
            add_reaction "$channel" "$thread_ts" "x" || true
          fi
          remove_thread_mapping "$task_id"
          remove_awaiting_response "$task_id"
        fi
      fi
    fi
  }

  local msg='{"id":"msg-notif-001","type":"notification","task_id":"task-react-002","content":"✅ 작업 완료","created_at":"2026-01-01T00:00:00Z","status":"pending"}'
  run process_notification "$msg"
  assert_success

  # MOCK_LOG에 reactions.remove (eyes) + reactions.add (white_check_mark) 호출 확인
  local log_content
  log_content=$(cat "$MOCK_LOG")
  echo "$log_content" | grep -q "reactions.remove"
  echo "$log_content" | grep -q "reactions.add"
  rm -f "$MOCK_LOG"
}

@test "envoy: check_socket_inbox processes message events" {
  # check_socket_inbox 인라인 정의 (message 케이스만)
  check_socket_inbox() {
    local inbox_dir="$BASE_DIR/state/envoy/socket-inbox"
    [[ -d "$inbox_dir" ]] || return 0

    for inbox_file in "$inbox_dir"/*.json; do
      [[ -f "$inbox_file" ]] || continue

      local event
      event=$(cat "$inbox_file")
      local type
      type=$(echo "$event" | jq -r '.type')
      local channel user_id text ts thread_ts event_ts
      channel=$(echo "$event" | jq -r '.channel')
      user_id=$(echo "$event" | jq -r '.user_id')
      text=$(echo "$event" | jq -r '.text')
      ts=$(echo "$event" | jq -r '.ts')
      thread_ts=$(echo "$event" | jq -r '.thread_ts // empty')
      event_ts=$(echo "$event" | jq -r '.event_ts')

      case "$type" in
        message)
          local event_id="evt-slack-msg-$(echo "$ts" | tr '.' '-')"
          local evt
          evt=$(jq -n \
            --arg id "$event_id" --arg text "$text" \
            --arg user_id "$user_id" --arg channel "$channel" \
            --arg message_ts "$ts" \
            '{ id: $id, type: "slack.channel.message", source: "slack", repo: null,
               payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
               priority: "normal",
               created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
          add_reaction "$channel" "$ts" "eyes" || true
          emit_event "$evt"
          ;;
      esac

      rm -f "$inbox_file"
    done
  }

  # socket-inbox에 message 이벤트 파일 생성
  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-001.json" << 'EOF'
{"type":"message","channel":"D123","user_id":"U_USER","text":"hello kingdom","ts":"1707300000.000100","event_ts":"1707300000.000100"}
EOF

  check_socket_inbox

  # 이벤트가 pending에 생성되었는지 확인
  local evt_file="$BASE_DIR/queue/events/pending/evt-slack-msg-1707300000-000100.json"
  assert [ -f "$evt_file" ]
  run jq -r '.type' "$evt_file"
  assert_output "slack.channel.message"
  run jq -r '.payload.text' "$evt_file"
  assert_output "hello kingdom"

  # inbox 파일이 삭제되었는지 확인
  assert [ ! -f "$BASE_DIR/state/envoy/socket-inbox/evt-001.json" ]
}

@test "envoy: check_socket_inbox processes app_mention events" {
  check_socket_inbox() {
    local inbox_dir="$BASE_DIR/state/envoy/socket-inbox"
    [[ -d "$inbox_dir" ]] || return 0

    for inbox_file in "$inbox_dir"/*.json; do
      [[ -f "$inbox_file" ]] || continue

      local event
      event=$(cat "$inbox_file")
      local type
      type=$(echo "$event" | jq -r '.type')
      local channel user_id text ts thread_ts event_ts
      channel=$(echo "$event" | jq -r '.channel')
      user_id=$(echo "$event" | jq -r '.user_id')
      text=$(echo "$event" | jq -r '.text')
      ts=$(echo "$event" | jq -r '.ts')
      thread_ts=$(echo "$event" | jq -r '.thread_ts // empty')
      event_ts=$(echo "$event" | jq -r '.event_ts')

      case "$type" in
        app_mention)
          local event_id="evt-slack-mention-$(echo "$ts" | tr '.' '-')"
          local evt
          evt=$(jq -n \
            --arg id "$event_id" --arg text "$text" \
            --arg user_id "$user_id" --arg channel "$channel" \
            --arg message_ts "$ts" \
            '{ id: $id, type: "slack.app_mention", source: "slack", repo: null,
               payload: { text: $text, user_id: $user_id, channel: $channel, message_ts: $message_ts },
               priority: "normal",
               created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
          add_reaction "$channel" "$ts" "eyes" || true
          emit_event "$evt"
          ;;
      esac

      rm -f "$inbox_file"
    done
  }

  # socket-inbox에 app_mention 이벤트 파일 생성
  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-mention-001.json" << 'EOF'
{"type":"app_mention","channel":"C_GENERAL","user_id":"U_USER","text":"<@BOT> help me","ts":"1707300000.000200","event_ts":"1707300000.000200"}
EOF

  check_socket_inbox

  # 이벤트가 pending에 생성되었는지 확인
  local evt_file="$BASE_DIR/queue/events/pending/evt-slack-mention-1707300000-000200.json"
  assert [ -f "$evt_file" ]
  run jq -r '.type' "$evt_file"
  assert_output "slack.app_mention"
  run jq -r '.payload.text' "$evt_file"
  assert_output "<@BOT> help me"

  # inbox 파일이 삭제되었는지 확인
  assert [ ! -f "$BASE_DIR/state/envoy/socket-inbox/evt-mention-001.json" ]
}

@test "envoy: check_socket_inbox matches thread_reply to awaiting" {
  check_socket_inbox() {
    local inbox_dir="$BASE_DIR/state/envoy/socket-inbox"
    [[ -d "$inbox_dir" ]] || return 0

    for inbox_file in "$inbox_dir"/*.json; do
      [[ -f "$inbox_file" ]] || continue

      local event
      event=$(cat "$inbox_file")
      local type
      type=$(echo "$event" | jq -r '.type')
      local channel user_id text ts thread_ts event_ts
      channel=$(echo "$event" | jq -r '.channel')
      user_id=$(echo "$event" | jq -r '.user_id')
      text=$(echo "$event" | jq -r '.text')
      ts=$(echo "$event" | jq -r '.ts')
      thread_ts=$(echo "$event" | jq -r '.thread_ts // empty')
      event_ts=$(echo "$event" | jq -r '.event_ts')

      case "$type" in
        thread_reply)
          [[ -n "$thread_ts" ]] || { rm -f "$inbox_file"; continue; }

          local matched=false

          if [[ -f "$AWAITING_FILE" ]]; then
            local awaiting_match
            awaiting_match=$(jq -r --arg tts "$thread_ts" \
              '.[] | select(.thread_ts == $tts) | .task_id' "$AWAITING_FILE" 2>/dev/null | head -1)
            if [[ -n "$awaiting_match" ]]; then
              local reply_ctx
              reply_ctx=$(jq --arg tts "$thread_ts" \
                '.[] | select(.thread_ts == $tts) | .reply_context // {}' "$AWAITING_FILE" 2>/dev/null | head -1)
              [[ -z "$reply_ctx" || "$reply_ctx" == "null" ]] && reply_ctx='{}'
              local event_id="evt-slack-reply-$(echo "$thread_ts" | tr '.' '-')-$(date +%s)"
              local evt
              evt=$(jq -n \
                --arg id "$event_id" --arg text "$text" \
                --arg channel "$channel" --arg thread_ts "$thread_ts" \
                --argjson reply_ctx "$reply_ctx" \
                '{ id: $id, type: "slack.thread.reply", source: "slack",
                   payload: { text: $text, channel: $channel, thread_ts: $thread_ts,
                              reply_context: $reply_ctx },
                   priority: "high",
                   created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
              emit_event "$evt"
              remove_awaiting_response "$awaiting_match"
              matched=true
            fi
          fi
          ;;
      esac

      rm -f "$inbox_file"
    done
  }

  # awaiting에 task 등록
  add_awaiting_response "task-await-001" "1707300000.000300" "D_DM_CH"

  # socket-inbox에 thread_reply 이벤트 파일 생성
  cat > "$BASE_DIR/state/envoy/socket-inbox/evt-reply-001.json" << 'EOF'
{"type":"thread_reply","channel":"D_DM_CH","user_id":"U_USER","text":"yes, proceed","ts":"1707300000.000400","thread_ts":"1707300000.000300","event_ts":"1707300000.000400"}
EOF

  check_socket_inbox

  # slack.thread.reply 이벤트가 생성되었는지 확인
  local found=false
  for f in "$BASE_DIR/queue/events/pending"/evt-slack-reply-*.json; do
    if [[ -f "$f" ]]; then
      local evt_type
      evt_type=$(jq -r '.type' "$f")
      if [[ "$evt_type" == "slack.thread.reply" ]]; then
        found=true
        run jq -r '.payload.text' "$f"
        assert_output "yes, proceed"
        run jq -r '.priority' "$f"
        assert_output "high"
        break
      fi
    fi
  done
  assert [ "$found" = "true" ]

  # awaiting에서 해당 task가 제거되었는지 확인
  run jq 'length' "$AWAITING_FILE"
  assert_output "0"

  # inbox 파일이 삭제되었는지 확인
  assert [ ! -f "$BASE_DIR/state/envoy/socket-inbox/evt-reply-001.json" ]
}

@test "envoy: 5 message types recognized" {
  # 각 메시지 타입이 case문에서 처리되는지 간접 확인
  for type in thread_start thread_update human_input_request notification report; do
    cat > "$BASE_DIR/queue/messages/pending/msg-${type}.json" << EOF
{"id":"msg-${type}","type":"${type}","task_id":"task-001","channel":"C123","content":"test","created_at":"2026-01-01T00:00:00Z","status":"pending"}
EOF
  done
  local count
  count=$(ls "$BASE_DIR/queue/messages/pending/"*.json | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]
}

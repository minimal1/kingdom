#!/usr/bin/env bash
# King message/id helpers

next_seq_id() {
  local prefix="$1"
  local seq_file="$2"
  local result_file="${seq_file}.result"
  local today
  today=$(date +%Y%m%d)

  portable_flock "$seq_file.lock" "
    last=\$(cat \"$seq_file\" 2>/dev/null || echo '00000000:000')
    last_date=\${last%%:*}
    last_seq=\${last##*:}

    if [ \"\$last_date\" = \"$today\" ]; then
      seq=\$((10#\$last_seq + 1))
    else
      seq=1
    fi

    formatted=\$(printf '%03d' \"\$seq\")
    printf '%s\n' \"$today:\$formatted\" > \"$seq_file\"
    printf '%s\n' \"$prefix-$today-\$formatted\" > \"$result_file\"
  " || return 1

  cat "$result_file"
  rm -f "$result_file"
}

next_task_id() {
  next_seq_id "task" "$TASK_SEQ_FILE"
}

next_msg_id() {
  next_seq_id "msg" "$MSG_SEQ_FILE"
}

extract_source_ref() {
  local task="$1"
  local src_msg_ts src_ch
  src_msg_ts=$(echo "$task" | jq -r '.payload.message_ts // empty')
  src_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  if [[ -n "$src_msg_ts" && -n "$src_ch" ]]; then
    jq -n --arg ch "$src_ch" --arg ts "$src_msg_ts" '{channel: $ch, message_ts: $ts}'
  else
    echo "null"
  fi
}

write_to_queue() {
  local dir="$1"
  local id="$2"
  local json="$3"
  atomic_write_json_file "$dir" "${id}.json" "$json"
}

format_task_context() {
  local type="$1"
  local payload="$2"

  case "$type" in
    github.pr.*|github.issue.*)
      local title pr_number repo_name html_url
      title=$(echo "$payload" | jq -r '.subject_title // empty')
      pr_number=$(echo "$payload" | jq -r '.pr_number // empty')
      repo_name=$(echo "$payload" | jq -r '.repo // empty')
      if [[ -n "$pr_number" && -n "$repo_name" ]]; then
        html_url="https://github.com/${repo_name}/pull/${pr_number}"
        printf '<%s|#%s %s>' "$html_url" "$pr_number" "$title"
      elif [[ -n "$title" ]]; then
        printf '%s' "$title"
      fi
      ;;
    jira.ticket.*)
      local url ticket_key summary
      url=$(echo "$payload" | jq -r '.url // empty')
      ticket_key=$(echo "$payload" | jq -r '.ticket_key // empty')
      summary=$(echo "$payload" | jq -r '.summary // empty')
      if [[ -n "$url" && -n "$ticket_key" ]]; then
        printf '<%s|%s %s>' "$url" "$ticket_key" "$summary"
      elif [[ -n "$summary" ]]; then
        printf '%s' "$summary"
      fi
      ;;
  esac
}

create_thread_start_message() {
  local task_id="$1"
  local general="$2"
  local event="$3"
  local event_type
  event_type=$(echo "$event" | jq -r '.type')
  local repo
  repo=$(echo "$event" | jq -r '.repo // ""')
  local msg_id
  msg_id=$(next_msg_id) || return 1
  local channel
  channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"

  local payload
  payload=$(echo "$event" | jq -c '.payload // {}')
  if [[ -n "$repo" ]]; then
    payload=$(echo "$payload" | jq --arg r "$repo" '.repo //= $r')
  fi
  local ctx
  ctx=$(format_task_context "$event_type" "$payload")

  local content
  if [[ -n "$ctx" ]]; then
    content=$(printf '📋 *%s* | %s\n%s\n`%s`' "$general" "$task_id" "$ctx" "$event_type")
  else
    content=$(printf '📋 *%s* | %s\n`%s`' "$general" "$task_id" "$event_type")
    [ -n "$repo" ] && content=$(printf '📋 *%s* | %s\n`%s` | %s' "$general" "$task_id" "$event_type" "$repo")
  fi

  local existing_ts existing_ch
  existing_ts=$(echo "$event" | jq -r '.payload.message_ts // empty')
  existing_ch=$(echo "$event" | jq -r '.payload.channel // empty')

  local message
  if [[ -n "$existing_ts" && -n "$existing_ch" ]]; then
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$existing_ch" --arg ct "$content" \
      --arg ts "$existing_ts" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        thread_ts: $ts,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  else
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$channel" --arg ct "$content" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  fi

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_thread_update_message() {
  local task_id="$1"
  local content="$2"
  local msg_id
  msg_id=$(next_msg_id) || return 1

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
    '{id: $id, type: "thread_update", task_id: $task, content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_notification_message() {
  local task_id="$1"
  local content="$2"
  local override_channel="${3:-}"
  local source_ref_json="${4:-null}"
  local msg_id
  msg_id=$(next_msg_id) || return 1
  local channel
  if [ -n "$override_channel" ]; then
    channel="$override_channel"
  else
    channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"
  fi

  local message
  message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    --argjson sr "$source_ref_json" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "normal", content: $ct, source_ref: $sr,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
}

create_proclamation_message() {
  local task_id="$1" channel="$2" message="$3"
  local msg_id
  msg_id=$(next_msg_id) || return 1
  local proc_task_id="proclamation-${task_id}"

  local msg
  msg=$(jq -n \
    --arg id "$msg_id" --arg task "$proc_task_id" \
    --arg ch "$channel" --arg ct "$message" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "high", content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$msg"
}

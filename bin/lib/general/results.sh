#!/usr/bin/env bash
# General result reporting helpers

report_to_king() {
  local task_id="$1"
  local status="$2"
  local summary="$3"
  local raw_result="$4"

  local result_file="$BASE_DIR/state/results/${task_id}.json"
  local tmp_file="${result_file}.tmp"

  if [ -n "$raw_result" ] && [ "$raw_result" != "" ]; then
    echo "$raw_result" | jq --arg s "$status" --arg tid "$task_id" '.status = $s | .task_id = $tid' > "$tmp_file"
  else
    jq -n \
      --arg task_id "$task_id" \
      --arg status "$status" \
      --arg summary "$summary" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id: $task_id, status: $status, summary: $summary, completed_at: $ts}' \
      > "$tmp_file"
  fi

  mv "$tmp_file" "$result_file"
  log "[EVENT] [$GENERAL_DOMAIN] Reported to king: $task_id ($status)"
}

escalate_to_king() {
  local task_id="$1"
  local result="$2"

  local checkpoint_file="$BASE_DIR/state/results/${task_id}-checkpoint.json"
  local task
  task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null || echo '{}')

  local session_id=""
  local session_id_file="$BASE_DIR/state/results/${task_id}-session-id"
  if [ -f "$session_id_file" ]; then
    session_id=$(cat "$session_id_file")
  fi

  jq -n \
    --arg task_id "$task_id" \
    --arg general "$GENERAL_DOMAIN" \
    --argjson repo "$(echo "$task" | jq '.repo')" \
    --argjson payload "$(echo "$task" | jq '.payload')" \
    --arg session_id "$session_id" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id: $task_id, target_general: $general, repo: $repo,
      payload: $payload, session_id: $session_id, created_at: $ts}' \
    > "$checkpoint_file"

  local result_file="$BASE_DIR/state/results/${task_id}.json"
  local tmp_file="${result_file}.tmp"

  echo "$result" | jq \
    --arg cp "$checkpoint_file" \
    '.status = "needs_human" | .checkpoint_path = $cp' \
    > "$tmp_file"
  mv "$tmp_file" "$result_file"

  log "[EVENT] [$GENERAL_DOMAIN] Escalated to king: $task_id (needs_human)"
}

#!/usr/bin/env bash
# General main loop

main_loop() {
  local max_retries
  max_retries=$(get_config "generals/$GENERAL_DOMAIN" "retry.max_attempts" 2)
  local retry_backoff
  retry_backoff=$(get_config "generals/$GENERAL_DOMAIN" "retry.backoff_seconds" 60)

  RUNNING=true
  trap 'RUNNING=false; stop_heartbeat_daemon; rm -f /tmp/kingdom-wake-$$.fifo; log "[SYSTEM] [$GENERAL_DOMAIN] Shutting down..."; exit 0' SIGTERM SIGINT

  log "[SYSTEM] [$GENERAL_DOMAIN] Started."
  start_heartbeat_daemon "$GENERAL_DOMAIN"

  while $RUNNING; do
    local task_file
    task_file=$(pick_next_task "$GENERAL_DOMAIN")
    if [ -z "$task_file" ]; then
      sleep_or_wake 10 "$BASE_DIR/queue/tasks/pending"
      continue
    fi

    local task
    task=$(cat "$task_file")
    local task_id
    task_id=$(echo "$task" | jq -r '.id')

    mv "$task_file" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
    log "[EVENT] [$GENERAL_DOMAIN] Task claimed: $task_id"

    local repo
    repo=$(echo "$task" | jq -r '.repo // empty')
    local work_dir="$BASE_DIR/workspace/$GENERAL_DOMAIN"
    if [ -n "$repo" ]; then
      work_dir=$(ensure_workspace "$GENERAL_DOMAIN" "$repo") || {
        report_to_king "$task_id" "failed" "Workspace setup failed for $repo"
        continue
      }
    fi

    sync_general_agents "$GENERAL_DOMAIN" "$work_dir"

    local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
    local task_type
    task_type=$(echo "$task" | jq -r '.type // ""')
    local resume_session_id=""
    if [ "$task_type" = "resume" ]; then
      resume_session_id=$(echo "$task" | jq -r '.payload.session_id // ""')
    fi

    if [ -n "$resume_session_id" ]; then
      local human_response
      human_response=$(echo "$task" | jq -r '.payload.human_response // ""')
      printf '사람의 응답: %s\n\n이전 작업을 이어서 진행하라.\n' "$human_response" > "$prompt_file"
      log "[SYSTEM] [$GENERAL_DOMAIN] Resume prompt built for task: $task_id (session: $resume_session_id)"
    else
      build_prompt "$task" > "$prompt_file"
    fi
    check_prompt_size "$prompt_file"

    local attempt=0
    local final_status="failed"
    local final_result=""

    while (( attempt <= max_retries )); do
      local raw_file="$BASE_DIR/state/results/${task_id}-raw.json"
      rm -f "$raw_file"

      spawn_soldier "$task_id" "$prompt_file" "$work_dir" || {
        attempt=$((attempt + 1))
        continue
      }

      local timeout
      timeout=$(get_config "generals/$GENERAL_DOMAIN" "timeout_seconds" 1800)
      wait_for_soldier "$task_id" "$raw_file" "$timeout"

      if [ ! -f "$raw_file" ]; then
        log "[ERROR] [$GENERAL_DOMAIN] No result file: $task_id (attempt $attempt)"
        attempt=$((attempt + 1))
        continue
      fi

      local result
      result=$(cat "$raw_file")
      local status
      status=$(echo "$result" | jq -r '.status // "failed"')

      case "$status" in
        success)
          final_status="success"
          final_result="$result"
          update_memory "$result"
          break
          ;;
        needs_human)
          final_status="needs_human"
          final_result="$result"
          break
          ;;
        skipped)
          final_status="skipped"
          final_result="$result"
          break
          ;;
        failed)
          local error
          error=$(echo "$result" | jq -r '.error // "unknown"')
          log "[WARN] [$GENERAL_DOMAIN] Attempt $attempt failed: $task_id — $error"
          attempt=$((attempt + 1))
          if (( attempt <= max_retries )); then
            log "[EVENT] [$GENERAL_DOMAIN] Retrying in ${retry_backoff}s"
            sleep "$retry_backoff"
          fi
          ;;
        *)
          log "[WARN] [$GENERAL_DOMAIN] Unknown status '$status': $task_id"
          attempt=$((attempt + 1))
          ;;
      esac
    done

    if [ "$final_status" = "needs_human" ]; then
      escalate_to_king "$task_id" "$final_result"
    else
      report_to_king "$task_id" "$final_status" \
        "$(echo "$final_result" | jq -r '.summary // "no summary"')" \
        "$final_result"
    fi

    sleep_or_wake 5 "$BASE_DIR/queue/tasks/pending"
  done
}

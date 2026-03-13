#!/usr/bin/env bash
# General soldier lifecycle helpers

spawn_soldier() {
  local task_id="$1"
  local prompt_file="$2"
  local work_dir="$3"

  if [ ! -f "$prompt_file" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Prompt file not found: $prompt_file"
    return 1
  fi
  if [ ! -d "$work_dir" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Work directory not found: $work_dir"
    return 1
  fi

  local resume_session_id=""
  local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  if [ -f "$task_file" ]; then
    local task_type
    task_type=$(jq -r '.type // ""' "$task_file" 2>/dev/null || true)
    if [ "$task_type" = "resume" ]; then
      resume_session_id=$(jq -r '.payload.session_id // ""' "$task_file" 2>/dev/null || true)
      if [ -n "$resume_session_id" ]; then
        log "[SYSTEM] [$GENERAL_DOMAIN] Resume session_id from payload: $resume_session_id"
      fi
    fi
  fi

  local spawn_script="${SPAWN_SOLDIER_SCRIPT:-$_GENERAL_LIB_DIR/../../spawn-soldier.sh}"
  "$spawn_script" "$task_id" "$prompt_file" "$work_dir" "$resume_session_id"
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log "[ERROR] [$GENERAL_DOMAIN] spawn-soldier.sh failed for task: $task_id"
    return 1
  fi

  local soldier_id
  soldier_id=$(cat "$BASE_DIR/state/results/${task_id}-soldier-id" 2>/dev/null)
  if [ -n "$soldier_id" ]; then
    local session_entry
    session_entry=$(jq -n \
      --arg id "$soldier_id" \
      --arg task "$task_id" \
      --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{id: $id, task_id: $task, started_at: $started}')

    portable_flock "$BASE_DIR/state/sessions.lock" "
      local current=\$(cat '$BASE_DIR/state/sessions.json' 2>/dev/null || echo '[]')
      echo \"\$current\" | jq --argjson entry '$session_entry' '. + [\$entry]' > '$BASE_DIR/state/sessions.json'
    "
  fi
}

wait_for_soldier() {
  local task_id="$1"
  local raw_file="$2"
  local timeout=${3:-1800}
  local waited=0
  local health_check_interval=10

  local soldier_id=""
  local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"
  if [ -f "$soldier_id_file" ]; then
    soldier_id=$(cat "$soldier_id_file")
  fi

  local heartbeat_file="$BASE_DIR/state/results/${task_id}-heartbeat"
  local heartbeat_grace=30
  local hard_max=$((timeout * 2))
  local extended=false

  while [ ! -f "$raw_file" ] && (( waited < timeout )); do
    sleep 1
    waited=$((waited + 1))

    if (( waited % health_check_interval == 0 )) && [ -n "$soldier_id" ]; then
      if ! tmux has-session -t "$soldier_id" 2>/dev/null; then
        log "[WARN] [$GENERAL_DOMAIN] Soldier session dead: $soldier_id (task: $task_id, waited: ${waited}s)"
        break
      fi
    fi

    if (( waited >= timeout )) && (( timeout < hard_max )); then
      if [ -f "$heartbeat_file" ]; then
        local hb_mtime now hb_age
        hb_mtime=$(get_mtime "$heartbeat_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        hb_age=$((now - hb_mtime))
        if (( hb_age <= heartbeat_grace )); then
          timeout=$((timeout + 60))
          if (( timeout > hard_max )); then
            timeout=$hard_max
          fi
          if [ "$extended" = false ]; then
            log "[INFO] [$GENERAL_DOMAIN] Soldier still active (heartbeat ${hb_age}s ago), extending timeout (task: $task_id)"
            extended=true
          fi
        fi
      fi
    fi
  done

  if [ ! -f "$raw_file" ]; then
    local result_status="failed"
    local reason="Timeout after ${waited} seconds"

    if [ "$extended" = true ]; then
      reason="Timeout after ${waited} seconds (extended from original, heartbeat stale)"
    fi

    if (( waited < timeout )); then
      result_status="killed"
      reason="Soldier session died after ${waited} seconds"
    else
      log "[ERROR] [$GENERAL_DOMAIN] Soldier timeout: $task_id (>${waited}s)"
    fi

    if [ -n "$soldier_id" ] && tmux has-session -t "$soldier_id" 2>/dev/null; then
      tmux kill-session -t "$soldier_id"
      log "[SYSTEM] [$GENERAL_DOMAIN] Killed soldier session: $soldier_id"
    fi

    jq -n \
      --arg task_id "$task_id" \
      --arg status "$result_status" \
      --arg error "$reason" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id: $task_id, status: $status, error: $error, completed_at: $ts}' \
      > "$raw_file"
  fi
}

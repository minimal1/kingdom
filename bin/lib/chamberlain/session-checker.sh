#!/usr/bin/env bash
# Chamberlain Session Checker — heartbeat monitoring + session cleanup

# --- Heartbeat Monitoring ---

check_heartbeats() {
  local threshold
  threshold=$(get_config "chamberlain" "heartbeat.threshold_seconds" 120)
  local now
  now=$(date +%s)

  # Core roles
  local targets=("sentinel" "king" "envoy")

  # Add active generals from manifests
  for manifest in "$BASE_DIR/config/generals/"*.yaml; do
    [ -f "$manifest" ] || continue
    local name=""
    if command -v yq &>/dev/null; then
      name=$(yq eval '.name' "$manifest" 2>/dev/null)
    else
      name=$(grep -m1 '^name:' "$manifest" | sed 's/^name:[[:space:]]*//' | tr -d '"'"'" 2>/dev/null)
    fi
    [ -n "$name" ] && [ "$name" != "null" ] && targets+=("$name")
  done

  for target in "${targets[@]}"; do
    local hb_file="$BASE_DIR/state/${target}/heartbeat"

    # No heartbeat file → not started yet, skip
    [ -f "$hb_file" ] || continue

    local mtime
    mtime=$(get_mtime "$hb_file" 2>/dev/null)

    if [ -z "$mtime" ]; then
      log "[WARN] [chamberlain] Cannot read mtime for $target heartbeat, skipping"
      continue
    fi

    local elapsed=$((now - mtime))

    if (( elapsed > threshold )); then
      log "[WARN] [chamberlain] Heartbeat missed: $target (${elapsed}s > ${threshold}s)"

      emit_internal_event "system.heartbeat_missed" "chamberlain" \
        "$(jq -n --arg target "$target" --argjson threshold "$threshold" \
                 '{target: $target, threshold_seconds: $threshold}')"

      handle_dead_role "$target"
    fi
  done
}

# --- Dead Role Handling ---

handle_dead_role() {
  local target="$1"
  local restart_sentinel
  restart_sentinel=$(get_config "chamberlain" "auto_recovery.restart_sentinel" true)

  case "$target" in
    sentinel)
      if [ "$restart_sentinel" = "true" ]; then
        log "[RECOVERY] [chamberlain] Restarting sentinel"
        tmux new-session -d -s sentinel "$BASE_DIR/bin/sentinel.sh"
        emit_internal_event "recovery.session_restarted" "chamberlain" \
          "$(jq -n --arg target "sentinel" '{target: $target}')"
      else
        create_alert_message "sentinel 세션 죽음 감지 — 수동 복구 필요"
      fi
      ;;
    king)
      create_alert_message "[긴급] king 세션 죽음 감지 — 수동 복구 필요" "high"
      ;;
    gen-*)
      kill_soldiers_of_dead_general "$target"
      create_alert_message "$target 세션 죽음 감지 — 소속 병사 정리됨"
      ;;
    *)
      create_alert_message "$target 세션 죽음 감지 — 확인 필요"
      ;;
  esac
}

# --- Soldier Cleanup ---

kill_soldiers_of_dead_general() {
  local general="$1"
  local killed=0

  for task_file in "$BASE_DIR/queue/tasks/in_progress/"*.json; do
    [ -f "$task_file" ] || continue

    local target_general
    target_general=$(jq -r '.target_general' "$task_file" 2>/dev/null)
    [ "$target_general" = "$general" ] || continue

    local task_id
    task_id=$(jq -r '.id' "$task_file" 2>/dev/null)
    local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"

    if [ -f "$soldier_id_file" ]; then
      local soldier_id
      soldier_id=$(cat "$soldier_id_file")
      if tmux has-session -t "$soldier_id" 2>/dev/null; then
        tmux kill-session -t "$soldier_id"
        killed=$((killed + 1))
        log "[RECOVERY] [chamberlain] Killed orphan soldier: $soldier_id (general: $general, task: $task_id)"
        emit_internal_event "soldier.killed" "chamberlain" \
          "$(jq -n --arg sid "$soldier_id" --arg reason "general_dead" \
                   '{soldier_id: $sid, reason: $reason}')"
      fi
    fi
  done

  if (( killed > 0 )); then
    log "[RECOVERY] [chamberlain] Killed $killed orphan soldiers of $general"
  fi
}

# --- Session Cleanup ---

check_and_clean_sessions() {
  local sessions_file="$BASE_DIR/state/sessions.json"
  [ -f "$sessions_file" ] || return 0

  local sessions
  sessions=$(cat "$sessions_file" 2>/dev/null)
  [ -z "$sessions" ] && return 0

  local count
  count=$(echo "$sessions" | jq 'length' 2>/dev/null || echo 0)
  (( count == 0 )) && return 0

  local alive_sessions="[]"
  local removed=0

  for ((i=0; i<count; i++)); do
    local entry
    entry=$(echo "$sessions" | jq -c ".[$i]")
    local soldier_id
    soldier_id=$(echo "$entry" | jq -r '.id')
    local task_id
    task_id=$(echo "$entry" | jq -r '.task_id')

    if tmux has-session -t "$soldier_id" 2>/dev/null; then
      alive_sessions=$(echo "$alive_sessions" | jq --argjson e "$entry" '. + [$e]')
    else
      removed=$((removed + 1))
      log "[CLEANUP] [chamberlain] Removed dead session: $soldier_id (task: $task_id)"
      emit_internal_event "system.session_orphaned" "chamberlain" \
        "$(jq -n --arg sid "$soldier_id" --arg tid "$task_id" \
                 '{soldier_id: $sid, task_id: $tid}')"
    fi
  done

  # Atomic write with lock
  portable_flock "$BASE_DIR/state/sessions.lock" "
    echo '$alive_sessions' > '${sessions_file}.tmp'
    mv '${sessions_file}.tmp' '$sessions_file'
  "

  if (( removed > 0 )); then
    emit_internal_event "recovery.sessions_cleaned" "chamberlain" \
      "$(jq -n --argjson count "$removed" '{removed_count: $count}')"
  fi
}

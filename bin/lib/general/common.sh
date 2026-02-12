#!/usr/bin/env bash
# General Common — shared functions for all generals

# GENERAL_DOMAIN must be set before sourcing this file

# prompt-builder.sh is sourced relative to this file's location
_GENERAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GENERAL_LIB_DIR/prompt-builder.sh"

# --- Task Selection ---

pick_next_task() {
  local general="$1"
  local pending_dir="$BASE_DIR/queue/tasks/pending"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local best_file=""
  local best_order=99

  for f in "$pending_dir"/*.json; do
    [ -f "$f" ] || continue

    local target
    target=$(jq -r '.target_general' "$f" 2>/dev/null)
    [ "$target" = "$general" ] || continue

    # Skip if retry_after is in the future
    local retry_after
    retry_after=$(jq -r '.retry_after // ""' "$f" 2>/dev/null)
    if [ -n "$retry_after" ] && [[ "$retry_after" > "$now" ]]; then
      continue
    fi

    local priority
    priority=$(jq -r '.priority' "$f" 2>/dev/null)
    local order=2
    case "$priority" in
      high) order=1 ;;
      normal) order=2 ;;
      low) order=3 ;;
    esac

    if (( order < best_order )); then
      best_order=$order
      best_file="$f"
    fi
  done

  echo "$best_file"
}

# --- Workspace Management ---

ensure_workspace() {
  local general="$1"
  local repo="$2"
  local work_dir="$BASE_DIR/workspace/$general"

  mkdir -p "$work_dir" || {
    log "[ERROR] [$general] Failed to create workspace: $work_dir"
    return 1
  }

  # CC Plugin validation (global enabledPlugins check)
  local manifest="$BASE_DIR/config/generals/${general}.yaml"
  if [ ! -f "$manifest" ]; then
    log "[ERROR] [$general] Manifest not found: $manifest"
    return 1
  fi

  local plugin_count
  plugin_count=$(yq eval '.cc_plugins | length' "$manifest" 2>/dev/null || echo "0")

  if (( plugin_count > 0 )); then
    local global_settings="$HOME/.claude/settings.json"
    if [ ! -f "$global_settings" ]; then
      log "[ERROR] [$general] ~/.claude/settings.json not found"
      return 1
    fi

    local i=0
    while (( i < plugin_count )); do
      local required_name
      required_name=$(yq eval ".cc_plugins[$i]" "$manifest")
      local found
      found=$(jq -r --arg n "$required_name" '.enabledPlugins // {} | keys[] | select(startswith($n + "@") or . == $n)' "$global_settings" | head -1)
      if [ -z "$found" ]; then
        log "[ERROR] [$general] Required plugin not enabled globally: $required_name"
        return 1
      fi
      i=$((i + 1))
    done
  fi

  # Repo clone/update
  if [ -n "$repo" ]; then
    local repo_dir="$work_dir/$(basename "$repo")"

    if [ ! -d "$repo_dir" ]; then
      log "[SYSTEM] [$general] Cloning repo: $repo"
      if ! git clone "git@github.com:${repo}.git" "$repo_dir" >/dev/null 2>&1; then
        log "[ERROR] [$general] Failed to clone repo: $repo"
        return 1
      fi
    else
      if ! git -C "$repo_dir" fetch origin >/dev/null 2>&1; then
        log "[WARN] [$general] Failed to fetch repo: $repo (continuing with stale)"
      fi
    fi
  fi

  echo "$work_dir"
}

# --- Memory ---

load_domain_memory() {
  local domain="$1"
  local memory_dir="$BASE_DIR/memory/generals/$domain"

  if [ -d "$memory_dir" ]; then
    cat "$memory_dir"/*.md 2>/dev/null | head -c 50000
  else
    echo ""
  fi
}

load_repo_memory() {
  local domain="$1"
  local repo="$2"

  [ -z "$repo" ] && echo "" && return 0

  local repo_slug
  repo_slug=$(echo "$repo" | tr '/' '-')
  local repo_file="$BASE_DIR/memory/generals/${domain}/repo-${repo_slug}.md"

  if [ -f "$repo_file" ]; then
    cat "$repo_file"
  else
    echo ""
  fi
}

update_memory() {
  local result="$1"
  local updates
  updates=$(echo "$result" | jq -r '.memory_updates[]' 2>/dev/null || true)

  [ -z "$updates" ] && return 0

  local memory_file="$BASE_DIR/memory/generals/${GENERAL_DOMAIN}/learned-patterns.md"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  portable_flock "$memory_file.lock" "
    echo '' >> '$memory_file'
    echo '### $timestamp' >> '$memory_file'
    echo '$updates' | while IFS= read -r line; do
      [ -n \"\$line\" ] && echo \"- \$line\" >> '$memory_file'
    done
  "

  local count
  count=$(echo "$updates" | grep -c '[^ ]' 2>/dev/null || echo 0)
  log "[SYSTEM] [$GENERAL_DOMAIN] Memory updated: $count new patterns"
}

# --- Soldier Management ---

spawn_soldier() {
  local task_id="$1"
  local prompt_file="$2"
  local work_dir="$3"

  # Pre-flight checks
  if [ ! -f "$prompt_file" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Prompt file not found: $prompt_file"
    return 1
  fi
  if [ ! -d "$work_dir" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Work directory not found: $work_dir"
    return 1
  fi

  # Spawn soldier via script (relative to this file's bin/ location)
  local spawn_script="${SPAWN_SOLDIER_SCRIPT:-$_GENERAL_LIB_DIR/../../spawn-soldier.sh}"
  "$spawn_script" "$task_id" "$prompt_file" "$work_dir"
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log "[ERROR] [$GENERAL_DOMAIN] spawn-soldier.sh failed for task: $task_id"
    return 1
  fi

  # Register session in sessions.json (with file lock)
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

  while [ ! -f "$raw_file" ] && (( waited < timeout )); do
    sleep 1
    waited=$((waited + 1))
  done

  # Timeout handling
  if (( waited >= timeout )) && [ ! -f "$raw_file" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Soldier timeout: $task_id (>${timeout}s)"

    local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"
    if [ -f "$soldier_id_file" ]; then
      local soldier_id
      soldier_id=$(cat "$soldier_id_file")
      if tmux has-session -t "$soldier_id" 2>/dev/null; then
        tmux kill-session -t "$soldier_id"
        log "[SYSTEM] [$GENERAL_DOMAIN] Killed soldier session: $soldier_id"
      fi
    fi

    jq -n \
      --arg task_id "$task_id" \
      --arg error "Timeout after ${timeout} seconds" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id: $task_id, status: "failed", error: $error, completed_at: $ts}' \
      > "$raw_file"
  fi
}

# --- Result Reporting ---

report_to_king() {
  local task_id="$1"
  local status="$2"
  local summary="$3"
  local raw_result="$4"

  local result_file="$BASE_DIR/state/results/${task_id}.json"
  local tmp_file="${result_file}.tmp"

  if [ -n "$raw_result" ] && [ "$raw_result" != "" ]; then
    echo "$raw_result" | jq --arg s "$status" '.status = $s' > "$tmp_file"
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

  jq -n \
    --arg task_id "$task_id" \
    --arg general "$GENERAL_DOMAIN" \
    --argjson repo "$(echo "$task" | jq '.repo')" \
    --argjson payload "$(echo "$task" | jq '.payload')" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id: $task_id, target_general: $general, repo: $repo,
      payload: $payload, created_at: $ts}' \
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

# --- Main Loop ---

main_loop() {
  local max_retries
  max_retries=$(get_config "generals/$GENERAL_DOMAIN" "retry.max_attempts" 2)
  local retry_backoff
  retry_backoff=$(get_config "generals/$GENERAL_DOMAIN" "retry.backoff_seconds" 60)

  RUNNING=true
  trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [$GENERAL_DOMAIN] Shutting down..."; exit 0' SIGTERM SIGINT

  log "[SYSTEM] [$GENERAL_DOMAIN] Started."

  start_heartbeat_daemon "$GENERAL_DOMAIN"

  while $RUNNING; do

    local task_file
    task_file=$(pick_next_task "$GENERAL_DOMAIN")
    if [ -z "$task_file" ]; then
      sleep 10
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

    local memory
    memory=$(load_domain_memory "$GENERAL_DOMAIN")
    local repo_context
    repo_context=$(load_repo_memory "$GENERAL_DOMAIN" "$repo")

    local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
    build_prompt "$task" "$memory" "$repo_context" > "$prompt_file"

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

    sleep 5
  done
}

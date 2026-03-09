#!/usr/bin/env bash
# bin/doctor.sh — 실패 태스크 진단 스크립트
# Usage:
#   bin/doctor.sh <task_id>              # 기본 진단
#   bin/doctor.sh <task_id> --deep       # + Claude session 상세 포함
#   bin/doctor.sh --recent [N]           # 최근 실패 N건 목록 (기본 5)
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

# ── Helpers ──────────────────────────────────────

print_field() {
  local label="$1"
  local value="$2"
  printf "  %-14s %s\n" "$label:" "$value"
}

human_size() {
  local bytes="$1"
  if [ "$bytes" -ge 1048576 ]; then
    echo "$((bytes / 1048576))MB"
  elif [ "$bytes" -ge 1024 ]; then
    echo "$((bytes / 1024))KB"
  else
    echo "${bytes}B"
  fi
}

# ── Recent Failures ─────────────────────────────

list_recent_failures() {
  local n="${1:-5}"
  local results_dir="$BASE_DIR/state/results"

  echo ""
  echo "=== Kingdom Doctor: Recent Failures ==="
  echo ""

  if [ ! -d "$results_dir" ]; then
    echo "  (no results directory)"
    return
  fi

  local count=0
  # Find failed results, sort by mtime descending
  local tmp_list
  tmp_list=$(mktemp)

  for f in "$results_dir"/*.json; do
    [ -f "$f" ] || continue
    local status
    status=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
    if [ "$status" = "failed" ]; then
      local mtime
      mtime=$(get_mtime "$f" 2>/dev/null || echo 0)
      echo "$mtime $f" >> "$tmp_list"
    fi
  done

  if [ ! -s "$tmp_list" ]; then
    echo "  (no failures found)"
    rm -f "$tmp_list"
    return
  fi

  sort -rn "$tmp_list" | head -n "$n" | while read -r _mtime filepath; do
    local task_id
    task_id=$(basename "$filepath" .json)
    local general error
    general=$(jq -r '.general // "(unknown)"' "$filepath" 2>/dev/null) || general="(unknown)"
    local task_type
    task_type=$(jq -r '.type // "(unknown)"' "$filepath" 2>/dev/null) || task_type="(unknown)"
    error=$(jq -r '.error // "(no error)"' "$filepath" 2>/dev/null) || error="(no error)"
    # Truncate error for display
    if [ ${#error} -gt 60 ]; then
      error="${error:0:57}..."
    fi
    printf "  %-24s %-14s %-10s %s\n" "$task_id" "$general" "$task_type" "\"$error\""
    count=$((count + 1))
  done

  rm -f "$tmp_list"
  echo ""
}

# ── Single Task Diagnosis ───────────────────────

diagnose_task() {
  local task_id="$1"
  local deep="${2:-false}"

  echo ""
  echo "=== Kingdom Doctor: $task_id ==="

  # --- Task Context ---
  echo ""
  echo "── Task Context ──────────────────────────"

  local task_file=""
  if [ -f "$BASE_DIR/queue/tasks/completed/${task_id}.json" ]; then
    task_file="$BASE_DIR/queue/tasks/completed/${task_id}.json"
  elif [ -f "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" ]; then
    task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  elif [ -f "$BASE_DIR/queue/tasks/pending/${task_id}.json" ]; then
    task_file="$BASE_DIR/queue/tasks/pending/${task_id}.json"
  fi

  if [ -n "$task_file" ]; then
    local general task_type repo priority created_at retry_count
    general=$(jq -r '.target_general // "(unknown)"' "$task_file" 2>/dev/null) || general="(unknown)"
    task_type=$(jq -r '.type // "(unknown)"' "$task_file" 2>/dev/null) || task_type="(unknown)"
    repo=$(jq -r '.repo // "(none)"' "$task_file" 2>/dev/null) || repo="(none)"
    priority=$(jq -r '.priority // "normal"' "$task_file" 2>/dev/null) || priority="normal"
    created_at=$(jq -r '.created_at // "(unknown)"' "$task_file" 2>/dev/null) || created_at="(unknown)"
    retry_count=$(jq -r '.retry_count // "0"' "$task_file" 2>/dev/null) || retry_count="0"
    print_field "General" "$general"
    print_field "Type" "$task_type"
    print_field "Repo" "$repo"
    print_field "Priority" "$priority"
    print_field "Created" "$created_at"
    print_field "Retry" "$retry_count"
  else
    echo "  (task file not found)"
  fi

  # --- Result ---
  echo ""
  echo "── Result ────────────────────────────────"

  local result_file="$BASE_DIR/state/results/${task_id}.json"
  if [ -f "$result_file" ]; then
    local status error summary
    status=$(jq -r '.status // "(unknown)"' "$result_file" 2>/dev/null) || status="(unknown)"
    error=$(jq -r '.error // "(none)"' "$result_file" 2>/dev/null) || error="(none)"
    summary=$(jq -r '.summary // "(none)"' "$result_file" 2>/dev/null) || summary="(none)"
    print_field "Status" "$status"
    print_field "Error" "$error"
    print_field "Summary" "$summary"
  else
    echo "  (result file not found)"
  fi

  # --- Soldier ---
  echo ""
  echo "── Soldier ───────────────────────────────"

  local soldier_id=""
  local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"
  if [ -f "$soldier_id_file" ]; then
    soldier_id=$(cat "$soldier_id_file" 2>/dev/null) || soldier_id=""
  fi

  local session_id=""
  local session_id_file="$BASE_DIR/state/results/${task_id}-session-id"
  if [ -f "$session_id_file" ]; then
    session_id=$(cat "$session_id_file" 2>/dev/null) || session_id=""
  fi

  local prompt_size="(not found)"
  local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
  if [ -f "$prompt_file" ]; then
    local bytes
    bytes=$(wc -c < "$prompt_file" 2>/dev/null) || bytes=0
    prompt_size=$(human_size "$bytes")
  fi

  print_field "Soldier ID" "${soldier_id:-(not found)}"
  print_field "Session ID" "${session_id:-(not found)}"
  print_field "Prompt Size" "$prompt_size"

  # --- stderr ---
  echo ""
  echo "── stderr (last 20 lines) ────────────────"

  if [ -n "$soldier_id" ] && [ -f "$BASE_DIR/logs/sessions/${soldier_id}.err" ]; then
    tail -20 "$BASE_DIR/logs/sessions/${soldier_id}.err" | sed 's/^/  /'
  else
    echo "  (not found)"
  fi

  # --- system.log timeline ---
  echo ""
  echo "── system.log timeline ───────────────────"

  if [ -f "$BASE_DIR/logs/system.log" ]; then
    local lines
    lines=$(grep "$task_id" "$BASE_DIR/logs/system.log" 2>/dev/null | tail -20) || true
    if [ -n "$lines" ]; then
      echo "$lines" | sed 's/^/  /'
    else
      echo "  (no log entries for this task)"
    fi
  else
    echo "  (system.log not found)"
  fi

  # --- Deep: Claude Session ---
  if [ "$deep" = "true" ]; then
    echo ""
    echo "── Claude Session (deep) ─────────────────"

    if [ -n "$soldier_id" ] && [ -f "$BASE_DIR/logs/sessions/${soldier_id}.json" ]; then
      local session_json="$BASE_DIR/logs/sessions/${soldier_id}.json"

      local input_tokens output_tokens
      input_tokens=$(jq -r '.result.usage.input_tokens // .usage.input_tokens // "(unknown)"' "$session_json" 2>/dev/null) || input_tokens="(unknown)"
      output_tokens=$(jq -r '.result.usage.output_tokens // .usage.output_tokens // "(unknown)"' "$session_json" 2>/dev/null) || output_tokens="(unknown)"

      print_field "Session ID" "${session_id:-(unknown)}"
      print_field "Input tokens" "$input_tokens"
      print_field "Output tokens" "$output_tokens"

      echo ""
      echo "  Tool calls (failed only):"

      # Extract tool uses with is_error=true
      local failed_tools
      failed_tools=$(jq -r '
        [.. | objects | select(.type == "tool_result" and .is_error == true)] |
        to_entries[] |
        "    [\(.key)] \(.value.tool_use_id // "?") → \(.value.content // "(no content)" | tostring | .[0:80])"
      ' "$session_json" 2>/dev/null) || true

      if [ -n "$failed_tools" ]; then
        echo "$failed_tools"
      else
        echo "    (none)"
      fi
    else
      echo "  (session file not found)"
    fi
  fi

  echo ""
}

# ── Main ────────────────────────────────────────

usage() {
  echo "Usage:"
  echo "  bin/doctor.sh <task_id>          # Diagnose a task"
  echo "  bin/doctor.sh <task_id> --deep   # + Claude session details"
  echo "  bin/doctor.sh --recent [N]       # List recent N failures (default 5)"
  exit 1
}

if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  --recent)
    list_recent_failures "${2:-5}"
    ;;
  --help|-h)
    usage
    ;;
  *)
    task_id="$1"
    deep="false"
    if [ "${2:-}" = "--deep" ]; then
      deep="true"
    fi
    diagnose_task "$task_id" "$deep"
    ;;
esac

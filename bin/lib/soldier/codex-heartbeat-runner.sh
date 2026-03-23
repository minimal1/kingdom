#!/usr/bin/env bash
# bin/lib/soldier/codex-heartbeat-runner.sh
# Codex does not support Claude-style PostToolUse hooks, so this runner turns
# streamed stdout/stderr activity into soldier heartbeat updates.

set -u

WORK_DIR="$1"
PROMPT_FILE="$2"
STDOUT_FILE="$3"
STDERR_FILE="$4"
SESSION_ID_FILE="$5"
RESUME_TOKEN="${6:-}"
MODEL="${7:-}"
CODEX_CMD="${8:-codex}"

HEARTBEAT_FILE=""
if [ -n "${KINGDOM_RESULT_PATH:-}" ]; then
  HEARTBEAT_FILE="${KINGDOM_RESULT_PATH%-raw.json}-heartbeat"
fi

update_codex_heartbeat() {
  [ -n "$HEARTBEAT_FILE" ] || return 0
  mkdir -p "$(dirname "$HEARTBEAT_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "codex-stream" > "$HEARTBEAT_FILE"
}

monitor_codex_stream() {
  local pid="$1"
  local last_sig=""

  while kill -0 "$pid" 2>/dev/null; do
    local out_mtime=0
    local err_mtime=0
    local out_size=0
    local err_size=0

    [ -f "$STDOUT_FILE" ] && out_mtime=$(stat -f %m "$STDOUT_FILE" 2>/dev/null || echo 0)
    [ -f "$STDERR_FILE" ] && err_mtime=$(stat -f %m "$STDERR_FILE" 2>/dev/null || echo 0)
    [ -f "$STDOUT_FILE" ] && out_size=$(wc -c < "$STDOUT_FILE" 2>/dev/null || echo 0)
    [ -f "$STDERR_FILE" ] && err_size=$(wc -c < "$STDERR_FILE" 2>/dev/null || echo 0)

    local sig="${out_mtime}:${out_size}:${err_mtime}:${err_size}"
    if [ "$sig" != "$last_sig" ]; then
      update_codex_heartbeat
      last_sig="$sig"
    fi

    sleep 1
  done
}

mkdir -p "$(dirname "$STDOUT_FILE")" "$(dirname "$STDERR_FILE")"

args=(exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox)
if [ -n "$MODEL" ]; then
  args+=(--model "$MODEL")
fi

if [ -n "$RESUME_TOKEN" ]; then
  args=(exec resume --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox)
  if [ -n "$MODEL" ]; then
    args+=(--model "$MODEL")
  fi
  args+=("$RESUME_TOKEN" -)
else
  args+=(-)
fi

(
  cd "$WORK_DIR" || exit 1
  exec "$CODEX_CMD" "${args[@]}" < "$PROMPT_FILE" > "$STDOUT_FILE" 2> "$STDERR_FILE"
) &
codex_pid=$!

monitor_codex_stream "$codex_pid" &
monitor_pid=$!

wait "$codex_pid"
codex_status=$?

wait "$monitor_pid" 2>/dev/null || true

if [ -f "$STDOUT_FILE" ]; then
  jq -r '.session_id // .data.session_id // empty' "$STDOUT_FILE" | head -1 > "$SESSION_ID_FILE" 2>/dev/null || true
fi

exit "$codex_status"

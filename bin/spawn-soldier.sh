#!/usr/bin/env bash
# bin/spawn-soldier.sh — Soldier tmux session creation
# Called by: general's spawn_soldier() function
# Role: tmux session creation + soldier-id file only
# Session registration (sessions.json) is handled by general's spawn_soldier()

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/bin/lib/common.sh"
if [ -f "$BASE_DIR/bin/lib/runtime/engine.sh" ]; then
  source "$BASE_DIR/bin/lib/runtime/engine.sh"
else
  source "$SCRIPT_DIR/lib/runtime/engine.sh"
fi

TASK_ID="$1"
PROMPT_FILE="$2"
WORK_DIR="$3"
RESUME_SESSION_ID="${4:-}"  # Optional: session_id to resume (for needs_human flow)
SOLDIER_ID="soldier-$(date +%s)-$$"
RUNTIME_ENGINE="$(get_runtime_engine)"

RAW_FILE="$BASE_DIR/state/results/${TASK_ID}-raw.json"
SESSION_ID_FILE="$BASE_DIR/state/results/${TASK_ID}-session-id"

# Pre-flight checks
RUNTIME_CMD="$(get_runtime_command "$RUNTIME_ENGINE")"
if ! command -v "$RUNTIME_CMD" &> /dev/null; then
  log "[ERROR] [soldier] runtime command not found: $RUNTIME_CMD"
  exit 1
fi

if [ -n "$RESUME_SESSION_ID" ]; then
  log "[SYSTEM] [soldier] Resuming session: $RESUME_SESSION_ID for task: $TASK_ID"
fi

ENGINE_COMMAND=$(runtime_prepare_command \
  "$RUNTIME_ENGINE" \
  "$PROMPT_FILE" \
  "$WORK_DIR" \
  "$BASE_DIR/logs/sessions/${SOLDIER_ID}.json" \
  "$BASE_DIR/logs/sessions/${SOLDIER_ID}.err" \
  "$SESSION_ID_FILE" \
  "$RESUME_SESSION_ID")

if ! tmux new-session -d -s "$SOLDIER_ID" \
  "export KINGDOM_BASE_DIR='$BASE_DIR' \
   KINGDOM_TASK_ID='$TASK_ID' \
   KINGDOM_RESULT_PATH='$RAW_FILE' && \
   $ENGINE_COMMAND; \
   tmux wait-for -S ${SOLDIER_ID}-done"; then
  log "[ERROR] [soldier] Failed to create tmux session: $SOLDIER_ID"
  exit 1
fi

# Record soldier_id
echo "$SOLDIER_ID" > "$BASE_DIR/state/results/${TASK_ID}-soldier-id"

log "[SYSTEM] [soldier] Spawned: $SOLDIER_ID for task: $TASK_ID in $WORK_DIR (engine: $RUNTIME_ENGINE)"

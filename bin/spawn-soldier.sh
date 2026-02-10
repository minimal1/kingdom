#!/usr/bin/env bash
# bin/spawn-soldier.sh — Soldier tmux session creation
# Called by: general's spawn_soldier() function
# Role: tmux session creation + soldier-id file only
# Session registration (sessions.json) is handled by general's spawn_soldier()

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

TASK_ID="$1"
PROMPT_FILE="$2"
WORK_DIR="$3"
SOLDIER_ID="soldier-$(date +%s)-$$"

# Pre-flight checks
if ! command -v claude &> /dev/null; then
  log "[ERROR] [soldier] claude command not found"
  exit 1
fi

# Session creation
if ! tmux new-session -d -s "$SOLDIER_ID" \
  "cd '$WORK_DIR' && claude -p \
    --dangerously-skip-permissions \
    < '$PROMPT_FILE' \
    > '$BASE_DIR/logs/sessions/${SOLDIER_ID}.log' 2>&1; \
   tmux wait-for -S ${SOLDIER_ID}-done"; then
  log "[ERROR] [soldier] Failed to create tmux session: $SOLDIER_ID"
  exit 1
fi

# Record soldier_id
echo "$SOLDIER_ID" > "$BASE_DIR/state/results/${TASK_ID}-soldier-id"

log "[SYSTEM] [soldier] Spawned: $SOLDIER_ID for task: $TASK_ID in $WORK_DIR"

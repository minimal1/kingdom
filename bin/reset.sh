#!/usr/bin/env bash
# Kingdom Reset — 런타임 데이터를 초기화한다.
#
# Usage:
#   bin/reset.sh              # 큐 + 상태 + 로그 초기화 (메모리/워크스페이스 보존)
#   bin/reset.sh --all        # 메모리 + 워크스페이스까지 전부 초기화
#   bin/reset.sh --dry-run    # 삭제 대상만 출력 (실제 삭제 안 함)
#
# 주의: 실행 중인 Kingdom은 먼저 stop.sh로 종료해야 한다.

set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"

# --- Options ---

ALL=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --all) ALL=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: bin/reset.sh [--all] [--dry-run]"
      echo ""
      echo "  (기본)     큐/상태/로그 초기화 (메모리·워크스페이스 보존)"
      echo "  --all      메모리·워크스페이스까지 전부 초기화"
      echo "  --dry-run  삭제 대상만 출력"
      exit 0
      ;;
  esac
done

# --- Safety Check ---

if tmux list-sessions 2>/dev/null | grep -qE '^(king|sentinel|envoy|chamberlain|gen-|soldier-)'; then
  echo "[ERROR] Kingdom 세션이 실행 중입니다. 먼저 bin/stop.sh를 실행하세요."
  exit 1
fi

# --- Helper ---

clean_dir() {
  local dir="$1"
  local label="$2"

  if [ ! -d "$dir" ]; then
    return
  fi

  local count
  count=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  if [ "$count" -eq 0 ]; then
    return
  fi

  if $DRY_RUN; then
    echo "  [DRY-RUN] $label: $count files in $dir"
  else
    find "$dir" -type f -delete 2>/dev/null || true
    echo "  [CLEAN]   $label: $count files deleted"
  fi
}

# --- Reset ---

echo "Kingdom Reset"
echo "─────────────────────────────────────"
echo "BASE_DIR: $BASE_DIR"
echo "Mode:     $(if $ALL; then echo '전체 초기화 (--all)'; else echo '런타임 초기화'; fi)$(if $DRY_RUN; then echo ' [DRY-RUN]'; fi)"
echo ""

# 1. Queues
echo "[1/5] 큐 초기화"
clean_dir "$BASE_DIR/queue/events/pending"     "events/pending"
clean_dir "$BASE_DIR/queue/events/dispatched"   "events/dispatched"
clean_dir "$BASE_DIR/queue/events/completed"    "events/completed"
clean_dir "$BASE_DIR/queue/tasks/pending"       "tasks/pending"
clean_dir "$BASE_DIR/queue/tasks/in_progress"   "tasks/in_progress"
clean_dir "$BASE_DIR/queue/tasks/completed"     "tasks/completed"
clean_dir "$BASE_DIR/queue/messages/pending"    "messages/pending"
clean_dir "$BASE_DIR/queue/messages/sent"       "messages/sent"

# 2. State
echo "[2/5] 상태 초기화"
clean_dir "$BASE_DIR/state/results"    "results"
clean_dir "$BASE_DIR/state/prompts"    "prompts"
clean_dir "$BASE_DIR/state/sentinel/seen" "sentinel/seen"

# Reset state files (preserve directory structure)
if ! $DRY_RUN; then
  # sessions.json
  if [ -f "$BASE_DIR/state/sessions.json" ]; then
    echo '[]' > "$BASE_DIR/state/sessions.json"
    echo "  [RESET]   sessions.json → []"
  fi

  # King sequences
  for f in "$BASE_DIR/state/king/task-seq" "$BASE_DIR/state/king/msg-seq"; do
    if [ -f "$f" ]; then
      echo '0' > "$f"
      echo "  [RESET]   $(basename "$f") → 0"
    fi
  done

  # Schedule sent
  if [ -f "$BASE_DIR/state/king/schedule-sent.json" ]; then
    echo '{}' > "$BASE_DIR/state/king/schedule-sent.json"
    echo "  [RESET]   schedule-sent.json → {}"
  fi

  # Sentinel state
  for f in "$BASE_DIR/state/sentinel/"*.json; do
    [ -f "$f" ] || continue
    echo '{}' > "$f"
    echo "  [RESET]   $(basename "$f") → {}"
  done

  # Envoy state
  for f in thread-mappings.json awaiting-responses.json; do
    if [ -f "$BASE_DIR/state/envoy/$f" ]; then
      echo '{}' > "$BASE_DIR/state/envoy/$f"
      echo "  [RESET]   envoy/$f → {}"
    fi
  done

  # Chamberlain daily markers
  for f in "$BASE_DIR/state/chamberlain/daily-"*; do
    [ -f "$f" ] || continue
    rm -f "$f"
    echo "  [CLEAN]   $(basename "$f")"
  done

  # Heartbeats
  for f in "$BASE_DIR/state/"*/heartbeat; do
    [ -f "$f" ] || continue
    rm -f "$f"
    echo "  [CLEAN]   $(echo "$f" | sed "s|$BASE_DIR/||")"
  done
else
  echo "  [DRY-RUN] state files would be reset"
fi

# 3. Logs
echo "[3/5] 로그 초기화"
clean_dir "$BASE_DIR/logs/sessions"  "sessions"
clean_dir "$BASE_DIR/logs/analysis"  "analysis"

if ! $DRY_RUN; then
  for f in "$BASE_DIR/logs/"*.log "$BASE_DIR/logs/"*.log.old; do
    [ -f "$f" ] || continue
    rm -f "$f"
    echo "  [CLEAN]   $(basename "$f")"
  done
else
  if [ -d "$BASE_DIR/logs" ]; then
    log_count=$(find "$BASE_DIR/logs" -maxdepth 1 -name "*.log*" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$log_count" -gt 0 ]; then
      echo "  [DRY-RUN] logs: $log_count files"
    fi
  fi
fi

# 4. Memory (--all only)
echo "[4/5] 메모리$(if ! $ALL; then echo ' (건너뜀 — --all 필요)'; fi)"
if $ALL; then
  clean_dir "$BASE_DIR/memory/shared"   "shared"
  for d in "$BASE_DIR/memory/generals/"*/; do
    [ -d "$d" ] || continue
    gen_name=$(basename "$d")
    clean_dir "$d" "generals/$gen_name"
  done
fi

# 5. Workspace (--all only)
echo "[5/5] 워크스페이스$(if ! $ALL; then echo ' (건너뜀 — --all 필요)'; fi)"
if $ALL; then
  for d in "$BASE_DIR/workspace/"*/; do
    [ -d "$d" ] || continue
    gen_name=$(basename "$d")
    if $DRY_RUN; then
      wc=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "  [DRY-RUN] workspace/$gen_name: $wc files"
    else
      rm -rf "$d"
      echo "  [CLEAN]   workspace/$gen_name/"
    fi
  done
fi

echo ""

# Re-initialize directory structure
if ! $DRY_RUN; then
  echo "init-dirs.sh 재실행으로 디렉토리 구조 복원..."
  bash "$BASE_DIR/bin/init-dirs.sh" 2>/dev/null || true
  echo ""
  echo "Reset 완료."
else
  echo "[DRY-RUN] 실제 삭제 없음. --dry-run을 제거하면 실행됩니다."
fi

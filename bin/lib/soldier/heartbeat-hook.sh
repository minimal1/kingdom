#!/usr/bin/env bash
# bin/lib/soldier/heartbeat-hook.sh — PostToolUse hook for soldier heartbeat
# 도구 호출이 완료될 때마다 타임스탬프를 기록하여 생존 신호를 남긴다.
# chamberlain이 이 파일의 mtime으로 "마지막 활동 시각"을 판단할 수 있다.
#
# 환경변수 (spawn-soldier.sh에서 export):
#   KINGDOM_TASK_ID      — 태스크 ID
#   KINGDOM_RESULT_PATH  — 결과 파일 경로 (-raw.json)
#
# Heartbeat 경로: ${KINGDOM_RESULT_PATH%-raw.json}-heartbeat
#
# stdin: Claude Code PostToolUse hook JSON
#   { "tool_name": "Bash", "tool_input": {...}, ... }

# 병사 모드가 아니면 무시
if [ -z "${KINGDOM_TASK_ID:-}" ] || [ -z "${KINGDOM_RESULT_PATH:-}" ]; then
  exit 0
fi

HEARTBEAT_PATH="${KINGDOM_RESULT_PATH%-raw.json}-heartbeat"

# stdin 소비 (hook은 stdin을 읽어야 정상 종료)
TOOL_NAME=$(cat | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

# 타임스탬프 + 도구명 기록 (덮어쓰기)
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL_NAME" > "$HEARTBEAT_PATH"

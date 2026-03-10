#!/usr/bin/env bash
# bin/lib/soldier/stop-hook.sh — Claude Code Stop hook for soldier result reporting
# 병사가 종료하려 할 때, 결과 보고 파일이 없으면 block하여
# Claude가 직접 대화 맥락을 보고 결과를 작성하게 한다.
#
# 흐름:
#   1) 병사 모드가 아니면 → allow (exit 0)
#   2) stop_hook_active=true → allow (무한루프 방지)
#   3) 결과 파일 존재 → allow
#   4) 결과 파일 없음 → block + 결과 작성 지시
#
# 환경변수 (spawn-soldier.sh에서 export):
#   KINGDOM_TASK_ID      — 태스크 ID
#   KINGDOM_RESULT_PATH  — 결과 파일 경로 (-raw.json)
#
# stdin: Claude Code Stop hook JSON
#   { "last_assistant_message": "...", "stop_hook_active": false, ... }

set -euo pipefail

# 병사 모드가 아니면 무시
if [ -z "${KINGDOM_TASK_ID:-}" ] || [ -z "${KINGDOM_RESULT_PATH:-}" ]; then
  exit 0
fi

# stdin에서 hook 입력 읽기
INPUT=$(cat)

# 무한루프 방지: block 후 재시도 시 stop_hook_active=true
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# 이미 결과 파일이 있으면 allow (프롬프트에서 직접 보고한 경우)
if [ -f "$KINGDOM_RESULT_PATH" ]; then
  exit 0
fi

# 결과 파일이 없으면 block → Claude가 직접 작성하도록 유도
jq -n \
  --arg task_id "$KINGDOM_TASK_ID" \
  --arg path "$KINGDOM_RESULT_PATH" \
  '{
    decision: "block",
    reason: ("결과 보고가 아직 작성되지 않았습니다. 종료 전에 Write 도구로 " + $path + " 에 결과 JSON을 작성해주세요.\n\n필수 형식:\n{\n  \"task_id\": \"" + $task_id + "\",\n  \"status\": \"success | failed | needs_human | skipped\",\n  \"summary\": \"작업 결과 요약 (1~2문장)\",\n  \"memory_updates\": []\n}\n\nstatus는 작업 결과에 맞게 판단하고, summary는 수행한 내용을 간결하게 요약해주세요.")
  }'

#!/usr/bin/env bash
# bin/petition-runner.sh — 상소 심의 tmux session runner
# spawn_petition()에서 tmux로 호출됨. LLM 분류 → 결과 파일 기록.

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"

EVENT_ID="$1"
MESSAGE_TEXT="$2"
RESULT_FILE="$BASE_DIR/state/king/petition-results/${EVENT_ID}.json"
GENERALS_CONFIG_DIR="$BASE_DIR/config/generals"

# 1. 장군 카탈로그 수집
catalog=""
general_names=""
for manifest in "$GENERALS_CONFIG_DIR"/*.yaml; do
  [ -f "$manifest" ] || continue
  name=$(yq eval '.name' "$manifest" 2>/dev/null)
  desc=$(yq eval '.description' "$manifest" 2>/dev/null)
  catalog="${catalog}- ${name}: ${desc}\n"
  general_names="${general_names}${name}\n"
done

if [ -z "$catalog" ]; then
  jq -n '{"general":null}' > "$RESULT_FILE"
  exit 0
fi

# 2. LLM 호출
model=$(get_config "king" "petition.model" "haiku")
petition_timeout=$(get_config "king" "petition.timeout_seconds" "15")

prompt_file=$(mktemp)
printf '사용자 메시지를 분석하여 적합한 장군을 선택하거나, 시스템 정보로 직접 답변하라.

## 장군 목록
%b

## 규칙
- 메시지 내용과 장군의 역할이 명확히 매칭될 때만 general 선택
- 시스템 메타 질문(장군 목록, 상태 등)은 direct_response로 직접 답변
- 애매하면 general: null, direct_response: null
- repo가 식별되면 포함 (org/repo 형식)

## 사용자 메시지
%s

JSON만 출력 (아래 중 하나):
{"general": "gen-xxx", "repo": "org/repo"}
{"general": null, "direct_response": "답변 텍스트"}
{"general": null}' "$catalog" "$MESSAGE_TEXT" > "$prompt_file"

# macOS 호환 타임아웃: background + wait
claude -p --model "$model" < "$prompt_file" > "${prompt_file}.out" 2>/dev/null &
pid=$!
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$petition_timeout" ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$prompt_file" "${prompt_file}.out"
  log "[WARN] [king] Petition timed out after ${petition_timeout}s for: $EVENT_ID"
  jq -n '{"general":null,"error":"timeout"}' > "$RESULT_FILE"
  exit 0
fi
wait "$pid" 2>/dev/null || true
raw_result=$(cat "${prompt_file}.out" 2>/dev/null)
rm -f "$prompt_file" "${prompt_file}.out"

if [ -z "$raw_result" ]; then
  jq -n '{"general":null}' > "$RESULT_FILE"
  exit 0
fi

# 3. JSON 추출 (LLM이 마크다운 코드블록으로 감쌀 수 있으므로)
json_result=$(echo "$raw_result" | grep -o '{[^}]*}' | head -1)
if [ -z "$json_result" ]; then
  jq -n '{"general":null}' > "$RESULT_FILE"
  exit 0
fi

# 4. 장군 이름 검증
general=$(echo "$json_result" | jq -r '.general // empty' 2>/dev/null || true)
if [ -n "$general" ]; then
  if ! echo -e "$general_names" | grep -q "^${general}$"; then
    log "[WARN] [king] Petition returned unknown general: $general for: $EVENT_ID"
    jq -n '{"general":null}' > "$RESULT_FILE"
    exit 0
  fi
fi

# 5. 결과 기록 (atomic write)
echo "$json_result" > "${RESULT_FILE}.tmp"
mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
log "[SYSTEM] [king] Petition reviewed for: $EVENT_ID"

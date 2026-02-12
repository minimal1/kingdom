# 사절 (Envoy)

> 궁궐과 외부 세계(사람) 사이의 소통을 담당한다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `envoy` |
| tmux 세션 | `envoy` |
| 실행 형태 | Bash 스크립트 (단일 polling loop) |
| 수명 | 상주 (Always-on) |
| 리소스 | 경량 (대부분 sleep 상태) |
| 소통 채널 | Slack Web API (curl) |

## 책임

- **Slack 소통 독점** — 시스템에서 Slack에 접근하는 유일한 역할
- **아웃바운드 (주 역할)**: 시스템 내부 이벤트를 사람이 이해할 수 있는 형태로 Slack에 전달
- 작업별 스레드 생명주기 관리 (생성 → 업데이트 → 종료)
- `needs_human` 작업의 스레드 응답 감지 및 이벤트 생성 (드문 경우)
- 정기 리포트 발송

## 하지 않는 것

- 작업 판단이나 실행 (왕/장군의 책임)
- GitHub/Jira 이벤트 감지 (파수꾼의 책임)
- **Slack 채널에서 새 작업 명령 수신** — 작업은 GitHub/Jira 이벤트로만 유입 (파수꾼 경유)
- 메시지 내용에 기반한 작업 수행

---

## Slack 채널 + 스레드 모델

### 개념

```
#kingdom 채널
│
├─ 📌 "[start] PR #1234 리뷰 — querypie/frontend"       ← 채널 메시지 (스레드 부모)
│   └─ 🧵 스레드:
│       ├─ 🤖 "PR 분석 중... 변경 파일 12개"
│       ├─ 🤖 "[question] 보안 이슈 2건 발견. 리뷰에 포함할까요?"
│       ├─ 👤 "포함해줘"
│       ├─ 🤖 "리뷰 코멘트 5개 작성 완료"
│       └─ 🤖 "[complete] PR #1234 리뷰 완료 ✓"
│
├─ 📌 "[start] Jira QP-567 구현"                        ← 또 다른 작업 스레드
│   └─ 🧵 ...
│
└─ 📊 "[일일 리포트] 2026-02-07 — 처리 3건, 실패 0건"    ← 리포트 (스레드 없이)
```

### 핵심 원칙

- **작업 1개 = 스레드 1개**: `task_id ↔ thread_ts` 1:1 매핑
- **채널 레벨**: 작업 시작/종료 알림, 리포트
- **스레드 레벨**: 진행 상황, 질문/응답, 상세 결과
- **스레드 종료**: 작업 완료 후 모니터링 중단 (Slack에 데이터는 남음)

---

## Slack API 접근

| 항목 | 값 |
|------|-----|
| 도구 | `curl` + Slack Web API |
| 인증 | `SLACK_BOT_TOKEN` (xoxb-) 환경변수 |
| Rate Limit | Tier 3: 50+ req/min (내부 앱 기준, 2026.03 제한 변경 대상 아님) |

### 주요 API 엔드포인트

| 용도 | 엔드포인트 | 비고 |
|------|-----------|------|
| 메시지 전송 | `POST chat.postMessage` | `thread_ts` 지정 시 스레드 답글 |
| 스레드 답글 읽기 | `GET conversations.replies` | `ts` (스레드 부모)로 특정 스레드, needs_human 응답 감지용 |

### 공통 함수 (`slack-api.sh`)

```bash
SLACK_API="https://slack.com/api"

# Slack API 호출 공통 (응답 검증 포함)
slack_api() {
  local method="$1"   # e.g., "chat.postMessage"
  local data="$2"     # JSON body

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "$SLACK_API/$method" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$data")

  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | sed '$d')

  # HTTP 에러 처리
  if [ "$http_code" = "429" ]; then
    local retry_after=$(echo "$body" | jq -r '.retry_after // 30')
    log "[WARN] [envoy] Rate limited. Retry after ${retry_after}s"
    sleep "$retry_after"
    return 1
  elif [ "$http_code" != "200" ]; then
    log "[ERROR] [envoy] Slack API $method failed: HTTP $http_code"
    return 1
  fi

  # Slack API 레벨 에러 (ok: false)
  local ok=$(echo "$body" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    local error=$(echo "$body" | jq -r '.error')
    log "[ERROR] [envoy] Slack API $method error: $error"
    return 1
  fi

  echo "$body"
}

# 채널에 메시지 전송 (스레드 부모 생성)
send_message() {
  local channel="$1"
  local text="$2"
  slack_api "chat.postMessage" \
    "$(jq -n --arg c "$channel" --arg t "$text" '{channel: $c, text: $t}')"
}

# 스레드에 답글 전송
send_thread_reply() {
  local channel="$1"
  local thread_ts="$2"
  local text="$3"
  slack_api "chat.postMessage" \
    "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg t "$text" \
      '{channel: $c, thread_ts: $ts, text: $t}')"
}

# 스레드의 새 답글 읽기 (needs_human 응답 감지용)
read_thread_replies() {
  local channel="$1"
  local thread_ts="$2"
  local oldest="$3"
  slack_api "conversations.replies" \
    "$(jq -n --arg c "$channel" --arg ts "$thread_ts" --arg o "$oldest" \
      '{channel: $c, ts: $ts, oldest: $o, limit: 20}')"
}
```

---

## 아웃바운드: 시스템 → Slack

### 흐름

```
왕/장군/내관
     │
     │ queue/messages/pending/ 에 메시지 파일 생성
     ▼
┌──────────────────┐
│ 사절 루프         │
│ 메시지 큐 감지    │ (5초 간격)
└──────┬───────────┘
       ▼
┌──────────────────┐
│ 메시지 타입 분기  │
├─ notification    │──→ 채널 메시지 또는 스레드 답글
├─ thread_start    │──→ 채널 메시지 생성 → thread_ts 기록
├─ thread_update   │──→ 기존 스레드에 답글
├─ human_input_req │──→ 스레드에 질문 게시 + awaiting 등록
├─ report          │──→ 채널 메시지 (스레드 없이)
└──────────────────┘
       ▼
  메시지를 sent/로 이동
```

### 메시지 타입별 처리

#### `thread_start` — 작업 시작 시 스레드 생성

왕이 작업을 배정할 때 생성하는 메시지.

```json
{
  "id": "msg-20260207-001",
  "type": "thread_start",
  "task_id": "task-20260207-001",
  "channel": "dev-eddy",
  "content": "[start] PR #1234 리뷰 — querypie/frontend",
  "created_at": "2026-02-07T10:00:00Z",
  "status": "pending"
}
```

사절은 이 메시지를 전송한 후, 반환된 `ts`를 스레드 매핑에 저장:

```bash
# send_message 후 thread_ts 추출 (에러 시 다음 주기에 재시도)
response=$(send_message "$channel" "$content") || return 1
thread_ts=$(echo "$response" | jq -r '.ts')

# 매핑 저장
save_thread_mapping "$task_id" "$thread_ts" "$channel"
```

#### `thread_update` — 스레드에 진행 상황 업데이트

```json
{
  "id": "msg-20260207-002",
  "type": "thread_update",
  "task_id": "task-20260207-001",
  "content": "PR 분석 중... 변경 파일 12개",
  "created_at": "2026-02-07T10:01:00Z",
  "status": "pending"
}
```

사절은 `task_id`로 `thread_ts`를 조회하여 스레드에 답글.

#### `human_input_request` — needs_human 질문 게시

```json
{
  "id": "msg-20260207-003",
  "type": "human_input_request",
  "task_id": "task-20260207-001",
  "content": "[question] 보안 이슈 2건 발견. 리뷰에 포함할까요?",
  "context": {
    "checkpoint_path": "state/results/task-20260207-001-checkpoint.json"
  },
  "created_at": "2026-02-07T10:03:00Z",
  "status": "pending"
}
```

사절은 스레드에 질문을 게시하고, 해당 스레드를 **awaiting_response** 목록에 등록:

```bash
process_human_input_request() {
  local msg="$1"
  local task_id=$(echo "$msg" | jq -r '.task_id')
  local content=$(echo "$msg" | jq -r '.content')
  local mapping=$(get_thread_mapping "$task_id")
  local thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
  local channel=$(echo "$mapping" | jq -r '.channel')

  # 스레드에 질문 게시
  send_thread_reply "$channel" "$thread_ts" "$content"

  # awaiting_response 목록에 등록
  add_awaiting_response "$task_id" "$thread_ts" "$channel"

  log "[EVENT] [envoy] Human input requested for task: $task_id"
}
```

#### `notification` — 일반 알림

```json
{
  "id": "msg-20260207-004",
  "type": "notification",
  "task_id": "task-20260207-001",
  "channel": "dev-eddy",
  "urgency": "normal",
  "content": "[complete] PR #1234 리뷰 완료 — 5개 코멘트 작성",
  "context": {
    "result_url": "https://github.com/querypie/frontend/pull/1234"
  },
  "created_at": "2026-02-07T10:05:00Z",
  "status": "pending"
}
```

`task_id`가 있고 해당 스레드가 존재하면 스레드에 답글, 없으면 채널 메시지.

**urgency 처리 정책**: 현재는 모든 urgency를 동일하게 처리한다 (즉시 전송). 향후 `urgent` 시 `<!here>` 멘션을 포함하는 확장을 고려할 수 있으나, 1차 구현에서는 미분기.

작업 완료/실패 알림인 경우 스레드 매핑을 정리한다:

```bash
process_notification() {
  local msg="$1"
  local task_id=$(echo "$msg" | jq -r '.task_id // empty')
  local content=$(echo "$msg" | jq -r '.content')

  if [ -n "$task_id" ]; then
    local mapping=$(get_thread_mapping "$task_id")
    if [ -n "$mapping" ]; then
      local thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
      local channel=$(echo "$mapping" | jq -r '.channel')
      send_thread_reply "$channel" "$thread_ts" "$content"

      # 완료/실패 시 스레드 매핑 정리
      if echo "$content" | grep -qE '^\[(complete|failed)\]'; then
        remove_thread_mapping "$task_id"
        remove_awaiting_response "$task_id"  # 혹시 남아있으면 함께 정리
        log "[EVENT] [envoy] Thread closed for task: $task_id"
      fi
    else
      # 매핑 없으면 채널 메시지로 fallback
      local channel=$(echo "$msg" | jq -r '.channel // "'"$(get_config "envoy" "slack.default_channel_id")"'"')
      send_message "$channel" "$content"
      log "[WARN] [envoy] No thread mapping for task: $task_id, sent to channel"
    fi
  else
    local channel=$(echo "$msg" | jq -r '.channel')
    send_message "$channel" "$content"
  fi
}
```

---

## 인바운드: Slack → 시스템

### 설계 결정: 채널 명령 수신 없음

작업은 **GitHub/Jira 이벤트로만 유입**된다 (파수꾼 경유). Slack 채널에서 "리뷰해줘" 같은 명령을 받아 처리하는 경로는 두지 않는다.

이유:
- GitHub에서 review request 하는 것이 Slack에 타이핑하는 것보다 자연스러움
- LLM 분류 의존성 (API 비용, 오분류 위험)이 제거됨
- 사절의 역할이 단순해짐 — 거의 순수 아웃바운드

따라서 인바운드는 **needs_human 스레드 응답 감지**만 존재한다.

### 스레드 응답 → needs_human 처리

```
사람 (Slack 스레드)
     │
     │ "포함해줘" (needs_human 질문에 대한 답변)
     ▼
┌──────────────────────────┐
│ 사절 루프                 │
│ awaiting_response 스레드  │ (30초 간격)
│ 새 답글 감지              │
└──────┬───────────────────┘
       ▼
┌──────────────────┐
│ 이벤트 생성      │──→ queue/events/pending/
│                  │    type: "slack.human_response"
└──────────────────┘
       ▼
  왕이 소비 → 체크포인트 + 응답으로 작업 재배정
```

```bash
check_awaiting_responses() {
  local awaiting_file="state/envoy/awaiting-responses.json"
  [ -f "$awaiting_file" ] || return 0

  # 각 awaiting 스레드를 확인
  jq -c '.[]' "$awaiting_file" | while read -r entry; do
    local task_id=$(echo "$entry" | jq -r '.task_id')
    local thread_ts=$(echo "$entry" | jq -r '.thread_ts')
    local channel=$(echo "$entry" | jq -r '.channel')
    local asked_at=$(echo "$entry" | jq -r '.asked_at')

    # 스레드의 새 답글 읽기 (질문 이후)
    local replies=$(read_thread_replies "$channel" "$thread_ts" "$asked_at")

    # 봇이 아닌 사람의 답글 필터링
    # 의도: 첫 번째 응답만 취한다. 사람이 여러 메시지로 답변한 경우 첫 메시지만 전달.
    # 이유: 체크포인트 재개 시 단일 응답이 명확. 복잡한 지시는 스레드에 한 메시지로 작성 유도.
    local human_reply=$(echo "$replies" | jq -r '
      .messages[]? | select(.bot_id == null and .ts != "'"$thread_ts"'") | .text' | head -1)

    if [ -n "$human_reply" ]; then
      # 이벤트 생성
      # ID 패턴: evt-slack-response-{task_id}-{unix_timestamp}
      # (message-passing.md의 evt-slack-{channel}-{message_ts}와 다름 — 응답 이벤트는 task 기반)
      local event_id="evt-slack-response-${task_id}-$(date +%s)"
      local event=$(jq -n \
        --arg id "$event_id" \
        --arg task_id "$task_id" \
        --arg response "$human_reply" \
        '{
          id: $id,
          type: "slack.human_response",
          source: "slack",
          repo: null,
          payload: {
            task_id: $task_id,
            human_response: $response
          },
          priority: "high",
          created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
          status: "pending"
        }')

      emit_event "$event"
      remove_awaiting_response "$task_id"

      log "[EVENT] [envoy] Human responded for task: $task_id"
    else
      # 24시간 무응답 → 리마인더 발송
      local asked_epoch=$(date -d "$asked_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$asked_at" +%s)
      local now_epoch=$(date +%s)
      local hours_elapsed=$(( (now_epoch - asked_epoch) / 3600 ))

      if (( hours_elapsed >= 24 )); then
        # 매 24시간마다 리마인더 (asked_at 기준이므로 반복 방지는 별도 필요 없음 — 응답이 오면 제거됨)
        if (( hours_elapsed % 24 == 0 )) || (( hours_elapsed == 24 )); then
          send_thread_reply "$channel" "$thread_ts" \
            "[리마인더] 응답 대기 중입니다 (${hours_elapsed}시간 경과). 위 질문에 답변해 주세요."
          log "[WARN] [envoy] Reminder sent for task: $task_id (${hours_elapsed}h)"
        fi
      fi
    fi
  done
}
```

---

## 스레드 생명주기

```
작업 생성 (왕)
     │
     │ msg type: "thread_start"
     ▼
사절: 채널 메시지 전송 → thread_ts 획득
     │ thread_mappings에 저장
     │
     ├─ msg type: "thread_update" (진행 상황) ──→ 스레드 답글
     │
     ├─ msg type: "human_input_request" ──→ 스레드 답글 + awaiting 등록
     │   └─ 사람 응답 감지 ──→ slack.human_response 이벤트 생성
     │
     ├─ msg type: "notification" (완료/실패) ──→ 스레드 답글
     │
     └─ 작업 완료
         │ thread_mappings에서 제거
         │ awaiting에서도 제거 (있으면)
         ▼
       스레드 모니터링 종료
```

### 상태 파일

```
state/envoy/
├── heartbeat                    # 생존 확인
├── thread-mappings.json         # { "task-001": { "thread_ts": "...", "channel": "..." } }
└── awaiting-responses.json      # [ { "task_id": "...", "thread_ts": "...", "asked_at": "..." } ]
```

### 스레드 관리 함수 (`thread-manager.sh`)

```bash
MAPPINGS_FILE="$BASE_DIR/state/envoy/thread-mappings.json"
AWAITING_FILE="$BASE_DIR/state/envoy/awaiting-responses.json"

# ── 스레드 매핑 ────────────────────────────────────

save_thread_mapping() {
  local task_id="$1" thread_ts="$2" channel="$3"
  local tmp=$(jq --arg tid "$task_id" --arg ts "$thread_ts" --arg ch "$channel" \
    '.[$tid] = {thread_ts: $ts, channel: $ch}' "$MAPPINGS_FILE")
  echo "$tmp" > "$MAPPINGS_FILE"
}

get_thread_mapping() {
  local task_id="$1"
  jq -r --arg tid "$task_id" '.[$tid] // empty' "$MAPPINGS_FILE"
}

remove_thread_mapping() {
  local task_id="$1"
  local tmp=$(jq --arg tid "$task_id" 'del(.[$tid])' "$MAPPINGS_FILE")
  echo "$tmp" > "$MAPPINGS_FILE"
}

# ── awaiting 관리 ──────────────────────────────────

add_awaiting_response() {
  local task_id="$1" thread_ts="$2" channel="$3"
  local tmp=$(jq --arg tid "$task_id" --arg ts "$thread_ts" --arg ch "$channel" \
    '. + [{task_id: $tid, thread_ts: $ts, channel: $ch, asked_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    "$AWAITING_FILE")
  echo "$tmp" > "$AWAITING_FILE"
}

remove_awaiting_response() {
  local task_id="$1"
  local tmp=$(jq --arg tid "$task_id" '[.[] | select(.task_id != $tid)]' "$AWAITING_FILE")
  echo "$tmp" > "$AWAITING_FILE"
}

```

---

## 공통 함수 참조 (`common.sh`)

사절이 사용하는 공통 함수는 `bin/lib/common.sh`에 정의된다. 모든 역할이 공유하는 인프라 함수.

| 함수 | 용도 | 비고 |
|------|------|------|
| `log()` | 구조화 로그 출력 | `[카테고리] [역할] 메시지` 형식 |
| `get_config()` | YAML 설정 읽기 | `get_config "envoy" "schedule.daily_report"` — 첫 인자가 역할명 |
| `update_heartbeat()` | heartbeat 파일 갱신 | `update_heartbeat "envoy"` → `state/envoy/heartbeat` touch |
| `start_heartbeat_daemon()` | heartbeat 백그라운드 갱신 시작 | `start_heartbeat_daemon "envoy"` — blocking 내성 확보 |
| `stop_heartbeat_daemon()` | heartbeat 백그라운드 프로세스 종료 | trap에서 호출 |
| `emit_event()` | 이벤트 큐에 적재 | Write-then-Rename, **seen/ 인덱스 마킹 없음** (파수꾼만 seen/ 사용) |

> 센티널의 `watcher-common.sh`에 있던 `emit_event()`는 `common.sh`의 기본 emit에 **seen/ 인덱스 마킹을 추가한 래퍼**이다. 사절은 기본 emit만 사용한다 — human_response 이벤트는 task_id + timestamp 조합으로 자연적 유일성이 보장되므로 별도 중복 방지 불필요.

---

## 사절 메인 루프

```bash
#!/bin/bash
# bin/envoy.sh — 사절 메인 루프 (단일 루프)

BASE_DIR="/opt/kingdom"
source "$BASE_DIR/bin/lib/common.sh"              # 공통 함수 (emit_event, get_config, update_heartbeat, log)
source "$BASE_DIR/bin/lib/envoy/slack-api.sh"      # Slack API 호출
source "$BASE_DIR/bin/lib/envoy/thread-manager.sh"  # 스레드 매핑, awaiting 관리

# ── Graceful Shutdown ────────────────────────────
RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [envoy] Shutting down..."; exit 0' SIGTERM SIGINT

# ── 타이머 ───────────────────────────────────────
LAST_OUTBOUND=0      # 아웃바운드: 메시지 큐 소비
LAST_THREAD_CHECK=0  # 스레드: awaiting 응답 확인

OUTBOUND_INTERVAL=5       # 5초  — 내부 메시지는 빠르게 전달
THREAD_CHECK_INTERVAL=30  # 30초 — awaiting 스레드 확인 (needs_human 시에만 활성)

log "[SYSTEM] [envoy] Started."

start_heartbeat_daemon "envoy"

while $RUNNING; do
  now=$(date +%s)

  # ── 1. 아웃바운드: 메시지 큐 소비 (5초) ────────
  if (( now - LAST_OUTBOUND >= OUTBOUND_INTERVAL )); then
    process_outbound_queue
    LAST_OUTBOUND=$now
  fi

  # ── 2. 스레드 응답 확인 (30초, awaiting이 있을 때만) ───
  if (( now - LAST_THREAD_CHECK >= THREAD_CHECK_INTERVAL )); then
    check_awaiting_responses
    LAST_THREAD_CHECK=$now
  fi

  sleep 5  # 메인 루프 틱
done
```

### 아웃바운드 큐 처리

```bash
process_outbound_queue() {
  local pending_dir="$BASE_DIR/queue/messages/pending"
  local sent_dir="$BASE_DIR/queue/messages/sent"

  for msg_file in "$pending_dir"/*.json; do
    [ -f "$msg_file" ] || continue

    local msg=$(cat "$msg_file")
    local msg_type=$(echo "$msg" | jq -r '.type')
    local task_id=$(echo "$msg" | jq -r '.task_id // empty')

    case "$msg_type" in
      thread_start)
        process_thread_start "$msg"
        ;;
      thread_update)
        process_thread_update "$msg"
        ;;
      human_input_request)
        process_human_input_request "$msg"
        ;;
      notification)
        process_notification "$msg"
        ;;
      report)
        process_report "$msg"
        ;;
      *)
        log "[EVENT] [envoy] Unknown message type: $msg_type"
        ;;
    esac

    # sent로 이동
    mv "$msg_file" "$sent_dir/"
  done
}
```

---

## 이벤트 타입 정의

> 전체 이벤트 타입 카탈로그: [systems/event-types.md](../systems/event-types.md)

### 인바운드 (Slack → 시스템)

| Type | 발생 조건 | Priority |
|------|----------|----------|
| `slack.human_response` | needs_human 스레드에 사람이 답변 | high |

> 채널 메시지를 통한 작업 명령 수신은 지원하지 않는다. 작업은 GitHub/Jira 이벤트로만 유입.

### 아웃바운드 메시지 타입 (시스템 → Slack)

| Type | 생성자 | Slack 동작 |
|------|--------|-----------|
| `thread_start` | 왕 | 채널 메시지 생성 (스레드 부모) |
| `thread_update` | 장군/병사 경유 | 스레드 답글 |
| `human_input_request` | 왕 (needs_human 감지 시) | 스레드 답글 + awaiting 등록 |
| `notification` | 왕/장군/내관 | 스레드 답글 또는 채널 메시지 |
| `report` | 내관 (generate_daily_report) | 채널 메시지 |

---

## needs_human 전체 흐름

```
1. 병사: 작업 중 판단 필요 → result에 needs_human + checkpoint 저장 → 종료

2. 장군/왕: needs_human 결과 감지
   → 사절에게 human_input_request 메시지 생성
   {
     type: "human_input_request",
     task_id: "task-001",
     content: "[question] 보안 이슈 2건, 리뷰에 포함할까요?",
     context: { checkpoint_path: "state/results/task-001-checkpoint.json" }
   }

3. 사절: 스레드에 질문 게시 + awaiting_responses에 등록

4. 사람: 스레드에서 "포함해줘" 답변

5. 사절: 스레드 폴링에서 답변 감지
   → queue/events/pending/ 에 이벤트 생성
   {
     type: "slack.human_response",
     payload: { task_id: "task-001", human_response: "포함해줘" }
   }

6. 왕: 이벤트 소비 → 체크포인트 + 사람 응답 포함하여 작업 재배정

7. 새 병사: 체크포인트에서 재개
   프롬프트: "이전 체크포인트를 이어서 진행. 사람 응답: '포함해줘'"
```

---

## 리포트

### 리포트 발송 (레이어드)

리포트 데이터 수집 및 메시지 생성은 **내관**이 담당한다 (chamberlain.md의 `generate_daily_report`). 사절은 큐에 도착한 `report` 타입 메시지를 Slack으로 발송하는 역할만 수행한다.

```
내관 (09:00) → generate_daily_report → queue/messages/pending/ (type: "report")
                                              ↓
사절 (5초 폴링) → process_report → Slack 채널에 발송
```

#### 리포트 메시지 예시

```
📊 [일일 리포트] 2026-02-07

처리: 5건 (PR 리뷰 3, Jira 1, 테스트 1)
실패: 1건 (Jira QP-890 — API timeout)
사람 대기: 0건

소요 시간 (평균): PR 리뷰 12분, Jira 작업 45분
```

---

## 설정

```yaml
# config/envoy.yaml
slack:
  bot_token_env: "SLACK_BOT_TOKEN"      # 환경변수 이름
  default_channel: "dev-eddy"            # 채널 이름
  default_channel_id: "C0XXXXXXXX"       # 채널 ID (API 호출용)

intervals:
  outbound_seconds: 5         # 메시지 큐 소비
  thread_check_seconds: 30    # awaiting 스레드 확인
```

## 장애 대응

| 상황 | 행동 |
|------|------|
| Slack API 실패 (401/403) | 로그 기록, SLACK_BOT_TOKEN 만료 가능 → 사람에게 알림 불가하므로 내관이 감지 |
| Slack API 실패 (429 Rate Limit) | 로그 기록, Retry-After 헤더 확인 후 대기 |
| Slack API 실패 (5xx) | 로그 기록, 다음 주기에 재시도 |
| 사절 프로세스 죽음 | 내관이 `state/envoy/heartbeat` mtime 확인 → tmux 재시작 |
| 사절 프로세스 hang | heartbeat 갱신 안됨 → 내관이 SIGTERM → 재시작 |
| SIGTERM/SIGINT 수신 | 현재 루프 완료 후 graceful shutdown |
| thread_ts 조회 실패 (매핑 없음) | 채널 메시지로 fallback, 로그 경고 |
| awaiting 스레드에 응답 없음 (장기) | 24시간 후 스레드에 리마인더 자동 발송 |

## 인증 정보

### Slack Bot Token

| 항목 | 값 |
|------|-----|
| 환경변수 | `SLACK_BOT_TOKEN` |
| 토큰 형식 | Bot User OAuth Token (`xoxb-...`) |
| 발급 | https://api.slack.com/apps → OAuth & Permissions → Install to Workspace |

### 필요 Bot Token Scopes

| 스코프 | 용도 | 사용 API |
|--------|------|----------|
| `chat:write` | 채널/스레드에 메시지 전송 | `chat.postMessage` |
| `channels:history` | 공개 채널의 스레드 답글 읽기 (needs_human 응답 감지) | `conversations.replies` |
| `channels:read` | 채널 ID 조회 | `conversations.list` (초기 설정 시) |

> `channels:history`는 채널 메시지 전체를 읽을 수 있는 권한이지만, 사절은 awaiting 스레드의 답글만 읽는다.

#### 비공개 채널을 사용하는 경우

비공개 채널(`#kingdom`가 private인 경우) 추가 스코프:

| 스코프 | 용도 |
|--------|------|
| `groups:history` | 비공개 채널의 스레드 답글 읽기 |
| `groups:read` | 비공개 채널 ID 조회 |

#### 불필요한 스코프 (사용하지 않음)

| 스코프 | 이유 |
|--------|------|
| `channels:manage` | 채널 생성/관리 안 함 |
| `users:read` | 사용자 정보 조회 불필요 |
| `files:write` | 파일 업로드 안 함 |
| `reactions:write` | 이모지 리액션 안 함 |

## 스크립트 위치

```
bin/
├── envoy.sh                             # 메인 polling loop
└── lib/envoy/
    ├── slack-api.sh                     # Slack API 공통 함수 (send, read)
    └── thread-manager.sh                # 스레드 매핑, awaiting 관리
```

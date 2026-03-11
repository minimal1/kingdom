# 사절 (Envoy)

> 궁궐과 외부 세계(사람) 사이의 소통을 담당한다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `envoy` |
| tmux 세션 | `envoy` |
| 실행 형태 | Bash 스크립트 + Node.js bridge (Socket Mode) |
| 수명 | 상주 (Always-on) |
| 리소스 | 경량 (대부분 sleep 상태) |
| 소통 채널 | Slack Socket Mode (WebSocket) + Web API |

## 책임

- **Slack 소통 독점** — 시스템에서 Slack에 접근하는 유일한 역할
- **아웃바운드**: 시스템 내부 이벤트를 사람이 이해할 수 있는 형태로 Slack에 전달
- **인바운드**: DM 새 메시지 감지, needs_human 응답 감지, 대화 스레드 후속 응답 감지
- 작업별 스레드 생명주기 관리 (생성 → 업데이트 → 종료)
- reply_context 추적: 왕이 포함한 메타데이터를 저장하고 이벤트에 그대로 반환
- 정기 리포트 발송

## 하지 않는 것

- 작업 판단이나 실행 (왕/장군의 책임)
- GitHub/Jira 이벤트 감지 (파수꾼의 책임)
- 메시지 내용 해석 또는 작업 판단 (사절은 메시지 파이프라인)
- reply_context 해석 — 그대로 전달만 할 뿐 의미를 모름

---

## Slack DM/채널 하이브리드 모델

### 개념

환경변수 `SLACK_DEFAULT_CHANNEL`(또는 config fallback `default_channel`)에 User ID (`UXXXXXXXX`)를 설정하면 DM으로 동작하고, 채널 이름을 설정하면 채널에 게시한다. Slack API의 `chat.postMessage`는 channel 파라미터에 User ID를 넣으면 자동으로 DM을 생성하므로, 별도 분기 없이 동일한 코드로 동작한다. 채널 설정은 `.env` 파일의 `SLACK_DEFAULT_CHANNEL`로 통합 관리하며, king과 envoy가 동일한 값을 공유한다.

DM으로 메시지를 보내면 Slack API 응답의 `channel` 필드에 `D`-prefixed 채널 ID (예: `D08XXXXXXXX`)가 반환된다. 사절은 이 **응답의 actual channel ID**를 `thread-mappings.json`에 저장하여, 이후 스레드 답글이 올바른 DM 대화에 전달되도록 한다.

```
DM 대화 (또는 채널)
│
├─ 📌 "📋 gen-pr | task-20260212-001                     ← 메시지 (스레드 부모)
│       github.pr.review_requested | querypie/frontend"
│   └─ 🧵 스레드:
│       ├─ 🤖 "PR 분석 중... 변경 파일 12개"
│       ├─ 🤖 "[question] 보안 이슈 2건 발견. 리뷰에 포함할까요?"
│       ├─ 👤 "포함해줘"
│       ├─ 🤖 "리뷰 코멘트 5개 작성 완료"
│       └─ 🤖 "✅ gen-pr | task-20260212-001
│              PR 리뷰 완료 — 5개 코멘트 작성"
│
├─ 📌 "📋 gen-briefing | task-20260212-002                   ← 또 다른 작업 스레드
│       briefing.summary_requested | querypie/backend"
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

### Socket Mode 아키텍처

```
┌─── Envoy 영역 ──────────────────────────────────────┐
│                                                       │
│  [bridge.js]  ←WebSocket─  Slack (Socket Mode)       │
│       │                                               │
│       └──JSON write──→  state/envoy/socket-inbox/    │
│                              │                        │
│  [envoy.sh]                  │                        │
│    ├─ check_socket_inbox()  ←┘  (sleep_or_wake 감지) │
│    ├─ expire_conversations()    (주기적 TTL 정리)     │
│    ├─ check_bridge_health()     (브릿지 생존 확인)    │
│    └─ process_outbound_queue()  (outbox 기반 발송)    │
│                                                       │
└───────────────────────────────────────────────────────┘
```

Socket Mode가 활성화되면 (`config/envoy.yaml`의 `socket_mode.enabled: true`):
- **인바운드**: bridge.js가 WebSocket으로 실시간 수신 → `socket-inbox/` 파일 생성 → envoy.sh가 소비
- **아웃바운드**: envoy.sh가 `outbox/` 파일 생성 → bridge.js가 Web API 호출 → `outbox-results/` 기록
- 레거시 폴링 함수 (`check_channel_messages`, `check_awaiting_responses`, `check_conversation_threads`)는 비활성화

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
├─ thread_reply    │──→ 스레드 답글 + 대화 추적 등록
├─ human_input_req │──→ 스레드에 질문 게시 + awaiting 등록
├─ report          │──→ 채널 메시지 (스레드 없이)
└──────────────────┘
       ▼
  성공 → sent/로 이동
  실패 → 재시도 (max 3회) → 초과 시 failed/로 격리
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
  "content": "📋 gen-pr | task-20260207-001\ngithub.pr.review_requested | querypie/frontend",
  "created_at": "2026-02-07T10:00:00Z",
  "status": "pending"
}
```

사절은 이 메시지를 처리할 때 두 가지 경로로 분기한다:

**일반 경로** (GitHub/Jira 이벤트 — `thread_ts` 없음): 새 채널 메시지를 생성하고 반환된 `ts`를 스레드 매핑에 저장.

**DM 경로** (`thread_ts` 있음): DM 원본 메시지가 이미 스레드 부모이므로 새 메시지를 생성하지 않고, 스레드 답글로 상태 알림을 보낸 뒤 기존 `thread_ts`로 매핑만 저장.

```bash
existing_ts=$(echo "$msg" | jq -r '.thread_ts // empty')

if [[ -n "$existing_ts" ]]; then
  # DM 경로: 기존 메시지를 스레드 부모로 재사용
  thread_ts="$existing_ts"
  actual_channel="$channel"
  send_thread_reply "$channel" "$thread_ts" "$content"
else
  # 일반 경로: 새 채널 메시지 생성
  response=$(send_message "$channel" "$content") || return 1
  thread_ts=$(echo "$response" | jq -r '.ts')
  actual_channel=$(echo "$response" | jq -r '.channel // "'"$channel"'"')
fi

save_thread_mapping "$task_id" "$thread_ts" "$actual_channel"
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
  "reply_context": {
    "general": "gen-pr",
    "session_id": "sess-abc",
    "repo": "chequer-io/querypie-frontend"
  },
  "channel": "D999",
  "thread_ts": "1707300000.000200",
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
  local reply_ctx=$(echo "$msg" | jq -c '.reply_context // {}')
  local mapping=$(get_thread_mapping "$task_id")

  if [[ -n "$mapping" ]]; then
    local thread_ts=$(echo "$mapping" | jq -r '.thread_ts')
    local channel=$(echo "$mapping" | jq -r '.channel')
    send_thread_reply "$channel" "$thread_ts" "$content"
    add_awaiting_response "$task_id" "$thread_ts" "$channel" "$reply_ctx"
    log "[EVENT] [envoy] Human input requested for task: $task_id"
  else
    # DM 원본: 메시지에 channel/thread_ts가 직접 포함된 경우 (thread_mapping 없이)
    local msg_ch=$(echo "$msg" | jq -r '.channel // empty')
    local msg_ts=$(echo "$msg" | jq -r '.thread_ts // empty')
    if [[ -n "$msg_ch" && -n "$msg_ts" ]]; then
      send_thread_reply "$msg_ch" "$msg_ts" "$content"
      add_awaiting_response "$task_id" "$msg_ts" "$msg_ch" "$reply_ctx"
      log "[EVENT] [envoy] Human input requested for task: $task_id (DM fallback)"
    else
      log "[WARN] [envoy] No thread mapping for task: $task_id (human_input_request)"
    fi
  fi
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
  "content": "✅ gen-pr | task-20260207-001\nPR #1234 리뷰 완료 — 5개 코멘트 작성",
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

      # 완료/실패/스킵 시 스레드 매핑 정리 (✅/❌/⏭️ 접두사로 판별)
      if echo "$content" | grep -qE '^(✅|❌|⏭️)'; then
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

## 이모지 리액션 관리

DM 수신 시 사용자에게 접수 여부를 즉시 피드백하고, 작업 완료 시 최종 상태를 리액션으로 표시한다.

### 리액션 라이프사이클

```
User DM 수신          → 👀 eyes (즉시, fire-and-forget)
Task 완료 (성공)      → 👀 제거 + ✅ white_check_mark
Task 완료 (실패)      → 👀 제거 + ❌ x
Task 완료 (건너뜀)    → 👀 제거
needs_human           → 👀 제거 + 🙋 raising_hand
Direct response       → 👀 제거 + ✅ white_check_mark
```

### 채널 스레드 부모 메시지 리액션

채널 스레드의 부모 메시지(thread_start)에도 상태 리액션을 추가하여, 채널에서 한눈에 작업 진행/완료 상태를 파악할 수 있다.

```
thread_start 발송       → 👀 eyes (즉시, fire-and-forget)
notification ✅ (성공)   → 👀 제거 + ✅ white_check_mark
notification ❌ (실패)   → 👀 제거 + ❌ x
notification ⏭️ (건너뜀) → 👀 제거 (제거만)
```

DM 원본 리액션(`source_ref` 기반)과 독립적으로 동작하며, `thread_ts`와 `channel`은 thread mapping에서 추출한다.

### 메커니즘

1. **즉시 리액션**: `check_channel_messages()`에서 DM 감지 시 `add_reaction("eyes")` 호출 (fire-and-forget)
2. **source_ref 전파**: 왕이 결과 처리 시 원본 DM의 `{channel, message_ts}`를 메시지의 `source_ref` 필드로 주입
3. **최종 리액션**: 사절의 각 processor에서 `update_source_reactions(msg, emoji)` 호출
   - `source_ref`가 null이면 자동 건너뜀 (GitHub/Jira 이벤트)

### Slack API

| 용도 | 엔드포인트 | 비고 |
|------|-----------|------|
| 리액션 추가 | `POST reactions.add` | channel + timestamp + name |
| 리액션 제거 | `POST reactions.remove` | `|| true` (이미 없어도 무시) |

### 필요 스코프

| 스코프 | 용도 |
|--------|------|
| `reactions:write` | 이모지 리액션 추가/제거 |
| `reactions:read` | (현재 불필요, 향후 상태 확인용 예비) |

---

## 인바운드: Slack → 시스템

사절은 세 가지 인바운드 경로를 감지한다. 모든 스레드 응답은 `slack.thread.reply` 단일 이벤트로 통합.

### 1. DM 새 메시지 → `slack.channel.message`

```
사용자 DM: "안녕" (ts: 1234.5678)
     ▼
사절: check_channel_messages() (30초 간격)
     → conversations.history로 새 top-level 메시지 감지
     → 봇 메시지, 스레드 답글 필터
     → slack.channel.message 이벤트 생성
     ▼
왕: 장군 라우팅 → 작업 배정
```

상태 파일: `state/envoy/last-channel-check-ts` (마지막 확인 ts)

### 2. Awaiting 응답 (needs_human) → `slack.thread.reply`

```
사람 (Slack 스레드)
     │ "포함해줘"
     ▼
사절: check_awaiting_responses() (30초 간격)
     → reply_context 포함한 slack.thread.reply 이벤트 생성
     → awaiting-responses.json에서 제거
     ▼
왕: process_thread_reply() → resume 태스크 (reply_context에서 general/session_id 복원)
```

### 3. 대화 스레드 (멀티턴) → `slack.thread.reply`

```
사용자 스레드 답글
     ▼
사절: check_conversation_threads() (15초 간격)
     → TTL 만료 체크 → 만료 시 추적 제거
     → 새 답글 감지 → reply_context 포함한 slack.thread.reply 이벤트 생성
     → last_reply_ts 갱신
     ▼
왕: process_thread_reply() → resume 태스크 (동일한 핸들러)
```

상태 파일: `state/envoy/conversation-threads.json` (thread_ts → {channel, last_reply_ts, expires_at, reply_context})

### reply_context 흐름

사절은 메시지 의미를 해석하지 않는다. 왕이 아웃바운드 메시지에 포함한 `reply_context`를 추적 파일에 저장하고, 사람 응답 시 이벤트 payload에 그대로 반환한다.

```
왕 → human_input_request { reply_context: {general, session_id, repo} }
  → 사절: awaiting-responses.json에 reply_context 저장
  → 사람 응답 → 사절: slack.thread.reply 이벤트 { payload.reply_context }

왕 → thread_reply { track_conversation: {reply_context, ttl_seconds} }
  → 사절: conversation-threads.json에 저장
  → 사람 답글 → 사절: slack.thread.reply 이벤트 { payload.reply_context }
```

### 통합 이벤트 스키마: `slack.thread.reply`

```json
{
  "id": "evt-slack-reply-{thread_ts_sanitized}-{unix_ts}",
  "type": "slack.thread.reply",
  "source": "slack",
  "payload": {
    "text": "사람 응답 텍스트",
    "channel": "D08XXX",
    "thread_ts": "1234.5678",
    "reply_context": {
      "general": "gen-pr",
      "session_id": "session-abc",
      "repo": "querypie/frontend"
    }
  },
  "priority": "high",
  "created_at": "...",
  "status": "pending"
}
```

### needs_human vs 대화 — 추적 파일 분리, 이벤트 통합

| | needs_human | 대화 스레드 |
|---|---|---|
| 시작자 | 시스템 (thread_start) | 유저 (DM) |
| 추적 파일 | `awaiting-responses.json` | `conversation-threads.json` |
| 추적 모드 | 일회성 (응답 후 제거) | 멀티턴 (TTL 기반) |
| **이벤트** | **`slack.thread.reply`** | **`slack.thread.reply`** |
| **왕 핸들러** | **`process_thread_reply()`** | **`process_thread_reply()`** |

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
├── awaiting-responses.json      # [ { "task_id": "...", "thread_ts": "...", "reply_context": {...}, "asked_at": "..." } ]
├── conversation-threads.json    # { "1234.5678": { "task_id": "...", "channel": "...", "last_reply_ts": "...", "expires_at": "...", "reply_context": {...} } }
├── socket-inbox/                # Socket Mode 인바운드 이벤트 (bridge.js → envoy.sh)
├── outbox/                      # 아웃바운드 요청 (envoy.sh → bridge.js)
├── outbox-results/              # 아웃바운드 결과 (bridge.js → envoy.sh)
├── bridge-health                # bridge.js 생존 확인 (10초마다 touch)
└── last-channel-check-ts        # DM 채널 마지막 확인 ts (숫자)
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
  local task_id="$1" thread_ts="$2" channel="$3" reply_context_json="${4:-"{}"}"
  local asked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp=$(jq --arg tid "$task_id" --arg ts "$thread_ts" --arg ch "$channel" \
    --arg aa "$asked_at" --argjson rc "$reply_context_json" \
    '. + [{task_id: $tid, thread_ts: $ts, channel: $ch, asked_at: $aa, reply_context: $rc}]' \
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
LAST_CHANNEL_CHECK=0 # DM: 새 메시지 감지
LAST_CONV_CHECK=0    # 대화: 스레드 후속 응답 감지

OUTBOUND_INTERVAL=$(get_config "envoy" "intervals.outbound_seconds" "5")
THREAD_CHECK_INTERVAL=$(get_config "envoy" "intervals.thread_check_seconds" "30")
CHANNEL_CHECK_INTERVAL=$(get_config "envoy" "intervals.channel_check_seconds" "30")
CONV_CHECK_INTERVAL=$(get_config "envoy" "intervals.conversation_check_seconds" "15")
CONV_TTL=$(get_config "envoy" "intervals.conversation_ttl_seconds" "3600")

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

  # ── 3. DM 채널 메시지 확인 (30초) ──────────────
  if (( now - LAST_CHANNEL_CHECK >= CHANNEL_CHECK_INTERVAL )); then
    check_channel_messages
    LAST_CHANNEL_CHECK=$now
  fi

  # ── 4. 대화 스레드 후속 응답 확인 (15초) ────────
  if (( now - LAST_CONV_CHECK >= CONV_CHECK_INTERVAL )); then
    check_conversation_threads
    LAST_CONV_CHECK=$now
  fi

  sleep "$LOOP_TICK"
done
```

### 아웃바운드 큐 처리

```bash
MAX_RETRY_COUNT=$(get_config "envoy" "retry.max_count" "3")

process_outbound_queue() {
  local pending_dir="$BASE_DIR/queue/messages/pending"
  local sent_dir="$BASE_DIR/queue/messages/sent"
  local failed_dir="$BASE_DIR/queue/messages/failed"
  mkdir -p "$failed_dir"

  for msg_file in "$pending_dir"/*.json; do
    [ -f "$msg_file" ] || continue

    local msg=$(cat "$msg_file")
    local msg_type=$(echo "$msg" | jq -r '.type')

    local send_ok=true
    case "$msg_type" in
      thread_start)       process_thread_start "$msg" || send_ok=false ;;
      thread_update)      process_thread_update "$msg" || send_ok=false ;;
      human_input_request) process_human_input_request "$msg" || send_ok=false ;;
      notification)       process_notification "$msg" || send_ok=false ;;
      report)             process_report "$msg" || send_ok=false ;;
      *)                  log "[EVENT] [envoy] Unknown message type: $msg_type" ;;
    esac

    if $send_ok; then
      mv "$msg_file" "$sent_dir/"
    else
      # 재시도 카운터 증가
      local retry_count=$(echo "$msg" | jq -r '.retry_count // 0')
      retry_count=$((retry_count + 1))

      if (( retry_count >= MAX_RETRY_COUNT )); then
        # 최대 재시도 초과 → 영구 실패 격리
        log "[ERROR] [envoy] Message permanently failed after $retry_count retries: $(basename "$msg_file")"
        mv "$msg_file" "$failed_dir/"
      else
        # pending에 유지, retry_count 갱신
        echo "$msg" | jq --argjson rc "$retry_count" '.retry_count = $rc' > "${msg_file}.tmp"
        mv "${msg_file}.tmp" "$msg_file"
        log "[WARN] [envoy] Message send failed (retry $retry_count/$MAX_RETRY_COUNT): $(basename "$msg_file")"
      fi
    fi
  done
}
```

---

## 이벤트 타입 정의

> 전체 이벤트 타입 카탈로그: [systems/event-types.md](../systems/event-types.md)

### 인바운드 (Slack → 시스템)

| Type | 발생 조건 | Priority |
|------|----------|----------|
| `slack.channel.message` | DM 새 top-level 메시지 | normal |
| `slack.app_mention` | 채널에서 @멘션 (Socket Mode) | normal |
| `slack.thread.reply` | 스레드 사람 응답 (needs_human + 대화 통합) | high |

### 아웃바운드 메시지 타입 (시스템 → Slack)

| Type | 생성자 | Slack 동작 |
|------|--------|-----------|
| `thread_start` | 왕 | 채널 메시지 생성 (스레드 부모) |
| `thread_update` | 장군/병사 경유 | 스레드 답글 |
| `thread_reply` | 왕 (성공 시 reply_to) | 스레드 답글 + 대화 추적 등록 (선택) |
| `human_input_request` | 왕 (needs_human 감지 시) | 스레드 답글 + awaiting 등록 (reply_context 포함) |
| `notification` | 왕/장군/내관 | 스레드 답글 또는 채널 메시지 |
| `report` | 내관 (generate_daily_report) | 채널 메시지 |

---

## needs_human 전체 흐름 (정리됨)

```
1. 병사: 작업 중 판단 필요 → result에 needs_human + checkpoint 저장 → 종료

2. 장군: escalate_to_king() → checkpoint 저장

3. 왕: handle_needs_human()
   → complete_task() — 태스크 즉시 완료 (in_progress 잔류 없음)
   → reply_context 구성 (checkpoint에서 general/session_id/repo 추출)
   → human_input_request 메시지 생성 (reply_context 포함)
   {
     type: "human_input_request",
     task_id: "task-001",
     content: "[question] 보안 이슈 2건, 리뷰에 포함할까요?",
     reply_context: { general: "gen-pr", session_id: "session-abc", repo: "querypie/frontend" }
   }

4. 사절: 스레드에 질문 게시 + awaiting_responses에 등록 (reply_context 포함)

5. 사람: 스레드에서 "포함해줘" 답변

6. 사절: 스레드 폴링에서 답변 감지
   → queue/events/pending/ 에 이벤트 생성
   {
     type: "slack.thread.reply",
     payload: { text: "포함해줘", reply_context: { general: "gen-pr", session_id: "session-abc" } }
   }

7. 왕: process_thread_reply() → reply_context에서 resume 태스크 생성 (checkpoint 조회 불필요)

8. 장군: --resume SESSION_ID → 세션 재개
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
  default_channel: "dev-eddy"            # fallback (환경변수 SLACK_DEFAULT_CHANNEL 우선)

intervals:
  outbound_seconds: 5                   # 메시지 큐 소비
  thread_check_seconds: 30              # awaiting 스레드 확인
  channel_check_seconds: 30             # DM 새 메시지 감지
  conversation_check_seconds: 15        # 대화 스레드 후속 응답 확인
  conversation_ttl_seconds: 3600        # 대화 스레드 추적 만료 (1시간)

socket_mode:
  enabled: true
  app_token_env: "SLACK_APP_TOKEN"
```

## 장애 대응

| 상황 | 행동 |
|------|------|
| Slack API 실패 (401/403) | 로그 기록, SLACK_BOT_TOKEN 만료 가능 → 사람에게 알림 불가하므로 내관이 감지 |
| Slack API 실패 (429 Rate Limit) | 로그 기록, Retry-After 헤더 확인 후 대기 |
| Slack API 실패 (5xx) | 로그 기록, retry_count 증가 후 다음 주기에 재시도 (최대 3회) |
| 메시지 전송 영구 실패 (3회 초과) | `queue/messages/failed/`로 격리, 에러 로그 |
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

### Slack App Token (Socket Mode)

| 항목 | 값 |
|------|-----|
| 환경변수 | `SLACK_APP_TOKEN` |
| 토큰 형식 | App-Level Token (`xapp-...`) |
| 발급 | https://api.slack.com/apps → Basic Information → App-Level Tokens → Generate Token (`connections:write` 스코프) |

### Socket Mode 이벤트 구독

| 이벤트 | 용도 |
|--------|------|
| `message.im` | DM 메시지 수신 |
| `app_mention` | 채널에서 @멘션 수신 |

### 필요 Bot Token Scopes

| 스코프 | 용도 | 사용 API |
|--------|------|----------|
| `chat:write` | 채널/스레드에 메시지 전송 | `chat.postMessage` |
| `channels:history` | 공개 채널의 스레드 답글 읽기 (needs_human 응답 감지) | `conversations.replies` |
| `channels:read` | 채널 ID 조회 | `conversations.list` (초기 설정 시) |
| `im:history` | DM 메시지 읽기 (DM 모드에서 인바운드 메시지 + 응답 감지) | `conversations.history`, `conversations.replies` |
| `im:write` | DM으로 메시지 전송 | `chat.postMessage` (DM 모드) |

> `channels:history`/`im:history`는 메시지 전체를 읽을 수 있는 권한이지만, 사절은 awaiting 스레드의 답글만 읽는다.

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
| ~~`reactions:write`~~ | ~~이모지 리액션 안 함~~ → **필요** (Phase 1 리액션 시스템) |

## 스크립트 위치

```
bin/
├── envoy.sh                             # 메인 polling loop + Socket Mode 분기
└── lib/envoy/
    ├── bridge.js                        # Socket Mode WebSocket 브릿지 (Node.js)
    ├── slack-api.sh                     # Slack API 함수 (outbox/curl 분기)
    └── thread-manager.sh                # 스레드 매핑, awaiting 관리
```

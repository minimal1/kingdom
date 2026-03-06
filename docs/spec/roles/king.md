# 왕 (King)

> 나라의 중심. 파수꾼의 보고를 받아 판단하고, 적합한 장군에게 지시를 내린다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `king` |
| tmux 세션 | `king` |
| 실행 형태 | Bash 스크립트 (polling loop) |
| 수명 | 상주 (Always-on) |
| 리소스 | 경량 (판단은 규칙 기반, petition만 LLM 사용) |

## 책임 — "무엇을, 누구에게"

- **이벤트 소비**: `queue/events/pending/`에서 이벤트를 읽고 처리
- **동적 라우팅**: 장군 매니페스트를 읽어 이벤트 타입 → 장군 매칭 테이블 구성
- **리소스 기반 판단**: 현재 시스템 상태에 따라 작업 수용/보류 결정
- **작업 생성**: task.json을 생성하여 장군의 큐에 배정
- **스케줄 실행**: 장군 매니페스트에 선언된 정기 작업을 시간에 맞춰 트리거
- **결과 처리**: 완료/실패/needs_human 결과에 따른 후속 조치
- **작업 재개**: `slack.thread.reply` 이벤트 수신 시 reply_context 기반 작업 재배정 (needs_human + 대화 통합)
- **상소 심의 (petition)**: `slack.channel.message` — 백성(사용자)의 DM 상소를 LLM(haiku)으로 분류하여 적절한 장군에게 하명 (비동기 tmux 실행)

## 하지 않는 것

- 작업의 구체적 실행 방법 결정 (장군의 책임)
- 병사 직접 생성/관리 (장군의 책임)
- 외부 이벤트 감지 (파수꾼의 책임)
- 리소스 모니터링 수치 수집 (내관의 책임)
- **이벤트 무시/폐기** — 왕에게 도달한 이벤트는 모두 유효 (센티널이 필터 완료)

---

## 장군 매니페스트 & 동적 라우팅

### 설계 원칙

- **이벤트 타입은 외부 소스가 결정**: GitHub API → `github.pr.*`, Jira API → `jira.ticket.*`
- **장군은 기존 이벤트 타입을 구독**: 새 이벤트 타입을 만들지 않고, 이미 존재하는 타입 중 처리 가능한 것을 선언
- **왕은 매니페스트를 읽어 라우팅 테이블을 동적으로 구성**: 장군 추가/제거 시 왕의 코드 수정 불필요

### 매니페스트 스키마

```yaml
# generals/gen-pr/manifest.yaml (install-general.sh로 설치 → config/generals/gen-pr.yaml)
name: gen-pr
description: "PR 리뷰 전문 장군"
timeout_seconds: 1800       # 30분 — 리뷰는 읽기 + 코멘트 위주

cc_plugins:
  - friday@qp-plugin

# 구독: 이 장군이 처리할 수 있는 이벤트 타입
subscribes:
  - github.pr.review_requested
  - github.pr.mentioned
  - github.pr.assigned

# 정기 작업: 외부 이벤트 없이 자체 스케줄로 실행
schedules: []
```

```yaml
# (예시) 스케줄 기반 장군 매니페스트
name: gen-example
description: "스케줄 기반 장군 예시"
timeout_seconds: 3600
cc_plugins: []
subscribes: []    # 외부 이벤트 구독 없음 — 순수 스케줄 기반
schedules:
  - name: daily-task
    cron: "0 22 * * 1-5"
    task_type: "daily-task"
    payload:
      description: "Weekday 22:00 scheduled task"
```

> `cc_plugins` 필드는 장군의 `ensure_workspace()`가 소비한다. 왕의 라우팅 로직(`load_general_manifests`)은 subscribes/schedules만 읽으므로 변경 불필요.
> 매니페스트 소스는 `generals/gen-{name}/manifest.yaml`이며, `install-general.sh`가 `config/generals/{name}.yaml`로 복사한다.

### 시작 시 라우팅 테이블 구성

```bash
# bin/lib/king/router.sh

GENERALS_CONFIG_DIR="$BASE_DIR/config/generals"

# 라우팅 테이블: event_type → general_name
declare -A ROUTING_TABLE
# 스케줄 목록: general_name → schedule entries
declare -a SCHEDULES

# 장군 매니페스트를 읽어 라우팅 테이블 구성
load_general_manifests() {
  ROUTING_TABLE=()
  SCHEDULES=()

  for manifest in "$GENERALS_CONFIG_DIR"/*.yaml; do
    [ -f "$manifest" ] || continue

    local name=$(yq eval '.name' "$manifest")
    local subscribes=$(yq eval '.subscribes[]' "$manifest" 2>/dev/null)

    # 구독 이벤트 → 라우팅 테이블
    while IFS= read -r event_type; do
      [ -z "$event_type" ] && continue
      if [ -n "${ROUTING_TABLE[$event_type]}" ]; then
        log "[WARN] [king] Event type '$event_type' already claimed by ${ROUTING_TABLE[$event_type]}, ignoring $name"
        continue
      fi
      ROUTING_TABLE["$event_type"]="$name"
    done <<< "$subscribes"

    # 스케줄 등록
    local schedule_count=$(yq eval '.schedules | length' "$manifest")
    for ((i=0; i<schedule_count; i++)); do
      local sched_json=$(yq eval -o=json ".schedules[$i]" "$manifest")
      SCHEDULES+=("$name|$sched_json")
    done

    log "[SYSTEM] [king] Loaded general: $name ($(echo "$subscribes" | wc -l | tr -d ' ') event types, $schedule_count schedules)"
  done

  log "[SYSTEM] [king] Routing table: ${#ROUTING_TABLE[@]} event types → generals"
}

# 이벤트 타입으로 장군 찾기
find_general() {
  local event_type="$1"

  # 정확한 매칭
  if [ -n "${ROUTING_TABLE[$event_type]}" ]; then
    echo "${ROUTING_TABLE[$event_type]}"
    return 0
  fi

  # 와일드카드 매칭: github.pr.review_requested → github.pr.* 체크
  local prefix="${event_type%.*}"
  local wildcard="${prefix}.*"
  # (라우팅 테이블에 와일드카드 패턴이 있을 경우)

  log "[WARN] [king] No general found for event type: $event_type"
  return 1
}
```

### 플러거블 축 정리

| 축 | 플러그인 단위 | 누가 정의 | 추가 시 영향 |
|---|-------------|----------|-------------|
| 외부 소스 | Watcher (github, jira, ...) | 센티널 | 새 watcher 작성 |
| 처리 능력 | General (gen-pr, gen-briefing, ...) | 장군 매니페스트 | 매니페스트 추가만 (왕/센티널 수정 불필요) |

> 아무 장군도 구독하지 않는 이벤트 타입이 센티널에서 생산되면, 왕은 `find_general()`에서 매칭 실패 → 로그 경고 후 이벤트를 completed로 이동 (폐기).

---

## 왕 메인 루프

```bash
#!/bin/bash
# bin/king.sh — 왕 메인 루프

BASE_DIR="/opt/kingdom"
source "$BASE_DIR/bin/lib/common.sh"          # 공통 함수 (log, get_config, start_heartbeat_daemon, emit_event)
source "$BASE_DIR/bin/lib/king/router.sh"      # 라우팅 테이블, find_general
source "$BASE_DIR/bin/lib/king/resource-check.sh"

# ── Graceful Shutdown ────────────────────────────
RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [king] Shutting down..."; exit 0' SIGTERM SIGINT

# ── 장군 매니페스트 로딩 ─────────────────────────
load_general_manifests

# ── Task ID 시퀀스 (파일 기반, 재시작 안전) ────────
TASK_SEQ_FILE="$BASE_DIR/state/king/task-seq"
next_task_id() {
  local today=$(date +%Y%m%d)
  local last=$(cat "$TASK_SEQ_FILE" 2>/dev/null || echo "00000000:000")
  local last_date="${last%%:*}"
  local last_seq="${last##*:}"

  if [ "$last_date" = "$today" ]; then
    local seq=$((10#$last_seq + 1))
  else
    local seq=1
  fi

  local formatted=$(printf '%03d' $seq)
  echo "${today}:${formatted}" > "$TASK_SEQ_FILE"
  echo "task-${today}-${formatted}"
}

# ── 타이머 ───────────────────────────────────────
LAST_EVENT_CHECK=0
LAST_RESULT_CHECK=0
LAST_SCHEDULE_CHECK=0
LAST_PETITION_CHECK=0

EVENT_CHECK_INTERVAL=10    # 10초 — 이벤트 큐 소비
PETITION_CHECK_INTERVAL=5  # 5초  — 상소 심의 결과 수거
RESULT_CHECK_INTERVAL=10   # 10초 — 작업 결과 확인
SCHEDULE_CHECK_INTERVAL=60 # 60초 — 장군 스케줄 확인

log "[SYSTEM] [king] Started. ${#ROUTING_TABLE[@]} event types registered."

start_heartbeat_daemon "king"

while $RUNNING; do
  now=$(date +%s)

  # ── 1. 이벤트 소비 (10초) ──────────────────────
  if (( now - LAST_EVENT_CHECK >= EVENT_CHECK_INTERVAL )); then
    process_pending_events
    LAST_EVENT_CHECK=$now
  fi

  # ── 1.5 상소 심의 결과 수거 (5초) ─────────────
  if (( now - LAST_PETITION_CHECK >= PETITION_CHECK_INTERVAL )); then
    process_petition_results
    LAST_PETITION_CHECK=$now
  fi

  # ── 2. 결과 확인 (10초) ────────────────────────
  if (( now - LAST_RESULT_CHECK >= RESULT_CHECK_INTERVAL )); then
    check_task_results
    LAST_RESULT_CHECK=$now
  fi

  # ── 3. 스케줄 확인 (60초) ──────────────────────
  if (( now - LAST_SCHEDULE_CHECK >= SCHEDULE_CHECK_INTERVAL )); then
    check_general_schedules
    LAST_SCHEDULE_CHECK=$now
  fi

  sleep 5  # 메인 루프 틱
done
```

---

## 이벤트 소비

### 흐름

```
queue/events/pending/*.json
     │
     │ 읽기 + priority 정렬
     ▼
┌──────────────────┐
│ 이벤트 분류       │
├─ source: slack   │──→ 작업 재개 경로 (human_response)
├─ source: github  │──→ 새 작업 경로
└─ source: jira    │──→ 새 작업 경로
     │
     ▼
┌──────────────────┐
│ 리소스 확인       │──── yellow/orange/red → 보류 (pending 유지)
└────────┬─────────┘
         ▼
┌──────────────────┐
│ 병사 수 확인      │──── max_soldiers 초과 → 보류 (pending 유지)
└────────┬─────────┘
         ▼
┌──────────────────┐
│ 장군 매칭         │──── 매칭 실패 → 경고 로그, completed로 이동
└────────┬─────────┘
         ▼
┌──────────────────────────────┐
│ task.json 생성                │
│ → queue/tasks/pending/       │
│ + 사절에게 thread_start 메시지 │
│ + 이벤트를 dispatched로 이동  │
└──────────────────────────────┘
```

### 이벤트 소비 코드

```bash
process_pending_events() {
  local pending_dir="$BASE_DIR/queue/events/pending"

  # pending 이벤트 수집 + priority 정렬 (high → normal → low)
  local events=$(collect_and_sort_events "$pending_dir")
  [ -z "$events" ] && return 0

  echo "$events" | while IFS= read -r event_file; do
    [ -f "$event_file" ] || continue
    local event=$(cat "$event_file")
    local event_id=$(echo "$event" | jq -r '.id')
    local event_type=$(echo "$event" | jq -r '.type')
    local source=$(echo "$event" | jq -r '.source')
    local priority=$(echo "$event" | jq -r '.priority')

    # ── slack.thread.reply → 작업 재개 경로 ──
    if [ "$event_type" = "slack.thread.reply" ]; then
      process_thread_reply "$event" "$event_file"
      continue
    fi

    # ── 새 작업 경로 ──

    # 1. 리소스 확인
    local health=$(get_resource_health)
    if ! can_accept_task "$health" "$priority"; then
      # 보류: pending에 그대로 둠, 다음 주기에 재시도
      continue
    fi

    # 2. 병사 수 확인 (max_soldiers) — sessions.json (JSON 배열) 기준
    local max_soldiers=$(get_config "king" "concurrency.max_soldiers")
    local active_soldiers=0
    if [ -f "$BASE_DIR/state/sessions.json" ]; then
      active_soldiers=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
    fi
    if (( active_soldiers >= max_soldiers )); then
      log "[EVENT] [king] Max soldiers reached ($active_soldiers/$max_soldiers), deferring event: $event_id"
      continue
    fi

    # 3. 장군 매칭
    local general=$(find_general "$event_type")
    if [ -z "$general" ]; then
      log "[WARN] [king] No general for event type: $event_type, discarding: $event_id"
      mv "$event_file" "$BASE_DIR/queue/events/completed/"
      continue
    fi

    # 4. 작업 생성
    dispatch_new_task "$event" "$general" "$event_file"
  done
}

# 이벤트를 priority 순서로 정렬
collect_and_sort_events() {
  local dir="$1"
  # high(1) → normal(2) → low(3) 순으로 정렬
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    local p=$(jq -r '.priority' "$f")
    local order=2
    case "$p" in
      high) order=1 ;;
      normal) order=2 ;;
      low) order=3 ;;
    esac
    echo "$order $f"
  done | sort -n | cut -d' ' -f2
}
```

### 새 작업 배정

```bash
dispatch_new_task() {
  local event="$1"
  local general="$2"
  local event_file="$3"

  local event_id=$(echo "$event" | jq -r '.id')
  local event_type=$(echo "$event" | jq -r '.type')
  local repo=$(echo "$event" | jq -r '.repo // empty')
  # 이벤트에 repo가 없으면 장군 manifest의 default_repo 사용
  if [ -z "$repo" ]; then
    repo=$(get_default_repo "$general")
  fi
  local priority=$(echo "$event" | jq -r '.priority')
  local task_id=$(next_task_id)

  # task.json 생성 (Write-then-Rename)
  local task=$(jq -n \
    --arg id "$task_id" \
    --arg event_id "$event_id" \
    --arg general "$general" \
    --arg type "$event_type" \
    --arg priority "$priority" \
    --argjson payload "$(echo "$event" | jq '.payload')" \
    --arg repo "$repo" \
    '{
      id: $id,
      event_id: $event_id,
      target_general: $general,
      type: $type,
      repo: $repo,
      payload: $payload,
      priority: $priority,
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
  mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
     "$BASE_DIR/queue/tasks/pending/${task_id}.json"

  # 사절에게 thread_start 메시지 생성 (DM이면 기존 thread_ts 포함)
  create_thread_start_message "$task_id" "$general" "$event"

  # 이벤트를 dispatched로 이동
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Dispatched: $event_id → $general (task: $task_id)"
}
```

### 작업 재개 (thread_reply)

사절이 생성하는 `slack.thread.reply` 통합 이벤트를 처리한다. needs_human 응답과 대화 스레드 응답 모두 이 핸들러에서 처리.

`reply_context`에 장군/세션 정보가 포함되어 있으므로 체크포인트 파일 조회가 불필요하다.

```bash
process_thread_reply() {
  local event="$1"
  local event_file="$2"

  local event_id=$(echo "$event" | jq -r '.id')
  local text=$(echo "$event" | jq -r '.payload.text')
  local channel=$(echo "$event" | jq -r '.payload.channel')
  local thread_ts=$(echo "$event" | jq -r '.payload.thread_ts')

  # reply_context에서 resume 정보 추출
  local general=$(echo "$event" | jq -r '.payload.reply_context.general // empty')
  local session_id=$(echo "$event" | jq -r '.payload.reply_context.session_id // empty')
  local repo=$(echo "$event" | jq -r '.payload.reply_context.repo // empty')

  if [[ -z "$general" ]]; then
    log "[WARN] [king] No general in reply_context, discarding: $event_id"
    mv "$event_file" "$BASE_DIR/queue/events/completed/"
    return 0
  fi

  local task_id=$(next_task_id)
  local task=$(jq -n \
    --arg id "$task_id" \
    --arg event_id "$event_id" \
    --arg general "$general" \
    --arg text "$text" \
    --arg session_id "$session_id" \
    --arg repo "$repo" \
    --arg channel "$channel" \
    --arg thread_ts "$thread_ts" \
    '{
      id: $id,
      event_id: $event_id,
      target_general: $general,
      type: "resume",
      repo: (if $repo == "" then null else $repo end),
      payload: {
        human_response: $text,
        session_id: $session_id,
        channel: $channel,
        thread_ts: $thread_ts
      },
      priority: "high",
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Thread reply → $general (task: $task_id)"
}
```

---

## 상소 심의 (Petition — 비동기 DM 분류)

DM(`slack.channel.message`)은 백성이 왕에게 직접 올리는 **상소**다. 메시지 **내용** 분석이 필요하므로, 왕은 LLM 기반 분류를 tmux 세션으로 비동기 실행하여 적합한 장군에게 하명한다.

### 2단계 처리

```
[Phase 1: 이벤트 접수 — process_pending_events]
DM 이벤트 도착 → petition enabled? → pending/ → petitioning/ 이동 + tmux 세션 스폰
(왕의 메인 루프 계속 — 블로킹 없음)

[Phase 2: 결과 수거 — process_petition_results]
tmux 세션 완료 → state/king/petition-results/{event_id}.json 생성
왕: 결과 읽기 → 4단계 분기:
  1. petition → general 있음 → dispatch to general
  2. petition → direct_response 있음 → 사절에게 DM 답글 전달
  3. find_general (정적 매핑) → 구독 장군에게 dispatch
  4. 모두 실패 → "처리 불가" 응답
```

### petition 결과 스키마

```json
// Case 1: 장군 매칭
{"general": "gen-pr", "repo": "chequer-io/querypie-frontend"}

// Case 2: 직접 답변 (시스템 메타 질문)
{"general": null, "direct_response": "현재 활성 장군: ..."}

// Case 3: 매칭 불가
{"general": null}
```

### 스크립트

```
bin/petition-runner.sh          — tmux 세션에서 실행. 장군 카탈로그 수집 → LLM 호출 → 결과 기록
bin/lib/king/petition.sh        — spawn_petition() + process_petition_results()
bin/lib/king/functions.sh     — handle_direct_response() + handle_unroutable_dm()
```

### 설정

```yaml
# config/king.yaml
petition:
  enabled: true
  model: haiku
  timeout_seconds: 15

intervals:
  petition_check_seconds: 5
```

---

## 결과 확인 & 완료 처리

### 흐름

```
state/results/{task-id}.json
     │
     │ 왕이 주기적 확인 (10초)
     ▼
┌──────────────────────┐
│ status 분기           │
├─ success             │──→ 완료 처리 (아래) [+ proclamation if present]
├─ failed              │──→ 에스컬레이션 (장군이 재시도 소진 후) [+ proclamation if present]
├─ killed              │──→ 재시도 (retry_count < max) 또는 영구 실패
├─ needs_human         │──→ 사절에게 human_input_request
├─ skipped             │──→ 완료 처리 + 사절에게 ⏭️ 알림 [+ proclamation if present]
└──────────────────────┘
```

### source_ref 주입 (이모지 리액션용)

DM 기반 작업의 결과 처리 시, 왕은 원본 DM의 참조 정보를 사절 메시지에 `source_ref`로 주입한다. 사절은 이를 사용하여 원본 DM에 이모지 리액션(👀→✅/❌/🙋)을 업데이트한다.

```bash
extract_source_ref() {
  local task="$1"
  local src_msg_ts=$(echo "$task" | jq -r '.payload.message_ts // empty')
  local src_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  if [[ -n "$src_msg_ts" && -n "$src_ch" ]]; then
    jq -n --arg ch "$src_ch" --arg ts "$src_msg_ts" '{channel: $ch, message_ts: $ts}'
  else
    echo "null"  # GitHub/Jira 이벤트는 source_ref 없음
  fi
}
```

적용 대상: `handle_success`, `handle_failure`, `handle_skipped`, `handle_needs_human`, `handle_direct_response`

> 상세: [systems/message-passing.md](../systems/message-passing.md#source_ref-원본-dm-참조)

### 결과 처리 코드

```bash
check_task_results() {
  local results_dir="$BASE_DIR/state/results"
  local dispatched_dir="$BASE_DIR/queue/events/dispatched"
  local tasks_in_progress="$BASE_DIR/queue/tasks/in_progress"

  for result_file in "$results_dir"/task-*.json; do
    [ -f "$result_file" ] || continue

    # 장군 내부 파일은 스킵 (-checkpoint.json, -raw.json, -soldier-id)
    echo "$result_file" | grep -qE '\-(checkpoint|raw|soldier-id)\.' && continue

    local result=$(cat "$result_file")
    local task_id=$(echo "$result" | jq -r '.task_id')
    local status=$(echo "$result" | jq -r '.status')

    # 이미 처리된 결과인지 확인 (in_progress에 해당 task가 없으면 이미 처리됨)
    [ -f "$tasks_in_progress/${task_id}.json" ] || continue

    case "$status" in
      success)
        handle_success "$task_id" "$result"
        ;;
      failed)
        handle_failure "$task_id" "$result"
        ;;
      killed)
        handle_killed "$task_id" "$result"
        ;;
      needs_human)
        handle_needs_human "$task_id" "$result"
        ;;
      skipped)
        handle_skipped "$task_id" "$result"
        ;;
      *)
        log "[WARN] [king] Unknown result status: $status for task: $task_id"
        ;;
    esac
  done
}
```

### 성공 처리

```bash
handle_success() {
  local task_id="$1"
  local result="$2"
  local summary=$(echo "$result" | jq -r '.summary // "completed"')

  # task 파일을 먼저 읽은 후 complete_task 호출 (mv 후에는 경로가 바뀜)
  local task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general=$(echo "$task" | jq -r '.target_general')

  # 작업 완료 처리
  complete_task "$task_id"

  # reply_to 분기: 기존 스레드에 답글 or 새 알림
  local reply_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  local reply_ts=$(echo "$task" | jq -r '.payload.thread_ts // .payload.message_ts // empty')

  if [[ -n "$reply_ch" && -n "$reply_ts" ]]; then
    # DM/스레드 대화 → thread_reply 메시지 + 대화 추적 등록
    local session_id=$(cat "$BASE_DIR/state/results/${task_id}-session-id" 2>/dev/null || echo "")
    local repo=$(echo "$task" | jq -r '.repo // empty')
    local msg_id=$(next_msg_id)
    local track_json="null"
    if [[ -n "$session_id" ]]; then
      local reply_ctx=$(jq -n --arg s "$session_id" --arg g "$general" --arg r "$repo" \
        '{session_id: $s, general: $g, repo: $r}')
      track_json=$(jq -n --argjson rc "$reply_ctx" '{reply_context: $rc}')
    fi
    local message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$reply_ch" --arg ts "$reply_ts" --arg ct "$summary" \
      --argjson tc "$track_json" \
      '{ id: $id, type: "thread_reply", task_id: $task, channel: $ch,
         thread_ts: $ts, content: $ct, track_conversation: $tc,
         created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending" }')
    write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"
  else
    # 일반 작업 → 알림 메시지 (결과에 notify_channel이 있으면 해당 채널로)
    # Rich context: task의 type/payload에서 GitHub/Jira 링크 추출
    local notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
    local ctx=$(format_task_context "$(echo "$task" | jq -r '.type')" "$(echo "$task" | jq -c '.payload // {}')")
    if [[ -n "$ctx" ]]; then
      create_notification_message "$task_id" "$(printf '✅ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$summary")" "$notify_ch"
    else
      create_notification_message "$task_id" "$(printf '✅ *%s* | %s\n%s' "$general" "$task_id" "$summary")" "$notify_ch"
    fi
  fi

  # Proclamation: 별도 채널 공표 (운영 알림과 독립)
  local proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  local proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

  log "[EVENT] [king] Task completed: $task_id"
}
```

### 실패 처리

> **재시도는 장군 전담**. 왕에게 도달하는 failed는 장군이 max retry를 소진한 최종 실패이다.
> 단, `killed` 상태(병사 강제 kill)는 왕이 직접 재시도를 관리한다 — 아래 참조.

```bash
handle_failure() {
  local task_id="$1"
  local result="$2"
  local error=$(echo "$result" | jq -r '.error // "unknown"')

  local task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general=$(echo "$task" | jq -r '.target_general')

  # 장군이 이미 재시도를 소진한 최종 실패 — 에스컬레이션만 수행
  complete_task "$task_id"
  local notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
  local ctx=$(format_task_context "$(echo "$task" | jq -r '.type')" "$(echo "$task" | jq -c '.payload // {}')")
  if [[ -n "$ctx" ]]; then
    create_notification_message "$task_id" "$(printf '❌ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$error")" "$notify_ch"
  else
    create_notification_message "$task_id" "$(printf '❌ *%s* | %s\n%s' "$general" "$task_id" "$error")" "$notify_ch"
  fi

  # Proclamation
  local proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  local proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

  log "[ERROR] [king] Task failed permanently: $task_id — $error"
}
```

### killed 처리

> 병사가 강제 kill되면 `wait_for_soldier`가 10초 이내에 tmux 세션 죽음을 감지하고 `status: "killed"`를 기록한다. 왕은 `retry.max_attempts` 이내면 task를 `pending/`으로 되돌려 재시도한다.

```bash
handle_killed() {
  local task_id="$1"
  local result="$2"
  local error=$(echo "$result" | jq -r '.error // "unknown"')

  local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  local task=$(cat "$task_file" 2>/dev/null)
  local general=$(echo "$task" | jq -r '.target_general')
  local retry_count=$(echo "$task" | jq -r '.retry_count // 0')
  local max_retries=$(get_config "king" "retry.max_attempts" "2")

  if (( retry_count < max_retries )); then
    # in_progress/ → pending/ (retry_count 증가)
    echo "$task" | jq --argjson rc "$((retry_count + 1))" \
      '.retry_count = $rc | .status = "pending"' > "$BASE_DIR/queue/tasks/pending/${task_id}.json"
    rm -f "$task_file"
    # result 파일 정리
    rm -f "$BASE_DIR/state/results/${task_id}"{-raw.json,-soldier-id,-session-id,.json}
    log "[RETRY] [king] Task re-queued: $task_id ($general) retry=$((retry_count + 1))/$max_retries"
  else
    handle_failure "$task_id" "$result"  # 영구 실패로 위임
  fi
}
```

### needs_human 처리

태스크를 즉시 완료 처리하고, checkpoint에서 `reply_context`를 구성하여 메시지에 포함한다. 사절은 `reply_context`를 그대로 추적 파일에 저장하고, 사람 응답 시 이벤트 payload로 되돌린다. 이로써 checkpoint 파일 조회 없이 resume 태스크를 생성할 수 있다.

```bash
handle_needs_human() {
  local task_id="$1"
  local result="$2"
  local question=$(echo "$result" | jq -r '.question')
  local checkpoint_path=$(echo "$result" | jq -r '.checkpoint_path')

  # checkpoint에서 reply_context 구성
  local checkpoint=$(cat "$checkpoint_path" 2>/dev/null || echo '{}')
  local general=$(echo "$checkpoint" | jq -r '.target_general // empty')
  local session_id=$(echo "$checkpoint" | jq -r '.session_id // empty')
  local repo=$(echo "$checkpoint" | jq -r '.repo // empty')

  local reply_ctx=$(jq -n \
    --arg g "$general" --arg s "$session_id" --arg r "$repo" \
    '{general: $g, session_id: $s, repo: $r}')

  # DM 원본 채널/스레드 정보 추출 (complete_task가 파일 이동 전에 읽기)
  local task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local reply_ch=$(echo "$task" | jq -r '.payload.channel // empty')
  local reply_ts=$(echo "$task" | jq -r '.payload.thread_ts // .payload.message_ts // empty')

  # 태스크 완료 처리 (checkpoint에 모든 정보가 보존됨)
  complete_task "$task_id"
  rm -f "$BASE_DIR/state/results/${task_id}.json"

  # 사절에게 human_input_request 메시지 생성 (reply_context 포함)
  # DM task인 경우 channel/thread_ts를 직접 포함 (thread_mapping 없이 전달 가능)
  local msg_id=$(next_msg_id)
  local message=$(jq -n \
    --arg id "$msg_id" \
    --arg task_id "$task_id" \
    --arg content "[question] $question" \
    --argjson reply_ctx "$reply_ctx" \
    --arg ch "$reply_ch" --arg ts "$reply_ts" \
    '{
      id: $id,
      type: "human_input_request",
      task_id: $task_id,
      content: $content,
      reply_context: $reply_ctx,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    } + (if $ch != "" then {channel: $ch} else {} end)
      + (if $ts != "" then {thread_ts: $ts} else {} end)')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$message"

  log "[EVENT] [king] Needs human input: $task_id (completed, reply_context included)"
}
```

### skipped 처리

병사가 작업이 자신의 역량 범위 밖이라고 판단한 경우 (예: 담당 영역이 아닌 PR, 이미 머지된 PR 등). 사절에게 ⏭️ 알림을 보내고 완료 처리한다.

```bash
handle_skipped() {
  local task_id="$1"
  local result="$2"
  local reason=$(echo "$result" | jq -r '.reason // "out of scope"')

  local task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)
  local general=$(echo "$task" | jq -r '.target_general')

  complete_task "$task_id"
  local notify_ch=$(echo "$result" | jq -r '.notify_channel // empty')
  local ctx=$(format_task_context "$(echo "$task" | jq -r '.type')" "$(echo "$task" | jq -c '.payload // {}')")
  if [[ -n "$ctx" ]]; then
    create_notification_message "$task_id" "$(printf '⏭️ *%s* | %s\n%s\n%s' "$general" "$task_id" "$ctx" "$reason")" "$notify_ch"
  else
    create_notification_message "$task_id" "$(printf '⏭️ *%s* | %s\n%s' "$general" "$task_id" "$reason")" "$notify_ch"
  fi

  # Proclamation
  local proc_ch=$(echo "$result" | jq -r '.proclamation.channel // empty')
  local proc_msg=$(echo "$result" | jq -r '.proclamation.message // empty')
  if [[ -n "$proc_ch" && -n "$proc_msg" ]]; then
    create_proclamation_message "$task_id" "$proc_ch" "$proc_msg"
  fi

  log "[EVENT] [king] Task skipped: $task_id — $reason"
}
```

### 완료 공통 처리

```bash
complete_task() {
  local task_id="$1"

  # task를 completed로 이동
  local task_file="$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
  if [ -f "$task_file" ]; then
    local task=$(cat "$task_file")
    local event_id=$(echo "$task" | jq -r '.event_id')
    local repo=$(echo "$task" | jq -r '.repo // empty')

    # task 완료
    mv "$task_file" "$BASE_DIR/queue/tasks/completed/"

    # 이벤트 완료 (dispatched → completed)
    local event_file="$BASE_DIR/queue/events/dispatched/${event_id}.json"
    if [ -f "$event_file" ]; then
      mv "$event_file" "$BASE_DIR/queue/events/completed/"
    fi
  fi
}
```

---

## 스케줄 처리

장군 매니페스트의 `schedules` 항목을 왕이 읽어 시간에 맞춰 작업을 생성한다.

### 스케줄 확인 코드

```bash
SCHEDULE_SENT_FILE="$BASE_DIR/state/king/schedule-sent.json"

# ── M1: cron 매칭 (분 시 일 월 요일) ──
# wildcard(*), step(*/10), range(1-5), exact match 지원
cron_matches() {
  local expr="$1"
  local min hour dom mon dow
  read -r min hour dom mon dow <<< "$expr"

  local now_min=$(date +%-M)
  local now_hour=$(date +%-H)
  local now_dom=$(date +%-d)
  local now_mon=$(date +%-m)
  local now_dow=$(date +%u)  # 1=Mon, 7=Sun

  _cron_field_matches "$min" "$now_min" || return 1
  _cron_field_matches "$hour" "$now_hour" || return 1
  _cron_field_matches "$dom" "$now_dom" || return 1
  _cron_field_matches "$mon" "$now_mon" || return 1
  _cron_field_matches "$dow" "$now_dow" || return 1
  return 0
}

_cron_field_matches() {
  local field="$1"
  local value="$2"

  # Wildcard
  [ "$field" = "*" ] && return 0

  # Step (e.g. */10, */5)
  if [[ "$field" == \*/* ]]; then
    local step="${field#*/}"
    (( value % step == 0 )) && return 0
    return 1
  fi

  # Range (e.g. 1-5)
  if [[ "$field" == *-* ]]; then
    local low="${field%%-*}"
    local high="${field##*-}"
    [ "$value" -ge "$low" ] && [ "$value" -le "$high" ] && return 0
    return 1
  fi

  # Exact match
  [ "$field" = "$value" ] && return 0
  return 1
}

# ── M2: 스케줄 중복 실행 방지 (분 단위) ──
already_triggered() {
  local name="$1"
  local now_key=$(date +%Y-%m-%dT%H:%M)
  local last=$(jq -r --arg n "$name" '.[$n] // ""' "$SCHEDULE_SENT_FILE" 2>/dev/null)
  [ "$last" = "$now_key" ]
}

mark_triggered() {
  local name="$1"
  local now_key=$(date +%Y-%m-%dT%H:%M)
  local current=$(cat "$SCHEDULE_SENT_FILE" 2>/dev/null || echo '{}')
  echo "$current" | jq --arg n "$name" --arg d "$now_key" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
}

check_general_schedules() {
  local now_hour=$(date +%H:%M)
  local now_dow=$(date +%u)    # 1=Mon, 7=Sun
  local now_dom=$(date +%d)    # 01-31

  for entry in "${SCHEDULES[@]}"; do
    local general="${entry%%|*}"
    local sched_json="${entry#*|}"

    local sched_name=$(echo "$sched_json" | jq -r '.name')
    local cron_expr=$(echo "$sched_json" | jq -r '.cron')

    # 간단한 cron 매칭 (분 시 일 월 요일)
    if cron_matches "$cron_expr" && ! already_triggered "$sched_name"; then
      local task_type=$(echo "$sched_json" | jq -r '.task_type')
      local payload=$(echo "$sched_json" | jq '.payload')

      # 리소스 확인
      local health=$(get_resource_health)
      if ! can_accept_task "$health" "normal"; then
        log "[WARN] [king] Skipping schedule '$sched_name': resource $health"
        continue
      fi

      # 스케줄 작업 생성 (repo가 있으면 전달 → ensure_workspace에서 자동 clone)
      local repo=$(echo "$sched_json" | jq -r '.repo // empty')
      dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload" "$repo"
      mark_triggered "$sched_name"

      log "[EVENT] [king] Scheduled task triggered: $sched_name → $general"
    fi
  done
}

dispatch_scheduled_task() {
  local general="$1"
  local sched_name="$2"
  local task_type="$3"
  local payload="$4"
  local repo="${5:-}"    # 스케줄에 repo 선언 시 전달, 없으면 빈 문자열
  local task_id=$(next_task_id)

  local repo_arg="null"
  if [[ -n "$repo" ]]; then
    repo_arg="\"$repo\""
  fi

  local task=$(jq -n \
    --arg id "$task_id" \
    --arg general "$general" \
    --arg type "$task_type" \
    --arg sched "$sched_name" \
    --argjson payload "$payload" \
    --argjson repo "$repo_arg" \
    '{
      id: $id,
      event_id: ("schedule-" + $sched),
      target_general: $general,
      type: $type,
      repo: $repo,
      payload: $payload,
      priority: "low",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  write_to_queue "$BASE_DIR/queue/tasks/pending" "$task_id" "$task"

  # 스케줄 작업도 사절에게 thread_start 알림
  create_thread_start_message "$task_id" "$general" \
    "$(jq -n --arg t "$task_type" --argjson r "$repo_arg" '{type: ("schedule." + $t), repo: $r}')"
}
```

---

## 리소스 기반 행동 규칙

```bash
# bin/lib/king/resource-check.sh

RESOURCES_FILE="$BASE_DIR/state/resources.json"

# 내관이 갱신하는 resources.json에서 health 레벨 읽기
# stale 감지: timestamp가 heartbeat 임계값(120초)을 초과하면 내관 crash로 판단 → orange 반환
get_resource_health() {
  local data=$(cat "$RESOURCES_FILE" 2>/dev/null || echo '{}')
  local health=$(echo "$data" | jq -r '.health // "green"')
  local ts=$(echo "$data" | jq -r '.timestamp // empty')

  # timestamp가 없거나 파일이 없으면 green (초기 상태)
  [ -z "$ts" ] && echo "green" && return 0

  # stale 판단: 120초 이상 미갱신 → 내관 비정상, 안전하게 orange 반환
  local ts_epoch=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)
  local now=$(date +%s)
  local elapsed=$((now - ts_epoch))

  if (( elapsed > 120 )); then
    log "[WARN] [king] resources.json stale: ${elapsed}s old (threshold: 120s)"
    echo "orange"
    return 0
  fi

  echo "$health"
}

# health + priority에 따라 작업 수용 가능 여부 판단
can_accept_task() {
  local health="$1"
  local priority="$2"

  case "$health" in
    green)  return 0 ;;                           # 모든 작업 수용
    yellow) [ "$priority" = "high" ] && return 0   # high만 수용
            return 1 ;;
    orange) return 1 ;;                           # 신규 작업 중단
    red)    return 1 ;;                           # 긴급 정리 모드
  esac
}
```

| Health | 조건 (내관이 판단) | 왕의 행동 |
|--------|-------------------|----------|
| `green` | CPU < 60% AND Memory < 60% | 모든 작업 수용 |
| `yellow` | CPU 60-80% OR Memory 60-80% | `high` 우선순위만 수용 |
| `orange` | CPU > 80% OR Memory > 80% | 신규 작업 중단, 진행 중 작업 완료 대기 |
| `red` | CPU > 90% OR Memory > 90% | 긴급 정리 모드, 사절에게 알림 |

### 토큰 예산 상태

| Token Status | 조건 (내관이 판단) | 왕의 행동 |
|-------------|-------------------|----------|
| `ok` | 일일 비용 < 예산 × 70% | health 기반 판단만 |
| `warning` | 일일 비용 ≥ 예산 × 70% | `high` 또는 health=green일 때만 수용 |
| `critical` | 일일 비용 ≥ 예산 × 90% | `high` 우선순위만 수용 |
| `unknown` | stats-cache.json 없음 | `ok`로 취급 |

> 토큰 상태는 health 판단보다 먼저 평가된다. `critical`이면 health가 green이어도 normal 작업을 거부한다.
> `orange`/`red` 상태에서도 pending 이벤트는 삭제하지 않고 보류한다. 리소스가 회복되면 다음 주기에 자동으로 소비됨.

---

## 사절에게 메시지 생성

왕이 사절에게 보내는 메시지 생성 헬퍼.

```bash
# 메시지 ID 시퀀스 (파일 기반, 재시작 안전)
MSG_SEQ_FILE="$BASE_DIR/state/king/msg-seq"
next_msg_id() {
  local today=$(date +%Y%m%d)
  local last=$(cat "$MSG_SEQ_FILE" 2>/dev/null || echo "00000000:000")
  local last_date="${last%%:*}"
  local last_seq="${last##*:}"

  if [ "$last_date" = "$today" ]; then
    local seq=$((10#$last_seq + 1))
  else
    local seq=1
  fi

  local formatted=$(printf '%03d' $seq)
  echo "${today}:${formatted}" > "$MSG_SEQ_FILE"
  echo "msg-${today}-${formatted}"
}

# thread_start: 작업 시작 알림 (스레드 생성)
create_thread_start_message() {
  local task_id="$1"
  local general="$2"
  local event="$3"
  local event_type=$(echo "$event" | jq -r '.type')
  local repo=$(echo "$event" | jq -r '.repo // ""')
  local msg_id=$(next_msg_id)
  local channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"

  # Rich context: payload에서 GitHub/Jira 링크 추출 (format_task_context)
  local payload=$(echo "$event" | jq -c '.payload // {}')
  [ -n "$repo" ] && payload=$(echo "$payload" | jq --arg r "$repo" '.repo //= $r')
  local ctx=$(format_task_context "$event_type" "$payload")

  if [[ -n "$ctx" ]]; then
    local content=$(printf '📋 *%s* | %s\n%s\n`%s`' "$general" "$task_id" "$ctx" "$event_type")
  else
    local content=$(printf '📋 *%s* | %s\n`%s`' "$general" "$task_id" "$event_type")
    [ -n "$repo" ] && content=$(printf '📋 *%s* | %s\n`%s` | %s' "$general" "$task_id" "$event_type" "$repo")
  fi

  # DM 이벤트: 기존 메시지를 스레드 부모로 재사용 (thread_ts + channel 포함)
  local existing_ts=$(echo "$event" | jq -r '.payload.message_ts // empty')
  local existing_ch=$(echo "$event" | jq -r '.payload.channel // empty')

  local message
  if [[ -n "$existing_ts" && -n "$existing_ch" ]]; then
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$existing_ch" --arg ct "$content" --arg ts "$existing_ts" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        thread_ts: $ts,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  else
    message=$(jq -n \
      --arg id "$msg_id" --arg task "$task_id" \
      --arg ch "$channel" --arg ct "$content" \
      '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')
  fi

  echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
  mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
     "$BASE_DIR/queue/messages/pending/${msg_id}.json"
}

# thread_update: 스레드에 진행 상황 업데이트
create_thread_update_message() {
  local task_id="$1"
  local content="$2"
  local msg_id=$(next_msg_id)

  local message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" --arg ct "$content" \
    '{id: $id, type: "thread_update", task_id: $task, content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
  mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
     "$BASE_DIR/queue/messages/pending/${msg_id}.json"
}

# notification: 완료/실패 알림 (override_channel 지정 시 해당 채널로 전송)
create_notification_message() {
  local task_id="$1"
  local content="$2"
  local override_channel="${3:-}"   # 병사 결과의 notify_channel (선택)
  local msg_id=$(next_msg_id)
  local channel
  if [ -n "$override_channel" ]; then
    channel="$override_channel"
  else
    channel="${SLACK_DEFAULT_CHANNEL:-$(get_config "king" "slack.default_channel")}"
  fi

  local message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "normal", content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
  mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
     "$BASE_DIR/queue/messages/pending/${msg_id}.json"
}

# proclamation: 별도 채널 공표 (운영 알림과 독립적)
# task_id를 "proclamation-{원래_task_id}"로 변환하여 사절의 thread mapping 조회를 의도적으로 실패시킴
# → 운영 스레드가 아닌 채널 직접 메시지로 발송 (사절 코드 수정 불필요)
create_proclamation_message() {
  local task_id="$1"
  local channel="$2"
  local message="$3"
  local msg_id=$(next_msg_id)
  local proc_task_id="proclamation-${task_id}"

  local msg=$(jq -n \
    --arg id "$msg_id" --arg task "$proc_task_id" \
    --arg ch "$channel" --arg ct "$message" \
    '{id: $id, type: "notification", task_id: $task, channel: $ch,
      urgency: "high", content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

  write_to_queue "$BASE_DIR/queue/messages/pending" "$msg_id" "$msg"
}
```

---

## 설정

```yaml
# config/king.yaml

slack:
  default_channel: "dev-eddy"    # fallback (환경변수 SLACK_DEFAULT_CHANNEL 우선)

retry:
  max_attempts: 2
  backoff_seconds: 60

concurrency:
  max_soldiers: 3         # 최대 동시 병사 수

petition:
  enabled: true           # DM LLM 분류 활성화
  model: haiku            # 분류에 사용할 모델
  timeout_seconds: 15     # LLM 호출 타임아웃

intervals:
  event_check_seconds: 10
  result_check_seconds: 10
  schedule_check_seconds: 60
  petition_check_seconds: 5
```

> 라우팅 규칙은 king.yaml에 없다 — `config/generals/*.yaml` 매니페스트에서 동적으로 구성됨.

---

## 장애 대응

| 상황 | 행동 |
|------|------|
| 왕 프로세스 죽음 | 내관이 `state/king/heartbeat` mtime 확인 → tmux 재시작 |
| 왕 프로세스 hang | heartbeat 갱신 안됨 → 내관이 SIGTERM → 재시작 |
| SIGTERM/SIGINT 수신 | 현재 루프 완료 후 graceful shutdown |
| 장군 매니페스트 파싱 실패 | 해당 장군 스킵, 로그 경고, 나머지 정상 동작 |
| 이벤트에 매칭되는 장군 없음 | 로그 경고, 이벤트를 completed로 이동 (폐기) |
| 결과 파일 파싱 실패 | 로그 경고, 다음 주기에 재시도 |
| 체크포인트 파일 없음 (human_response) | 로그 에러, 이벤트를 completed로 이동 |
| needs_human 7일 이상 체류 | 내관이 경고, 왕은 자동 취소 안함, 사절이 리마인더 반복 발송 |
| resources.json 없음 | green으로 간주 (내관 미동작 시 안전 기본값) |
| 재시도 max 초과 | 에스컬레이션: 사절에게 실패 알림, 작업 종료 |

---

## 상태 파일

```
state/king/
├── heartbeat              # 생존 확인 (내관이 mtime 체크)
├── task-seq               # Task ID 시퀀스 (date:seq, 재시작 안전)
├── msg-seq                # Message ID 시퀀스 (date:seq, 재시작 안전)
├── schedule-sent.json     # 스케줄 트리거 기록 (중복 실행 방지)
└── petition-results/        # petition 완료 결과 (event_id.json, 수거 후 삭제)
```

---

## 공통 함수 참조 (`common.sh`)

> `log()`, `get_config()`, `update_heartbeat()`, `start_heartbeat_daemon()`, `stop_heartbeat_daemon()`, `emit_event()`는 `bin/lib/common.sh`에 정의.

---

## 스크립트 위치

```
bin/
├── king.sh                              # 메인 polling loop (thin wrapper)
├── petition-runner.sh                     # tmux 세션에서 LLM 분류 실행
└── lib/king/
    ├── functions.sh                     # 왕 핵심 함수 (이벤트/결과/스케줄 처리)
    ├── petition.sh                        # DM petition (spawn + 결과 수거)
    ├── router.sh                        # 매니페스트 로딩, 라우팅 테이블, find_general
    └── resource-check.sh                # 리소스 + 토큰 상태 확인, can_accept_task
```

```
config/
├── king.yaml                            # 왕 설정 (재시도, 동시성, 인터벌)
└── generals/                            # 장군 매니페스트 (플러거블)
    ├── gen-pr.yaml
    └── gen-briefing.yaml
```

---

## 관련 문서

- [systems/event-types.md](../systems/event-types.md) — 이벤트 타입 카탈로그, 왕의 처리 분기
- [systems/message-passing.md](../systems/message-passing.md) — 이벤트/작업 큐 구조
- [roles/sentinel.md](sentinel.md) — 이벤트 생성자 (파수꾼)
- [roles/envoy.md](envoy.md) — 메시지 소비자 (사절), human_response 이벤트 생성
- [roles/general.md](general.md) — 작업 소비자 (장군) (TBD)

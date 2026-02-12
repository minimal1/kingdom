# 왕 (King)

> 나라의 중심. 파수꾼의 보고를 받아 판단하고, 적합한 장군에게 지시를 내린다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `king` |
| tmux 세션 | `king` |
| 실행 형태 | Bash 스크립트 (polling loop) |
| 수명 | 상주 (Always-on) |
| 리소스 | 경량 (판단은 규칙 기반, LLM 미사용) |

## 책임 — "무엇을, 누구에게"

- **이벤트 소비**: `queue/events/pending/`에서 이벤트를 읽고 처리
- **동적 라우팅**: 장군 매니페스트를 읽어 이벤트 타입 → 장군 매칭 테이블 구성
- **리소스 기반 판단**: 현재 시스템 상태에 따라 작업 수용/보류 결정
- **작업 생성**: task.json을 생성하여 장군의 큐에 배정
- **스케줄 실행**: 장군 매니페스트에 선언된 정기 작업을 시간에 맞춰 트리거
- **결과 처리**: 완료/실패/needs_human 결과에 따른 후속 조치
- **작업 재개**: `slack.human_response` 이벤트 수신 시 체크포인트 기반 작업 재배정

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
  - friday

# 구독: 이 장군이 처리할 수 있는 이벤트 타입
subscribes:
  - github.pr.review_requested
  - github.pr.mentioned
  - github.pr.assigned

# 정기 작업: 외부 이벤트 없이 자체 스케줄로 실행
schedules: []
```

```yaml
# generals/gen-jira/manifest.yaml
name: gen-jira
description: "Jira 티켓 구현 장군"
timeout_seconds: 5400       # 90분 — 코드 구현 + lint + test

cc_plugins:
  - sunday

subscribes:
  - jira.ticket.assigned
  - jira.ticket.updated

schedules: []
```

```yaml
# generals/gen-test/manifest.yaml
name: gen-test
description: "테스트 코드 작성 장군"
timeout_seconds: 3600       # 60분 — 코드 분석 + 테스트 작성 + 실행

cc_plugins:
  - saturday

subscribes: []    # 외부 이벤트 구독 없음 — 순수 스케줄 기반

schedules:
  - name: daily-test
    cron: "0 22 * * 1-5"
    task_type: "daily-test-generation"
    payload:
      description: "Weekday 22:00 test generation"
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
| 처리 능력 | General (gen-pr, gen-jira, ...) | 장군 매니페스트 | 매니페스트 추가만 (왕/센티널 수정 불필요) |

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

EVENT_CHECK_INTERVAL=10    # 10초 — 이벤트 큐 소비
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

    # ── slack.human_response → 작업 재개 경로 ──
    if [ "$event_type" = "slack.human_response" ]; then
      process_human_response "$event" "$event_file"
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

  # 사절에게 thread_start 메시지 생성
  create_thread_start_message "$task_id" "$event"

  # 이벤트를 dispatched로 이동
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Dispatched: $event_id → $general (task: $task_id)"
}
```

### 작업 재개 (human_response)

```bash
process_human_response() {
  local event="$1"
  local event_file="$2"

  local event_id=$(echo "$event" | jq -r '.id')
  local original_task_id=$(echo "$event" | jq -r '.payload.task_id')
  local human_response=$(echo "$event" | jq -r '.payload.human_response')
  local task_id=$(next_task_id)

  # 원래 작업의 체크포인트 확인
  local checkpoint_file="$BASE_DIR/state/results/${original_task_id}-checkpoint.json"
  if [ ! -f "$checkpoint_file" ]; then
    log "[ERROR] [king] Checkpoint not found for task: $original_task_id"
    mv "$event_file" "$BASE_DIR/queue/events/completed/"
    return 1
  fi

  local checkpoint=$(cat "$checkpoint_file")
  local original_general=$(echo "$checkpoint" | jq -r '.target_general')
  local repo=$(echo "$checkpoint" | jq -r '.repo // empty')

  # 재개 작업 생성 (resume 플래그 포함)
  local task=$(jq -n \
    --arg id "$task_id" \
    --arg event_id "$event_id" \
    --arg general "$original_general" \
    --arg original_task "$original_task_id" \
    --arg response "$human_response" \
    --arg repo "$repo" \
    --arg checkpoint_path "$checkpoint_file" \
    '{
      id: $id,
      event_id: $event_id,
      target_general: $general,
      type: "resume",
      repo: $repo,
      payload: {
        original_task_id: $original_task,
        checkpoint_path: $checkpoint_path,
        human_response: $response
      },
      priority: "high",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
  mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
     "$BASE_DIR/queue/tasks/pending/${task_id}.json"

  # 리소스 확인 의도적 생략: 사람이 응답을 대기 중이므로 즉시 재개
  # 사절에게 스레드 업데이트
  create_thread_update_message "$original_task_id" \
    "사람 응답 수신: \"$human_response\" — 작업 재개 중"

  # 이벤트를 dispatched로 이동
  mv "$event_file" "$BASE_DIR/queue/events/dispatched/"

  log "[EVENT] [king] Resumed task: $original_task_id → $original_general (new: $task_id, response: '$human_response')"
}
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
├─ success             │──→ 완료 처리 (아래)
├─ failed              │──→ 에스컬레이션 (장군이 재시도 소진 후)
├─ needs_human         │──→ 사절에게 human_input_request
├─ skipped             │──→ 조용히 완료 처리 (사절 알림 없음)
└──────────────────────┘
```

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
  local event_type=$(echo "$task" | jq -r '.type')

  # 작업 완료 처리
  complete_task "$task_id"

  # 사절에게 완료 알림
  create_notification_message "$task_id" "[complete] $event_type — $summary"

  log "[EVENT] [king] Task completed: $task_id"
}
```

### 실패 처리

> **재시도는 장군 전담**. 왕에게 도달하는 failed는 장군이 max retry를 소진한 최종 실패이다.

```bash
handle_failure() {
  local task_id="$1"
  local result="$2"
  local error=$(echo "$result" | jq -r '.error // "unknown"')

  # 장군이 이미 재시도를 소진한 최종 실패 — 에스컬레이션만 수행
  complete_task "$task_id"
  create_notification_message "$task_id" "[failed] $error"

  log "[ERROR] [king] Task failed permanently: $task_id — $error"
}
```

### needs_human 처리

```bash
handle_needs_human() {
  local task_id="$1"
  local result="$2"
  local question=$(echo "$result" | jq -r '.question')
  local checkpoint_path=$(echo "$result" | jq -r '.checkpoint_path')

  # 사절에게 human_input_request 메시지 생성
  local msg_id=$(next_msg_id)
  local message=$(jq -n \
    --arg id "$msg_id" \
    --arg task_id "$task_id" \
    --arg content "[question] $question" \
    --arg checkpoint "$checkpoint_path" \
    '{
      id: $id,
      type: "human_input_request",
      task_id: $task_id,
      content: $content,
      context: { checkpoint_path: $checkpoint },
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  echo "$message" > "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json"
  mv "$BASE_DIR/queue/messages/pending/.tmp-${msg_id}.json" \
     "$BASE_DIR/queue/messages/pending/${msg_id}.json"

  # 작업 상태는 in_progress 유지 (사람 응답 대기 중)

  log "[EVENT] [king] Needs human input for task: $task_id"
}
```

### skipped 처리

병사가 작업이 자신의 역량 범위 밖이라고 판단한 경우 (예: 담당 영역이 아닌 PR, 이미 머지된 PR 등). 사절 알림 없이 조용히 완료 처리한다.

```bash
handle_skipped() {
  local task_id="$1"
  local result="$2"
  local reason=$(echo "$result" | jq -r '.reason // "out of scope"')

  complete_task "$task_id"
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

# ── M1: cron 매칭 (분 시 일 월 요일, * 와일드카드 지원) ──
cron_matches() {
  local expr="$1"
  local fields=($expr)  # 분 시 일 월 요일

  local now_min=$(date +%-M)
  local now_hour=$(date +%-H)
  local now_dom=$(date +%-d)
  local now_mon=$(date +%-m)
  local now_dow=$(date +%u)  # 1=Mon, 7=Sun

  local now_vals=($now_min $now_hour $now_dom $now_mon $now_dow)

  for i in 0 1 2 3 4; do
    local field="${fields[$i]}"
    local val="${now_vals[$i]}"
    [ "$field" = "*" ] && continue
    [ "$field" != "$val" ] && return 1
  done
  return 0
}

# ── M2: 스케줄 중복 실행 방지 ──
already_triggered_today() {
  local name="$1"
  local today=$(date +%Y-%m-%d)
  local last=$(jq -r --arg n "$name" '.[$n] // ""' "$SCHEDULE_SENT_FILE" 2>/dev/null)
  [ "$last" = "$today" ]
}

mark_triggered_today() {
  local name="$1"
  local today=$(date +%Y-%m-%d)
  local current=$(cat "$SCHEDULE_SENT_FILE" 2>/dev/null || echo '{}')
  echo "$current" | jq --arg n "$name" --arg d "$today" '.[$n] = $d' > "$SCHEDULE_SENT_FILE"
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
    if cron_matches "$cron_expr" && ! already_triggered_today "$sched_name"; then
      local task_type=$(echo "$sched_json" | jq -r '.task_type')
      local payload=$(echo "$sched_json" | jq '.payload')

      # 리소스 확인
      local health=$(get_resource_health)
      if ! can_accept_task "$health" "normal"; then
        log "[WARN] [king] Skipping schedule '$sched_name': resource $health"
        continue
      fi

      # 스케줄 작업 생성
      dispatch_scheduled_task "$general" "$sched_name" "$task_type" "$payload"
      mark_triggered_today "$sched_name"

      log "[EVENT] [king] Scheduled task triggered: $sched_name → $general"
    fi
  done
}

dispatch_scheduled_task() {
  local general="$1"
  local sched_name="$2"
  local task_type="$3"
  local payload="$4"
  local task_id=$(next_task_id)

  local task=$(jq -n \
    --arg id "$task_id" \
    --arg general "$general" \
    --arg type "$task_type" \
    --arg sched "$sched_name" \
    --argjson payload "$payload" \
    '{
      id: $id,
      event_id: ("schedule-" + $sched),
      target_general: $general,
      type: $type,
      repo: null,
      payload: $payload,
      priority: "low",
      retry_count: 0,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }')

  echo "$task" > "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json"
  mv "$BASE_DIR/queue/tasks/pending/.tmp-${task_id}.json" \
     "$BASE_DIR/queue/tasks/pending/${task_id}.json"

  # 스케줄 작업도 사절에게 thread_start 알림 (repo: null — 스케줄 작업은 특정 레포 없음)
  create_thread_start_message "$task_id" \
    "$(jq -n --arg t "$task_type" '{type: ("schedule." + $t), repo: null}')"
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
  local event="$2"
  local event_type=$(echo "$event" | jq -r '.type')
  local repo=$(echo "$event" | jq -r '.repo // ""')
  local msg_id=$(next_msg_id)
  local channel=$(get_config "king" "slack.default_channel")

  local content="[start] ${event_type}"
  [ -n "$repo" ] && content="$content — $repo"

  local message=$(jq -n \
    --arg id "$msg_id" --arg task "$task_id" \
    --arg ch "$channel" --arg ct "$content" \
    '{id: $id, type: "thread_start", task_id: $task, channel: $ch, content: $ct,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), status: "pending"}')

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

# notification: 완료/실패 알림
create_notification_message() {
  local task_id="$1"
  local content="$2"
  local msg_id=$(next_msg_id)
  local channel=$(get_config "king" "slack.default_channel")

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
```

---

## 설정

```yaml
# config/king.yaml

slack:
  default_channel: "dev-eddy"

retry:
  max_attempts: 2
  backoff_seconds: 60

concurrency:
  max_soldiers: 3         # 최대 동시 병사 수

intervals:
  event_check_seconds: 10
  result_check_seconds: 10
  schedule_check_seconds: 60
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
└── schedule-sent.json     # 스케줄 트리거 기록 (중복 실행 방지)
```

---

## 공통 함수 참조 (`common.sh`)

> `log()`, `get_config()`, `update_heartbeat()`, `start_heartbeat_daemon()`, `stop_heartbeat_daemon()`, `emit_event()`는 `bin/lib/common.sh`에 정의.

---

## 스크립트 위치

```
bin/
├── king.sh                              # 메인 polling loop
└── lib/king/
    ├── router.sh                        # 매니페스트 로딩, 라우팅 테이블, find_general
    └── resource-check.sh                # 리소스 상태 확인, can_accept_task
```

```
config/
├── king.yaml                            # 왕 설정 (재시도, 동시성, 인터벌)
└── generals/                            # 장군 매니페스트 (플러거블)
    ├── gen-pr.yaml
    ├── gen-jira.yaml
    └── gen-test.yaml
```

---

## 관련 문서

- [systems/event-types.md](../systems/event-types.md) — 이벤트 타입 카탈로그, 왕의 처리 분기
- [systems/message-passing.md](../systems/message-passing.md) — 이벤트/작업 큐 구조
- [roles/sentinel.md](sentinel.md) — 이벤트 생성자 (파수꾼)
- [roles/envoy.md](envoy.md) — 메시지 소비자 (사절), human_response 이벤트 생성
- [roles/general.md](general.md) — 작업 소비자 (장군) (TBD)

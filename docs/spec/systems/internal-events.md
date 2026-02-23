# 내부 이벤트 카탈로그

> 시스템 내부 동작을 추적하는 구조화된 이벤트의 단일 진실 소스.
> 외부 이벤트([event-types.md](event-types.md))와 분리 — 외부 이벤트는 작업을 트리거하고, 내부 이벤트는 시스템을 관찰한다.

## 외부 이벤트 vs 내부 이벤트

| | 외부 이벤트 | 내부 이벤트 |
|---|---|---|
| **목적** | 작업 트리거 | 시스템 관찰 (observability) |
| **생산자** | 파수꾼, 사절 | 모든 역할 |
| **소비자** | 왕 | 내관 |
| **저장** | `queue/events/` (파일 기반 큐) | `logs/events.log` (JSONL, append-only) |
| **생명주기** | pending → dispatched → completed | 기록 후 불변 (immutable) |
| **정의** | [event-types.md](event-types.md) | 이 문서 |

---

## 공통 스키마

모든 내부 이벤트는 아래 스키마를 따른다:

```json
{
  "ts": "2026-02-07T10:00:00Z",
  "type": "category.action",
  "actor": "역할명 또는 역할-도메인",
  "data": {}
}
```

| 필드 | 타입 | 설명 |
|------|------|------|
| `ts` | string (ISO8601) | 이벤트 발생 시각 |
| `type` | string | `{category}.{action}` 형식 |
| `actor` | string | 이벤트 생산자 (예: `king`, `gen-pr`, `sentinel`, `chamberlain`) |
| `data` | object | 이벤트별 추가 데이터 |

### 발행 함수

```bash
# bin/lib/common.sh

emit_internal_event() {
  local type="$1"     # 필수: "category.action"
  local actor="$2"    # 필수: 이벤트 생산자
  local data="${3:-{}}"  # 선택: 추가 데이터 (생략 시 빈 객체)

  jq -n -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg type "$type" \
    --arg actor "$actor" \
    --argjson data "$data" \
    '{ts: $ts, type: $type, actor: $actor, data: $data}' \
    >> "$BASE_DIR/logs/events.log"
}
```

> `logs/events.log`는 JSONL (줄 단위 JSON). 한 줄 = 한 이벤트. 내관이 tail/poll로 소비한다.

### 구현 상태

> **주의**: 현재 구현에서는 `system.*`, `recovery.*` 카테고리만 실제로 `emit_internal_event()`를 호출한다. `event.*`, `task.*`, `soldier.*`, `message.*` 카테고리는 설계 단계이며, 해당 역할에서 `log()` 호출로 텍스트 로깅만 수행 중이다. 향후 각 역할에 `emit_internal_event()` 호출을 추가하여 내관의 메트릭 집계와 이상 감지를 활성화할 예정이다.

---

## 이벤트 카테고리

### 1. event — 외부 이벤트 감지

파수꾼과 사절이 외부 이벤트를 감지했을 때 발행.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `event.detected` | sentinel | 파수꾼이 GitHub/Jira에서 새 이벤트 감지 | `event_id`, `source`, `event_type` |
| `event.dispatched` | king | 왕이 이벤트를 task로 변환하여 배정 | `event_id`, `task_id`, `target_general` |
| `event.discarded` | king | 매칭 장군 없어 이벤트 폐기 | `event_id`, `event_type`, `reason` |

```json
{"ts": "...", "type": "event.detected", "actor": "sentinel", "data": {"event_id": "evt-github-12345", "source": "github", "event_type": "github.pr.review_requested"}}
{"ts": "...", "type": "event.dispatched", "actor": "king", "data": {"event_id": "evt-github-12345", "task_id": "task-20260207-001", "target_general": "gen-pr"}}
```

### 2. task — 작업 생명주기

왕과 장군이 작업을 처리하는 과정에서 발행.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `task.created` | king | 왕이 task.json 생성 | `task_id`, `event_type`, `target_general`, `priority` |
| `task.started` | general | 장군이 task 처리 시작 (in_progress 이동) | `task_id` |
| `task.completed` | general | 장군이 최종 결과를 왕에게 보고 (success) | `task_id`, `status`, `duration_seconds` |
| `task.failed` | general | 재시도 소진 후 최종 실패 | `task_id`, `error`, `retry_count` |
| `task.needs_human` | general | 사람 판단 필요로 에스컬레이션 | `task_id`, `question` |
| `task.resumed` | king | 사람 응답 받아 작업 재개 | `task_id`, `original_task_id` |

```json
{"ts": "...", "type": "task.created", "actor": "king", "data": {"task_id": "task-20260207-001", "event_type": "github.pr.review_requested", "target_general": "gen-pr", "priority": "normal"}}
{"ts": "...", "type": "task.completed", "actor": "gen-pr", "data": {"task_id": "task-20260207-001", "status": "success", "duration_seconds": 180}}
{"ts": "...", "type": "task.failed", "actor": "gen-pr", "data": {"task_id": "task-20260207-002", "error": "Permission denied", "retry_count": 2}}
```

### 3. soldier — 병사 생명주기

장군이 병사를 관리하는 과정에서 발행.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `soldier.spawned` | general | 장군이 병사 tmux 세션 생성 | `task_id`, `soldier_id` |
| `soldier.completed` | general | 병사가 결과 파일 생성 후 정상 종료 | `task_id`, `soldier_id`, `status` |
| `soldier.timeout` | general | wait_for_soldier가 타임아웃 감지 | `task_id`, `soldier_id`, `timeout_seconds` |
| `soldier.killed` | chamberlain | 내관이 고아 세션 강제 종료 | `soldier_id`, `reason` |

```json
{"ts": "...", "type": "soldier.spawned", "actor": "gen-pr", "data": {"task_id": "task-20260207-001", "soldier_id": "soldier-1707300000-1234"}}
{"ts": "...", "type": "soldier.timeout", "actor": "gen-pr", "data": {"task_id": "task-20260207-002", "soldier_id": "soldier-1707300180-5678", "timeout_seconds": 1800}}
{"ts": "...", "type": "soldier.killed", "actor": "chamberlain", "data": {"soldier_id": "soldier-1707300180-5678", "reason": "orphaned"}}
```

### 4. system — 시스템 상태

내관이 시스템 상태를 감시하는 과정에서 발행.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `system.health_changed` | chamberlain | health 레벨 전환 (예: green → yellow) | `from`, `to`, `reason` |
| `system.heartbeat_missed` | chamberlain | 역할의 heartbeat mtime이 갱신 주기 초과 | `target`, `last_seen`, `threshold_seconds` |
| `system.session_orphaned` | chamberlain | sessions.json에 있으나 tmux 세션 미존재 | `soldier_id`, `task_id` |
| `system.resource_warning` | chamberlain | 리소스 임계값 초과 | `metric`, `value`, `threshold` |
| `system.token_status_changed` | chamberlain | Token status 전환 (ok ↔ warning ↔ critical) | `from`, `to`, `daily_cost_usd` |
| `system.token_budget_reset` | chamberlain | 일일 예산 자정 리셋 | `date`, `previous_cost` |
| `system.startup` | system | 시스템 전체 시작 | `version` |
| `system.shutdown` | system | 시스템 전체 종료 | `reason` |

```json
{"ts": "...", "type": "system.health_changed", "actor": "chamberlain", "data": {"from": "green", "to": "yellow", "reason": "cpu_percent: 72"}}
{"ts": "...", "type": "system.heartbeat_missed", "actor": "chamberlain", "data": {"target": "gen-pr", "last_seen": "2026-02-07T09:55:00Z", "threshold_seconds": 120}}
{"ts": "...", "type": "system.session_orphaned", "actor": "chamberlain", "data": {"soldier_id": "soldier-1707300000-1234", "task_id": "task-20260207-001"}}
{"ts": "...", "type": "system.token_status_changed", "actor": "chamberlain", "data": {"from": "ok", "to": "warning", "daily_cost_usd": "215.40"}}
{"ts": "...", "type": "system.token_budget_reset", "actor": "chamberlain", "data": {"date": "2026-02-08", "previous_cost": "285.60"}}
```

### 5. recovery — 자동 복구

내관이 자동 복구를 수행할 때 발행.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `recovery.session_restarted` | chamberlain | 죽은 필수 세션 재시작 | `target`, `pid` |
| `recovery.session_killed` | chamberlain | 고아/타임아웃 세션 강제 종료 | `soldier_id`, `reason` |
| `recovery.log_rotated` | chamberlain | 로그 파일 .old 로테이션 수행 | `file`, `size_mb` |
| `recovery.files_cleaned` | chamberlain | 보존 기간 경과 파일 삭제 | `deleted_count` |
| `recovery.sessions_cleaned` | chamberlain | sessions.json에서 종료 세션 제거 | `removed_count` |

```json
{"ts": "...", "type": "recovery.session_restarted", "actor": "chamberlain", "data": {"target": "sentinel", "pid": 12345}}
{"ts": "...", "type": "recovery.sessions_cleaned", "actor": "chamberlain", "data": {"removed_count": 3}}
```

### 6. message — 커뮤니케이션

사절 관련 메시지 이벤트.

| type | actor | 발생 시점 | data 필드 |
|------|-------|----------|-----------|
| `message.sent` | envoy | 사절이 Slack 메시지 발송 | `msg_id`, `task_id`, `channel` |
| `message.human_response` | envoy | 사람이 Slack 스레드에 응답 | `task_id`, `thread_ts` |

```json
{"ts": "...", "type": "message.sent", "actor": "envoy", "data": {"msg_id": "msg-20260207-001", "task_id": "task-20260207-001", "channel": "#kingdom"}}
```

---

## 저장 및 관리

### 파일 위치

```
logs/
├── events.log              # 내부 이벤트 (JSONL, 모든 역할이 append)
├── events-YYYYMMDD.log     # 일별 분할 파일 (내관이 매일 00:00 생성)
└── system.log              # 기존 텍스트 로그 (log 함수)
```

### 로테이션 정책

| 항목 | 값 |
|------|-----|
| 최대 크기 | 100MB (초과 시 내관이 .old 로테이션) |
| 일별 분할 | 매일 00:00, `logs/events-YYYYMMDD.log` |
| 보존 기간 | 7일 (이후 삭제, 아카이브 없음) |

### 접근 권한

| 역할 | events.log 접근 |
|------|----------------|
| 파수꾼 | W (append) |
| 왕 | W (append) |
| 장군 | W (append) |
| 병사 | - (직접 접근 안함) |
| 사절 | W (append) |
| 내관 | R/W (읽기 + 로테이션) |

---

## 내관의 소비 방식

내관은 `logs/events.log`를 주기적으로 읽어 다음 작업을 수행한다:

### 메트릭 집계

```bash
# 최근 1시간 task 완료 건수
grep "task.completed" logs/events.log | jq -r '.ts' | ...

# 장군별 평균 작업 시간
grep "task.completed" logs/events.log | jq '{actor, duration: .data.duration_seconds}' | ...
```

집계 결과는 `logs/analysis/stats.json`에 저장.

### 이상 감지

내관은 자체 모니터링 외에, 내부 이벤트 패턴으로도 이상을 감지한다:

| 패턴 | 감지 방법 | 행동 |
|------|----------|------|
| 특정 장군의 연속 실패 | `task.failed`가 같은 actor로 3회 연속 | 사절에 알림 |
| 병사 타임아웃 급증 | `soldier.timeout`이 1시간 내 5회 이상 | 사절에 알림 + health 레벨 조정 |
| 이벤트 체류 | `event.detected` 후 30분 내 `event.dispatched` 없음 | 왕 heartbeat 확인 |

### 일일 리포트

내관은 매일 내부 이벤트를 집계하여 일일 리포트를 사절에게 전달:

```json
{
  "type": "daily_report",
  "date": "2026-02-07",
  "tasks": {
    "created": 15,
    "completed": 12,
    "failed": 2,
    "needs_human": 1
  },
  "soldiers": {
    "spawned": 14,
    "timeout": 1
  },
  "avg_duration_seconds": {
    "gen-pr": 420,
    "gen-briefing": 60
  }
}
```

---

## 확장 시 가이드

### 새 내부 이벤트 추가

1. 이 문서에 이벤트 타입 추가 (카테고리, type, data 필드 정의)
2. 해당 역할의 코드에서 `emit_internal_event` 호출 추가
3. 내관이 새 이벤트를 활용해야 하면 chamberlain.md에 소비 로직 추가

### 새 카테고리 추가

1. 이 문서에 카테고리 섹션 추가
2. `{category}.{action}` 네이밍 규칙 준수
3. 기존 카테고리와 의미 중복 없도록 주의

---

## 관련 문서

- [event-types.md](event-types.md) — 외부 이벤트 (작업 트리거용)
- [roles/chamberlain.md](../roles/chamberlain.md) — 내부 이벤트 소비자, 시스템 모니터
- [roles/king.md](../roles/king.md) — task 이벤트 생산자
- [roles/general.md](../roles/general.md) — soldier/task 이벤트 생산자
- [roles/sentinel.md](../roles/sentinel.md) — event.detected 생산자

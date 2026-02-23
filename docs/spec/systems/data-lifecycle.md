# 데이터 생명주기

> 생성된 모든 데이터는 정해진 수명이 있다. 내관이 정리한다.

## 생명주기 전체 흐름

```
 생성          활성 처리        완료 보관         삭제
─────         ─────────       ──────────       ─────
                                 N일
                              ◄────────►

이벤트   pending → dispatched → completed ────────────→ 삭제 (7일)
작업     pending → in_progress → completed ───────────→ 삭제 (7일)
결과     생성 ────────────────→ results/  ────────────→ 삭제 (7일)
메시지   pending → sent ──────────────────────────────→ 삭제 (7일)
프롬프트 생성 ────────────────→ prompts/  ────────────→ 삭제 (3일)
세션로그 생성 ────────────────→ sessions/ ────────────→ 삭제 (7일)
중복인덱스 생성 ──────────────────────────────────────→ 삭제 (30일)
스레드매핑 항목 추가 ─→ 작업 완료 시 항목 제거 (사절 자체 관리)
응답대기  항목 추가 ─→ 응답 수신 시 항목 제거 (사절 자체 관리)
CLAUDE.md  config에서 복사 ─→ workspace에 상주 (병사 실행 시 자동 로드)
.kingdom-task.json  spawn-soldier.sh 생성 ─→ workspace에 상주 (다음 작업 시 덮어쓰기)
```

> 아카이브 단계 없음. 보존 기간 경과 후 바로 삭제한다. 일일 리포트가 핵심 메트릭을 이미 집계하므로 원본의 장기 보존이 불필요.

## 데이터별 상세

### 이벤트 (`queue/events/`)

| 상태 | 디렉토리 | 생성자 | 소비자 | 보관 기간 |
|------|---------|--------|--------|----------|
| `pending` | `queue/events/pending/` | 파수꾼 | 왕 | 왕이 소비할 때까지 |
| `dispatched` | `queue/events/dispatched/` | 왕 (mv) | 왕 (결과 확인 후) | 작업 완료까지 |
| `completed` | `queue/events/completed/` | 왕 (mv) | - | **7일 후 삭제** |

**상태 전이**:
```
pending ──왕이 읽고 task 생성──→ dispatched ──작업 완료──→ completed ──7일──→ 삭제
                                                    ↘ failed (재시도 후에도 실패) ──→ completed와 동일
```

### 작업 (`queue/tasks/`)

| 상태 | 디렉토리 | 생성자 | 소비자 | 보관 기간 |
|------|---------|--------|--------|----------|
| `pending` | `queue/tasks/pending/` | 왕 | 장군 | 장군이 소비할 때까지 |
| `in_progress` | `queue/tasks/in_progress/` | 장군 (mv) | 장군 | 작업 완료까지 |
| `completed` | `queue/tasks/completed/` | 장군 (mv) | - | **7일 후 삭제** |

### 결과 (`state/results/`)

| 위치 | 생성자 | 참조자 | 보관 기간 |
|------|--------|--------|----------|
| `state/results/{task-id}.json` | 장군 | 왕 | **7일 후 삭제** |
| `state/results/{task-id}-raw.json` | 병사 | 장군 | **7일 후 삭제** |
| `state/results/{task-id}-soldier-id` | 병사 | 장군, 내관 | **7일 후 삭제** |
| `state/results/{task-id}-session-id` | 병사 | 장군 (resume) | **7일 후 삭제** |

결과 파일은 Layer 2 메모리 역할을 겸한다. 장군이 이전 작업의 결과를 참고할 수 있는 기간이 7일.

### 프롬프트 (`state/prompts/`)

| 위치 | 생성자 | 소비자 | 보관 기간 |
|------|--------|--------|----------|
| `state/prompts/{task-id}.md` | 장군 (build_prompt) | 병사 | **3일 후 삭제** |

프롬프트는 병사가 즉시 소비하므로 보존 필요성이 낮다. 디버깅용으로 3일 유지.

### 메시지 (`queue/messages/`)

| 상태 | 디렉토리 | 생성자 | 소비자 | 보관 기간 |
|------|---------|--------|--------|----------|
| `pending` | `queue/messages/pending/` | 왕/장군/내관 | 사절 | 사절이 전송할 때까지 |
| `sent` | `queue/messages/sent/` | 사절 (mv) | - | **7일 후 삭제** |

메시지는 Slack에 이미 전송되었으므로 장기 보존 불필요.

### 로그 (`logs/`)

| 위치 | 생성자 | 보관 기간 |
|------|--------|----------|
| `logs/system.log` | 모든 역할 (log 함수) | 상주 (100MB 초과 시 .old 로테이션) |
| `logs/system.log.old` | 내관 (rotate) | **7일 후 삭제** |
| `logs/events.log` | 모든 역할 (emit_internal_event) | 상주 (매일 00:00 일별 분할) |
| `logs/events-YYYYMMDD.log` | 내관 (rotate) | **7일 후 삭제** |
| `logs/tasks.log` | 왕/장군 (작업 로그) | 상주 (100MB 초과 시 .old 로테이션) |
| `logs/tasks.log.old` | 내관 (rotate) | **7일 후 삭제** |
| `logs/metrics.log` | 내관 (메트릭 수집) | 상주 (100MB 초과 시 .old 로테이션) |
| `logs/metrics.log.old` | 내관 (rotate) | **7일 후 삭제** |
| `logs/sessions/{soldier-id}.json` | 병사 (stdout JSON) | **7일 후 삭제** |
| `logs/sessions/{soldier-id}.err` | 병사 (stderr) | **7일 후 삭제** |

### 사절 상태 (`state/envoy/`)

| 파일 | 생성자 | 정리 주체 | 정리 시점 |
|------|--------|----------|----------|
| `thread-mappings.json` | 사절 (thread_start 처리 시) | 사절 | **작업 완료/실패 시 해당 항목 제거** |
| `awaiting-responses.json` | 사절 (human_input_request 처리 시) | 사절 | **응답 수신 시 해당 항목 제거** |
| `report-sent.json` | 사절 (리포트 발송 시) | - | 덮어쓰기 (최근 발송일만 기록, 정리 불필요) |
| `heartbeat` | 사절 (매 루프) | - | 덮어쓰기 (정리 불필요) |

`thread-mappings`과 `awaiting-responses`는 JSON 파일 내부의 항목 단위로 관리된다 (파일 자체는 삭제하지 않음).
내관의 정리 대상이 아니며, 사절이 자체적으로 항목을 추가/제거한다.

> 안전장치: 내관이 `thread-mappings`에 7일 이상 된 항목이 있으면 경고 로그 기록 (작업이 완료되었는데 매핑이 남아있는 이상 상태).

### 왕 상태 (`state/king/`)

| 파일 | 생성자 | 정리 주체 | 정리 시점 |
|------|--------|----------|----------|
| `heartbeat` | 왕 (매 루프) | - | 덮어쓰기 (정리 불필요) |
| `task-seq` | 왕 (task ID 생성 시) | - | 덮어쓰기 (date:seq, 정리 불필요) |
| `msg-seq` | 왕 (message ID 생성 시) | - | 덮어쓰기 (date:seq, 정리 불필요) |
| `schedule-sent.json` | 왕 (스케줄 트리거 시) | - | 덮어쓰기 (당일 트리거 기록만 유지, 정리 불필요) |

> 왕이 매 루프마다 heartbeat를 갱신. 내관이 mtime을 확인하여 생존 여부 판단.

### Workspace 컨텍스트 파일

| 파일 | 생성자 | 소비자 | 정리 시점 |
|------|--------|--------|----------|
| `workspace/{general}/CLAUDE.md` | `spawn-soldier.sh` (config/workspace-claude.md에서 복사) | 병사 (CC 자동 로드) | 덮어쓰기 (정리 불필요) |
| `workspace/{general}/.kingdom-task.json` | `spawn-soldier.sh` | 병사 (task_id, result_path 읽기) | 다음 작업 시 덮어쓰기 (정리 불필요) |

`CLAUDE.md`는 병사에게 결과 보고 방식(status, summary 등)을 지시하며, `.kingdom-task.json`은 task_id와 result_path를 전달한다.

### 중복 방지 인덱스 (`state/sentinel/seen/`)

| 위치 | 생성자 | 삭제 시점 |
|------|--------|----------|
| `state/sentinel/seen/{event-id}` | 파수꾼 (emit_event) | **30일 후 내관이 삭제** |

빈 파일(0 bytes)로 이벤트 ID만 기록. 수만 개여도 디스크 영향 미미.

---

## 중복 방지 메커니즘

이벤트가 completed에서 삭제된 후에도 재감지를 방지하기 위한 장치:

### GitHub

ETag 기반 폴링이므로 **API 레벨에서 중복이 방지됨**. 이전에 본 notification을 다시 반환하지 않음.

### Jira

`last_check` timestamp 기반이므로 경계 시간에 중복 가능. 이벤트 ID에 `updated` timestamp가 포함되어 자연스럽게 동일 변경은 같은 ID 생성.

### 공통: seen 인덱스

기본 `emit_event()`(common.sh)는 큐 적재만 수행하며, seen 마킹은 포함하지 않는다. 파수꾼의 `sentinel_emit_event()`(watcher-common.sh)가 래퍼로 seen 마킹을 추가한다.

```bash
# bin/lib/common.sh — 기본 emit_event (seen 마킹 없음)
emit_event() {
  local event_json="$1"
  local event_id=$(echo "$event_json" | jq -r '.id')

  # 이벤트 큐에 적재 (Write-then-Rename)
  echo "$event_json" > "queue/events/pending/.tmp-${event_id}.json"
  mv "queue/events/pending/.tmp-${event_id}.json" "queue/events/pending/${event_id}.json"

  log "[EVENT] Emitted: $event_id"
}

# bin/lib/sentinel/watcher-common.sh — 파수꾼 전용 래퍼 (seen 마킹 추가)
sentinel_emit_event() {
  local event_json="$1"
  local event_id=$(echo "$event_json" | jq -r '.id')

  emit_event "$event_json"

  # 중복 방지 인덱스 마킹 (빈 파일)
  touch "state/sentinel/seen/${event_id}"
}

# is_duplicate() — 활성 큐 + seen 인덱스 확인
is_duplicate() {
  local event_id="$1"
  [ -f "queue/events/pending/${event_id}.json" ] ||
  [ -f "queue/events/dispatched/${event_id}.json" ] ||
  [ -f "state/sentinel/seen/${event_id}" ]
}
```

`is_duplicate()`가 `completed/` 디렉토리를 더 이상 확인하지 않는다. 대신 경량 인덱스(`seen/`)를 사용.

---

## 내관의 정리 설정

내관의 `cleanup_expired_files` 함수가 매일 03:00에 실행한다. 설정은 `chamberlain.yaml`의 `retention` 섹션.

```yaml
# config/chamberlain.yaml — retention 섹션
retention:
  log_max_mb: 100               # 로그 파일 크기 상한 (초과 시 .old 로테이션)
  logs_days: 7                  # .old 파일, events-*.log 보존 기간
  results_days: 7               # state/results/ 파일 보존 기간
  queue_days: 7                 # queue/*/completed/, messages/sent/ 보존 기간
  prompts_days: 3               # state/prompts/ 임시 프롬프트 보존 기간
  session_logs_days: 7          # logs/sessions/ 병사 로그 보존 기간
  seen_days: 30                 # state/sentinel/seen/ 중복 방지 인덱스 보존 기간
```

상세 구현: [roles/chamberlain.md — cleanup_expired_files](../roles/chamberlain.md)

---

## 디스크 사용량 추정

| 데이터 | 파일 크기 | 일 생성량 | 7일 누적 |
|--------|---------|----------|---------|
| 이벤트 | ~1KB | ~20개 | 140KB |
| 작업 | ~1KB | ~15개 | 105KB |
| 결과 | ~2KB | ~15개 | 210KB |
| 메시지 | ~0.5KB | ~30개 | 105KB |
| 프롬프트 | ~5KB | ~15개 | 225KB |
| 세션 로그 | ~50KB | ~15개 | 5.25MB |
| 중복 인덱스 | 0 bytes | ~20개 | inode만 |
| **합계** | | | **~6MB** |

100GB SSD에서 데이터 파일 누적은 무시할 수준. **로그 파일**(system.log, events.log)이 디스크의 주적이며, 100MB 크기 제한 + 7일 보존으로 관리.

---

## 관련 문서

- [roles/sentinel.md](../roles/sentinel.md) — 이벤트 생성, 중복 방지
- [roles/chamberlain.md](../roles/chamberlain.md) — 정리 실행, 모니터링
- [systems/message-passing.md](message-passing.md) — 큐 구조, 상태 전이
- [systems/memory.md](memory.md) — Layer 2 메모리 (결과 파일 7일 보관)

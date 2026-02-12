# 병사 (Soldier)

> 장군의 명을 받아, 실제 코드 작업을 수행하고 결과를 보고한다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `soldier` |
| tmux 세션 | `soldier-{id}` |
| 실행 형태 | Claude Code `-p` (headless, 일회성) |
| 수명 | 일회성 (작업 완료 후 종료) |
| 리소스 | 작업 중 높음 (CC API 호출) |
| 최대 동시 수 | 3 (초기 설정, `king.yaml`의 `concurrency.max_soldiers`) |

## 책임

- 장군이 조립한 프롬프트를 받아 실행
- 코드 수정, 테스트 실행, PR 생성 등 실제 작업 수행
- 결과를 Write 도구로 `state/results/{task-id}-raw.json`에 직접 저장
- 새로 발견한 패턴이 있으면 결과의 `memory_updates` 배열에 포함
  - 장군이 `update_memory` 함수로 `learned-patterns.md`에 반영

## 하지 않는 것

- 작업 선택이나 판단 (장군이 결정)
- 다른 병사와 직접 소통 (장군을 통해서만)
- 시스템 설정 변경
- 재시도 (장군의 책임)

## 생명주기

```
┌──────────────┐
│ 장군이 생성    │  spawn_soldier "$task_id" "$prompt_file" "$work_dir"
└──────┬───────┘
       ▼
┌──────────────┐
│ tmux 세션     │  tmux new-session -d -s soldier-{id}
│ 생성          │  (장군의 spawn_soldier가 sessions.json에 등록)
└──────┬───────┘
       ▼
┌──────────────┐
│ claude -p     │  cd workspace → CC Plugin 자동 로드
│ 실행          │
└──────┬───────┘
       ▼
┌──────────────┐
│ 작업 수행     │  코드 수정, 테스트, PR 등 (CC Plugin 활용)
└──────┬───────┘
       ▼
┌──────────────┐
│ 결과 저장     │  Write 도구로 state/results/{task-id}-raw.json 생성
└──────┬───────┘
       ▼
┌──────────────┐
│ 세션 종료     │  tmux wait-for -S → 장군이 감지
│               │  장군의 wait_for_soldier가 tmux 세션 정리
│               │  내관이 주기적으로 sessions.json에서 종료 세션 제거
└──────────────┘
```

## 실행 방식

### bin/spawn-soldier.sh

```bash
#!/bin/bash
# bin/spawn-soldier.sh — 병사 tmux 세션 생성
# 호출: 장군의 spawn_soldier() 함수에서 호출
# 역할: 컨텍스트 파일 생성 + tmux 세션 생성 + soldier-id 파일 기록
# 세션 등록(sessions.json)은 장군의 spawn_soldier()가 수행 (레이어드 구조)

source "$BASE_DIR/bin/lib/common.sh"

TASK_ID="$1"
PROMPT_FILE="$2"
WORK_DIR="$3"  # 장군의 workspace 경로
SOLDIER_ID="soldier-$(date +%s)-$$"
RAW_FILE="$BASE_DIR/state/results/${TASK_ID}-raw.json"

# ── Pre-flight Checks ──
if ! command -v claude &> /dev/null; then
  log "[ERROR] [soldier] claude command not found"
  exit 1
fi

# ── Context File ──
# .kingdom-task.json을 workspace에 생성 (CLAUDE.md가 병사에게 이 파일을 읽으라고 지시)
jq -n \
  --arg task_id "$TASK_ID" \
  --arg result_path "$RAW_FILE" \
  '{task_id: $task_id, result_path: $result_path}' \
  > "$WORK_DIR/.kingdom-task.json"

# ── Session Creation ──
# workspace에서 실행 → .claude/plugins.json이 CC Plugin을 자동 로드
# workspace/CLAUDE.md가 자동 로드되어 결과 보고 방식을 지시
# --dangerously-skip-permissions: 자동화 환경에서 모든 도구 승인 없이 실행 (리스크 인지)
# stdout+stderr → 로그 파일 (병사는 Write 도구로 결과를 직접 생성)
if ! tmux new-session -d -s "$SOLDIER_ID" \
  "cd '$WORK_DIR' && claude -p \
    --dangerously-skip-permissions \
    < '$PROMPT_FILE' \
    > '$BASE_DIR/logs/sessions/${SOLDIER_ID}.log' 2>&1; \
   tmux wait-for -S ${SOLDIER_ID}-done"; then
  log "[ERROR] [soldier] Failed to create tmux session: $SOLDIER_ID"
  exit 1
fi

# soldier_id를 파일에 기록 (장군의 spawn_soldier가 읽어 세션 등록, wait_for_soldier가 timeout 시 kill용)
echo "$SOLDIER_ID" > "$BASE_DIR/state/results/${TASK_ID}-soldier-id"

log "[SYSTEM] [soldier] Spawned: $SOLDIER_ID for task: $TASK_ID in $WORK_DIR"
```

> CC Plugin은 프롬프트에서 지정하지 않는다. `cd '$WORK_DIR'`로 장군의 workspace에서 실행되면 `.claude/plugins.json`을 통해 자동 로드된다. 상세: [roles/general.md — CC Plugin 통합](general.md#cc-plugin-통합)

## 프롬프트 구조

병사가 받는 프롬프트는 장군의 `build_prompt` 함수가 조립한다. CC Plugin 관련 지시는 포함하지 않는다 — workspace의 `.claude/plugins.json`이 자동 제공.

실제 프롬프트는 다음 순서로 구성된다:

```
{장군별 프롬프트 템플릿}
  - 도메인별 지시사항 (PR 리뷰, Jira 구현 등)
  - 작업 유형별 워크플로우
  - CC Plugin 사용법 (예: friday의 /review-pr 커맨드)
  - 플레이스홀더: {{TASK_ID}}, {{TASK_TYPE}}, {{REPO}}

## 이번 작업 (payload)
```json
{task.json의 payload — 이벤트 상세 정보}
```

## 도메인 메모리
{장군의 도메인 메모리에서 발췌 — load_domain_memory}
{예: "이 레포는 barrel export를 선호하지 않음"}

## 레포지토리 컨텍스트
{레포별 특수 사항 — load_repo_memory}
{예: "TypeScript strict mode, pnpm 사용"}
```

> **출력 요구사항은 프롬프트에 포함하지 않는다.** `workspace/CLAUDE.md`가 결과 스키마와 `.kingdom-task.json` 컨텍스트 파일 읽기를 지시하므로, 프롬프트 템플릿에서 별도로 출력 형식을 지시할 필요 없다. 상세: [roles/general.md — build_prompt](general.md#build_prompt)

## 결과 스키마

병사는 `workspace/CLAUDE.md`의 지시에 따라 `.kingdom-task.json`에서 `task_id`와 `result_path`를 읽고, Write 도구로 `state/results/{task-id}-raw.json`에 직접 결과를 저장한다. stdout+stderr는 `logs/sessions/{soldier-id}.log`로 캡처되어 디버깅용으로 보존된다.

`status` 필드에 따라 필수 필드가 다르다:

### success

```json
{
  "task_id": "task-20260207-001",
  "soldier_id": "soldier-1707300000-1234",
  "status": "success",
  "summary": "PR #1234에 대해 5개 코멘트 작성 완료",
  "details": {
    "files_reviewed": 12,
    "comments_posted": 5,
    "issues_found": ["unused-import", "missing-error-handling", "type-mismatch"]
  },
  "metrics": {
    "duration_seconds": 180,
    "tokens_used": 45000
  },
  "memory_updates": [
    "이 레포는 barrel export를 선호하지 않음"
  ],
  "completed_at": "2026-02-07T10:04:00Z"
}
```

### failed

```json
{
  "task_id": "task-20260207-002",
  "soldier_id": "soldier-1707300180-5678",
  "status": "failed",
  "error": "Git push failed: Permission denied (publickey)",
  "summary": "PR 생성 실패 — 레포 접근 권한 문제",
  "completed_at": "2026-02-07T10:05:00Z"
}
```

### needs_human

```json
{
  "task_id": "task-20260207-003",
  "soldier_id": "soldier-1707300360-9012",
  "status": "needs_human",
  "question": "이 PR의 breaking change 여부를 확인해야 합니다. major version bump가 필요한가요?",
  "summary": "사람의 판단 필요 — breaking change 여부",
  "completed_at": "2026-02-07T10:06:00Z"
}
```

### skipped

```json
{
  "task_id": "task-20260207-004",
  "soldier_id": "soldier-1707300420-3456",
  "status": "skipped",
  "summary": "이미 머지된 PR — 리뷰 불필요",
  "reason": "PR #1234 is already merged",
  "completed_at": "2026-02-07T10:07:00Z"
}
```

### 필드 참조표

| 필드 | success | failed | needs_human | skipped | 참조하는 주체 |
|------|---------|--------|-------------|---------|-------------|
| `task_id` | 필수 | 필수 | 필수 | 필수 | 장군, 왕 |
| `soldier_id` | 필수 | 선택 | 선택 | 선택 | 로깅용 |
| `status` | 필수 | 필수 | 필수 | 필수 | 장군 재시도 루프 |
| `summary` | 필수 | 필수 | 필수 | 필수 | 왕 → 사절 알림 |
| `reason` | - | - | - | 선택 | 왕 (건너뛴 이유 로깅) |
| `error` | - | 필수 | - | - | 장군 재시도 판단, 왕 에스컬레이션 |
| `question` | - | - | 필수 | - | 왕 → 사절 → 사람 |
| `details` | 선택 | - | - | - | 로깅, 메트릭 |
| `metrics` | 선택 | - | - | - | 내관 메트릭 수집 |
| `memory_updates` | 선택 | - | - | - | 장군 `update_memory` |
| `completed_at` | 필수 | 필수 | 필수 | 필수 | 로깅, 메트릭 |

> **결과 파일 작성 주체**: 정상 시 병사가 Write 도구로, timeout 시 장군의 `wait_for_soldier`가 직접 생성. 상세: [roles/general.md — wait_for_soldier](general.md#spawn_soldier--wait_for_soldier)

## 제한사항

- **동시 실행 상한**: 3 (config에서 조정 가능)
- **실행 시간 상한**: 장군 매니페스트의 `timeout_seconds` (기본 1800초)
  - gen-pr: 1800초 (30분) — 리뷰는 읽기 위주
  - gen-jira: 5400초 (90분) — 코드 구현 + lint + test
  - gen-test: 3600초 (60분) — 코드 분석 + 테스트 작성 + 실행
  - 장군의 `wait_for_soldier`가 감시
- **허용 도구**: 제한 없음 (`--dangerously-skip-permissions`)
  - CC Plugin이 제공하는 도구(Skill, Task 등)도 자유롭게 사용 가능
  - 도메인별 특수 도구는 CC Plugin을 통해 제공 (예: friday의 리뷰 커맨드)

## sessions.json

활성 병사 세션의 시스템 공유 레지스트리. 왕의 동시 병사 수 제어와 내관의 고아 세션 감지에 사용.

### 스키마

```json
[
  {"id": "soldier-1707300000-1234", "task_id": "task-20260207-001", "started_at": "2026-02-07T10:00:00Z"},
  {"id": "soldier-1707300180-5678", "task_id": "task-20260207-002", "started_at": "2026-02-07T10:03:00Z"}
]
```

JSON 배열. 장군이 `jq '. + [<entry>]'`로 추가하고, 내관이 종료 세션을 필터링하여 갱신한다.

### 생명주기

| 단계 | 담당 | 동작 |
|------|------|------|
| 등록 | 장군 (`spawn_soldier`) | `bin/spawn-soldier.sh` 호출 후 append |
| 활용 | 왕 (`max_soldiers` 체크) | `jq 'length'`로 활성 병사 수 확인 |
| 활용 | 내관 (`session-checker.sh`) | `tmux has-session`으로 생존 여부 확인 |
| 정리 | 내관 (`session-checker.sh`) | 종료된 세션 행 제거 (주기적) |

> 장군은 등록만 하고 제거하지 않는다. 내관이 `tmux has-session -t $id`로 종료 여부를 확인하고 정리한다. 장군 crash로 인한 고아 세션도 동일하게 내관이 감지 + 정리.

## 장애 대응

| 상황 | 병사의 행동 | 장군의 처리 |
|------|-----------|-----------|
| 정상 완료 | Write 도구로 -raw.json 생성 | raw 파일 읽기 → status별 분기 |
| CC API 에러 | 에러를 포함한 -raw.json 생성 (`status: failed`) | 재시도 루프 → max 초과 시 최종 실패 |
| 타임아웃 (30분 초과) | (없음 — 장군이 강제 종료) | tmux kill-session → failed 결과 직접 생성 |
| 세션 크래시 | (없음 — 결과 미생성) | raw 파일 미존재 → 타임아웃과 동일 처리 |
| 장군 crash | (병사는 계속 실행) | 내관이 고아 세션 감지 → tmux kill-session |

## 스크립트 위치

- `bin/spawn-soldier.sh` — 병사 생성 + 실행

## 관련 문서

- [roles/general.md](general.md) — 장군 스펙 (spawn_soldier, wait_for_soldier, build_prompt)
- [roles/king.md](king.md) — 왕 스펙 (max_soldiers 동시성 제어)
- [systems/filesystem.md](../systems/filesystem.md) — 파일 시스템 구조 (results/, sessions.json)

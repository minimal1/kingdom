# 장군 (General)

> 도메인별 작업 실행을 담당하는 공통 런타임 계층.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `general` |
| tmux 세션 | `gen-{domain}` |
| 실행 형태 | Bash loop + `claude -p` |
| 수명 | 상주 |
| 책임 축 | task claim, workspace, prompt, soldier, result |

관련 파일:

- [bin/lib/general/common.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/common.sh)
- [bin/lib/general/task-selection.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/task-selection.sh)
- [bin/lib/general/workspace.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/workspace.sh)
- [bin/lib/general/memory.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/memory.sh)
- [bin/lib/general/soldier-lifecycle.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/soldier-lifecycle.sh)
- [bin/lib/general/results.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/results.sh)
- [bin/lib/general/main-loop.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/main-loop.sh)
- [bin/lib/general/prompt-builder.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/prompt-builder.sh)

## 책임

- 자신의 도메인 task를 `queue/tasks/pending/`에서 선택
- `in_progress/`로 이동해 점유
- workspace 준비
- prompt 조립
- 병사 실행 및 대기
- 메모리 갱신
- 최종 결과를 왕에게 보고

## 비책임

- 이벤트 라우팅
- Slack 전송
- 전체 동시성 관리

## 모듈 구조

장군 공통 로직은 하나의 큰 파일이 아니라 보조 모듈로 나뉜다.

- `task-selection.sh`: `pick_next_task()`
- `workspace.sh`: `ensure_workspace()`, `sync_general_agents()`
- `memory.sh`: `load_domain_memory()`, `load_repo_memory()`, `update_memory()`
- `soldier-lifecycle.sh`: `spawn_soldier()`, `wait_for_soldier()`
- `results.sh`: `report_to_king()`, `escalate_to_king()`
- `main-loop.sh`: `main_loop()`

## 메인 루프

`main_loop()`의 실제 흐름:

1. `pick_next_task()`로 자기 도메인 task 선택
2. `in_progress/`로 이동
3. `ensure_workspace()` 실행
4. `build_prompt()`로 prompt 생성
5. `spawn_soldier()` 실행
6. `wait_for_soldier()`로 raw result 대기
7. 상태별 분기 후 `report_to_king()` 또는 `escalate_to_king()`

장군은 `task.started` 내부 이벤트를 발행한다.

## workspace

`ensure_workspace()`가 담당하는 것:

- 작업 디렉토리 생성
- `cc_plugins` 검증
- 필요한 repo clone/fetch
- 최종 작업 디렉토리 반환

repo가 있으면 `workspace/{general}/{repo-basename}`를 반환하고, 없으면 `workspace/{general}`를 반환한다.

## 메모리

장군 메모리는 두 층으로 나뉜다.

- 도메인 메모리: `memory/generals/{general}/*.md`
- 레포 메모리: `memory/generals/{general}/repo-{owner-repo}.md`

병사가 `memory_updates[]`를 남기면 `update_memory()`가 `learned-patterns.md`에 append한다.

## 병사 실행

`spawn_soldier()`는 pre-flight 검증 후 [bin/spawn-soldier.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/spawn-soldier.sh)를 호출한다.

주요 특징:

- prompt/workdir 존재 검증
- `resume` task면 기존 `session_id` 전달
- soldier id를 읽어 `sessions.json`에 등록
- `soldier.spawned` 내부 이벤트 발행

`wait_for_soldier()`는 다음을 처리한다.

- raw result 파일 대기
- tmux 세션 생존 확인
- heartbeat 기반 timeout extension
- timeout 또는 조기 종료 시 synthetic result 생성
- `soldier.timeout` 또는 `soldier.killed` 내부 이벤트 발행

## 결과 모델

장군은 raw result와 final result를 분리한다.

| 파일 | 용도 |
|------|------|
| `state/results/{task-id}-raw.json` | 병사 출력 |
| `state/results/{task-id}.json` | 왕이 소비하는 최종 결과 |
| `state/results/{task-id}-checkpoint.json` | `needs_human` 재개용 상태 |

최종 상태:

- `success`
- `failed`
- `needs_human`
- `skipped`

`killed`는 장군이 직접 최종 보고하지 않고, `wait_for_soldier()`가 만든 synthetic result를 왕이 재시도 정책으로 처리한다.

## `needs_human`

`escalate_to_king()`는 checkpoint를 저장하고 최종 result에 `checkpoint_path`를 포함한다. 왕은 이를 읽어 질문 메시지를 만들고, 이후 사람 응답을 `resume` task로 변환한다.

## prompt

prompt는 [bin/lib/general/prompt-builder.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/prompt-builder.sh)에서 조립한다.

입력 요소:

- task json
- general template
- payload 치환
- domain/repo memory

공통 원칙과 결과 스키마는 `workspace/CLAUDE.md`로 전달되고, prompt 자체는 작업 지시에 집중한다.

## 설정/매니페스트

장군 패키지는 다음을 가진다.

- `manifest.yaml`
- `prompt.md`
- `install.sh`
- `README.md`
- 선택: `general-claude.md`

매니페스트 스키마는 [schemas/general-manifest.schema.json](/Users/eddy/Documents/worktree/lab/lil-eddy/schemas/general-manifest.schema.json)이다.

주요 필드:

- `name`
- `description`
- `timeout_seconds`
- `cc_plugins`
- `default_repo`
- `subscribes`
- `schedules`

## 테스트

- [tests/lib/general/test_common.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/general/test_common.sh)
- [tests/lib/general/test_prompt_builder.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/general/test_prompt_builder.sh)
- [tests/test_spawn_soldier.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/test_spawn_soldier.sh)
- [tests/integration/test_task_to_result.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/integration/test_task_to_result.sh)

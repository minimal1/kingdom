# 병사 (Soldier)

> 선택된 실행 엔진으로 실제 작업을 수행하는 일회성 세션.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `soldier` |
| tmux 세션 | `soldier-{id}` |
| 실행 엔진 | `claude` 또는 `codex` |
| 수명 | 일회성 |
| 결과 계약 | `schemas/soldier-result.schema.json` |

핵심 파일:

- [bin/spawn-soldier.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/spawn-soldier.sh)
- [bin/lib/runtime/engine.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/runtime/engine.sh)
- [config/workspace-claude.md](/Users/eddy/Documents/worktree/lab/lil-eddy/config/workspace-claude.md)

## 책임

- prompt 실행
- 코드 수정/테스트/도구 사용
- `KINGDOM_RESULT_PATH`에 raw result 저장
- 가능하면 resume token(session id) 기록

## 실행 모델

`bin/spawn-soldier.sh`는 다음을 담당한다.

1. runtime engine 결정 (`config/system.yaml`)
2. tmux 세션 생성
3. env vars 주입
4. engine별 command 조립
5. stdout/stderr/session token 파일 기록

## 엔진별 차이

### Claude

- 실행: `claude -p`
- JSON stdout 사용
- `--resume SESSION_ID` 지원
- workspace의 `CLAUDE.md`를 사용

### Codex

- 실행: `codex exec --json`
- workspace의 `AGENTS.md`를 사용
- `codex exec resume` 기반 best-effort resume 지원
- session token은 stdout JSONL에서 가능하면 추출

## instruction 파일

runtime은 공통 instruction source를 다음 파일로 배치한다.

- root workspace: `CLAUDE.md`, `AGENTS.md`
- general workspace: `CLAUDE.md`, `AGENTS.md`

또한 package의 `agents/`, `skills/`가 있으면 다음 경로로 동기화한다.

- `.claude/agents`, `.codex/agents`
- `.claude/skills`, `.codex/skills`

## 결과 계약

병사는 `state/results/{task-id}-raw.json`에 결과를 쓴다.

필수 필드:

- `task_id`
- `status`
- `summary`

상태별 추가 필수:

- `failed`, `killed` → `error`
- `needs_human` → `question`
- `skipped` → `reason`

정의는 [schemas/soldier-result.schema.json](/Users/eddy/Documents/worktree/lab/lil-eddy/schemas/soldier-result.schema.json)을 따른다.

## resume

resume token은 현재도 `session_id` 파일명으로 저장한다.

- Claude: 실제 session id
- Codex: best-effort session token

왕과 장군은 이를 generic resume token처럼 취급한다.

## 테스트

- [tests/test_spawn_soldier.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/test_spawn_soldier.sh)
- [tests/test_workspace_claude.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/test_workspace_claude.sh)

# Builtin General Engine Support

## Current Matrix

| General | Claude | Codex | 상태 |
|--------|--------|-------|------|
| `gen-herald` | Yes | Yes | dual-engine |
| `gen-briefing` | Yes | Yes | dual-engine |
| `gen-doctor` | Yes | Yes | dual-engine |
| `gen-pr` | Yes | Yes | dual-engine |
| `gen-catchup` | Yes | Yes | dual-engine |
| `gen-test-writer` | Yes | Yes | dual-engine |
| `gen-jira` | Yes | No | deferred |
| `gen-harness-querypie-mono` | Yes | No | draft harness |

## Asset Rules

공통 fallback:

- `prompt.md`

엔진별 자산:

- Claude: `prompt-claude.md`, `general-claude.md`, `agents/claude/`, `skills/claude/`
- Codex: `prompt-codex.md`, `general-codex.md`, `agents/codex/`, `skills/codex/`

지원 엔진은 `manifest.yaml`의 `supported_engines`로 선언한다.

## Operational Guidance

- 새 장군은 가능하면 처음부터 `supported_engines`를 명시한다
- Codex 대응이 안 된 장군은 `claude-only`로 유지한다
- plugin 의존이 깊은 장군은 먼저 plugin-free workflow로 자립화한 뒤 Codex를 연다

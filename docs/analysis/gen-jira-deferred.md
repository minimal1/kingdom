# gen-jira Deferred Note

## Decision

`gen-jira`는 현재 `claude-only` 하네스 장군으로 재설계 중이며, Codex 포팅은 보류한다.

## Why Deferred

1. 현재 Claude 경로 안에서도 완성도가 낮다
2. Codex용 자산과 운영 검증이 아직 없다
3. Jira 상태/라벨/레포 연결 규칙이 복잡하다
4. 다른 장군 대비 운영 리스크가 높다

## Current State

- `supported_engines: [claude]`
- `cc_plugins: [friday@qp-plugin]`
- default repo 고정

관련 파일:

- [generals/gen-jira/manifest.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-jira/manifest.yaml)
- [generals/gen-jira/README.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-jira/README.md)

## Revisit Conditions

아래 중 하나가 충족되면 다시 검토한다.

- plugin-free Jira workflow가 문서화됨
- Claude 경로에서 동작 안정화 완료
- Codex용 task decomposition이 명확해짐

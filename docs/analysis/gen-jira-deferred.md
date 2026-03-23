# gen-jira Deferred Note

## Decision

`gen-jira`는 제거 대상으로 보고, 후속 방향을 `gen-harness-querypie-mono`로 둔다.

## Why Deferred

1. 이름이 너무 넓고 책임이 레포 바운드 개발 하네스에 가깝다
2. successor가 더 적절하다
3. Jira 상태/라벨/레포 연결 규칙이 복잡하다
4. 다른 장군 대비 운영 리스크가 높다

## Current State

- successor는 repo-bound harness general로 재설계한다

관련 파일:

- [generals/gen-harness-querypie-mono/manifest.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-harness-querypie-mono/manifest.yaml)
- [generals/gen-harness-querypie-mono/README.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-harness-querypie-mono/README.md)

## Revisit Conditions

아래 중 하나가 충족되면 다시 검토한다.

- plugin-free Jira workflow가 문서화됨
- Claude 경로에서 동작 안정화 완료
- Codex용 task decomposition이 명확해짐

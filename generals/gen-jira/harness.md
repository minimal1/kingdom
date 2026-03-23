# gen-jira Harness

## Harness Mode

이 장군은 `harnessed_dev` 모드로 동작하는 것을 목표로 한다.

## Phase Order

1. `bootstrap`
2. `intake`
3. `plan`
4. `execute`
5. `review`
6. `validate`
7. `decide`
8. `report`

각 phase는 이전 phase의 산출물을 기반으로 진행한다.

## Bootstrap Knowledge

작업 시작 전에 아래를 읽어라.

1. 레포의 핵심 문서와 skills
2. 이전 memory digest
3. 관련 모듈의 테스트/빌드 규칙

## Human Involvement Policy

- 기본적으로 즉시 사람에게 묻지 않는다
- 먼저 내부 judge(`risk-judge`, `validation-judge`)가 판단한다
- 그래도 결론이 안 나면 `needs_human`

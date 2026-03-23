# gen-harness-querypie-mono Proposal

## Why

`gen-jira`는 이름이 너무 넓고, 실제로는 `querypie-mono` 레포 전용 개발 하네스 장군에 가깝다.

따라서 이벤트 소스보다 “어떤 레포에 대해 어떤 방식으로 일하는가”를 이름에 반영하는 것이 더 적절하다.

## Trigger Model

- Jira: direct subscribe
- Slack: petition-routed

이 방식의 장점:

- DM catch-all과 충돌하지 않음
- Jira/Slack이 같은 개발 하네스로 합류 가능
- 장군의 책임이 repo 중심으로 고정됨

## Recommendation

장기적으로:

- `gen-jira`는 legacy/deprecated
- `gen-harness-querypie-mono`가 active successor

# gen-jira - Jira 티켓 대응

Jira 티켓이 "In Progress" 상태이고 "kingdom" 라벨이 있을 때 friday:jira 커맨드로 작업을 수행한다.
현재 스프린트의 할당된 티켓을 추적하되, 실제 작업은 두 조건을 모두 만족할 때만 실행한다.

현재는 보류 대상이며, 다음 방향은 harnessed_dev 재설계다.

관련 초안:

- `harness.md`
- `decision-rules.md`
- `validation-rules.md`
- `prompt-harness-claude.md`
- `README-harness-v1.md`

## 사전 요구사항

- Kingdom 설치 완료 (`/opt/kingdom/`)
- Jira API 토큰 (`JIRA_API_TOKEN` 환경변수)
- friday@qp-plugin CC 플러그인

## 설치

```bash
bash generals/gen-jira/install.sh
```

## 구독 이벤트

| 이벤트 | 설명 |
|--------|------|
| `jira.ticket.assigned` | 새 티켓이 최초 감지됨 |
| `jira.ticket.updated` | 티켓 상태 변경 |

> 두 이벤트 모두 수신하지만, 프롬프트에서 `payload.status == "In Progress"` 가드를 적용. 그 외 상태에서는 즉시 건너뜀(⏭️).

## 설정

파수꾼의 Jira watcher 설정 (`config/sentinel.yaml`):

```yaml
polling:
  jira:
    interval_seconds: 300
    scope:
      jql_base: "assignee = currentUser() AND project IN (QP, QPD)"
```

## 제거

```bash
/opt/kingdom/bin/install-general.sh --remove gen-jira
```

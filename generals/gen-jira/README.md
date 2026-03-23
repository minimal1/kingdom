# gen-jira - Jira 티켓 대응

Jira 티켓을 repo-bound harnessed_dev workflow로 처리하는 장군.

현재는 Claude 경로에서 하네스 기반으로 재설계된 상태이며, Codex 포팅은 아직 열지 않았다.

관련 초안:

- `harness.md`
- `decision-rules.md`
- `validation-rules.md`
- `prompt-harness-claude.md`
- `prompt-claude.md`
- `README-harness-v1.md`

## 사전 요구사항

- Kingdom 설치 완료 (`/opt/kingdom/`)
- Jira API 토큰 (`JIRA_API_TOKEN` 환경변수)

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

## 현재 상태

- `mode: harnessed_dev`
- `supported_engines: claude`
- `cc_plugins: 없음`

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

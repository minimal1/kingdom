# gen-jira — Jira 티켓 작업 장군

## 작업 조건

다음 두 조건을 **모두** 만족해야 작업을 수행한다:

1. payload.status가 "In Progress"일 것
2. payload.labels에 "kingdom"이 포함되어 있을 것

조건 미충족 시 아무 작업도 하지 않고 즉시 종료한다.
종료 시 결과 보고: "⏭️ {ticket_key} — 건너뜀 (status={status}, labels={labels})"

# 이벤트 타입 카탈로그

> 시스템에서 흐르는 모든 이벤트 타입의 단일 진실 소스 (Single Source of Truth).

## 이벤트 소스별 분류

### 파수꾼 (Sentinel) → 왕

외부 개발 도구에서 감지한 변화. 왕이 **새 작업을 생성**하여 처리.

| Type | 소스 | 발생 조건 | Priority | ID 패턴 |
|------|------|----------|----------|---------|
| `github.pr.review_requested` | GitHub | PR 리뷰 요청 수신 | normal | `evt-github-{notification_id}` |
| `github.pr.mentioned` | GitHub | PR에서 멘션됨 | normal | `evt-github-{notification_id}` |
| `github.pr.assigned` | GitHub | PR에 어사인됨 | normal | `evt-github-{notification_id}` |
| `github.pr.comment` | GitHub | PR에 코멘트 추가 | low | `evt-github-{notification_id}` |
| `github.pr.state_change` | GitHub | PR 상태 변경 (merged, closed 등) | low | `evt-github-{notification_id}` |
| `github.notification.*` | GitHub | 기타 notification reason | low | `evt-github-{notification_id}` |
| `github.issue.mentioned` | GitHub | Issue에서 멘션됨 | low | `evt-github-{notification_id}` |
| `github.issue.assigned` | GitHub | Issue에 어사인됨 | normal | `evt-github-{notification_id}` |
| `jira.ticket.assigned` | Jira | 티켓 할당됨 | normal | `evt-jira-{ticket_key}-{updated_ts}` |
| `jira.ticket.updated` | Jira | 할당된 티켓 상태/내용 변경 | normal | `evt-jira-{ticket_key}-{updated_ts}` |
| `jira.ticket.commented` | Jira | 할당된 티켓에 코멘트 | low | `evt-jira-{ticket_key}-{updated_ts}` |

> GitHub 이벤트 타입은 Notifications API의 `reason` 필드 기반으로 결정.
> Jira 이벤트 타입은 `changelog` 분석으로 결정.
> `github.pr.comment`, `github.pr.state_change`, `github.notification.*`는 현재 구독 장군 없음 — 왕이 경고 로그 후 폐기.
> `github.issue.mentioned`, `github.issue.assigned`는 **현재 파수꾼이 미생성** — Notifications API에서 issue 이벤트는 감지 가능하나 파수꾼의 파싱 로직 미구현 상태. 향후 구현 시 gen-jira의 subscribes에 추가 예정.
> `jira.ticket.commented`는 **현재 파수꾼이 미생성** — Jira REST API의 changelog에서 코멘트 변경 감지 로직 미구현 상태.
> 상세: [roles/sentinel.md](../roles/sentinel.md)

### 사절 (Envoy) → 왕

Slack에서 감지한 사람의 응답. 왕이 **기존 작업을 재개**하여 처리.

| Type | 소스 | 발생 조건 | Priority | ID 패턴 |
|------|------|----------|----------|---------|
| `slack.human_response` | Slack | needs_human 스레드에 사람이 답변 | high | `evt-slack-response-{task_id}-{unix_ts}` |

> 상세: [roles/envoy.md](../roles/envoy.md#인바운드-slack--시스템)

---

## 왕의 처리 분기

왕은 이벤트 타입에 따라 두 가지 다른 경로로 처리한다:

```
queue/events/pending/
     │
     ▼
왕: 이벤트 소비
     │
     ├─ source: github | jira
     │   → 새 작업 생성 (라우팅: 어떤 장군에게?)
     │   → queue/tasks/pending/ 에 작업 파일 생성
     │
     └─ source: slack (type: slack.human_response)
         → 기존 작업 재개 (체크포인트 + 사람 응답 결합)
         → queue/tasks/pending/ 에 작업 파일 생성 (재개 플래그 포함)
```

### 새 작업 생성 경로

```
이벤트 타입 → 장군 매핑 (config/generals/*.yaml 매니페스트 기반):
  왕이 시작 시 각 장군 매니페스트의 subscribes를 읽어 ROUTING_TABLE 구성.
  예:
    github.pr.*           → gen-pr   (gen-pr.yaml의 subscribes에 선언)
    jira.ticket.*         → gen-jira (gen-jira.yaml의 subscribes에 선언)
    github.issue.*        → (현재 구독 장군 없음 — 파수꾼 미생성 + gen-jira subscribes 미포함)
  매칭 실패 시 → 경고 로그, 이벤트를 completed로 이동 (폐기)
```

### 기존 작업 재개 경로

```
slack.human_response
  → payload.task_id로 원래 작업 조회
  → 체크포인트 파일 확인 (state/results/{task_id}-checkpoint.json)
  → 원래 장군에게 재배정 (체크포인트 + 사람 응답 포함)
```

---

## 이벤트 공통 스키마

모든 이벤트는 아래 스키마를 따른다:

```json
{
  "id": "evt-{source}-{source_specific_id}",
  "type": "{source}.{category}.{action}",
  "source": "github | jira | slack",
  "repo": "owner/repo | null",
  "payload": { },
  "priority": "low | normal | high",
  "created_at": "ISO8601",
  "status": "pending | dispatched | completed | failed"
}
```

### ID 패턴 요약

| 소스 | 패턴 | 생성자 | 중복 방지 |
|------|------|--------|----------|
| GitHub | `evt-github-{notification_id}` | 파수꾼 | ETag + seen/ 인덱스 |
| Jira | `evt-jira-{ticket_key}-{updated_ts}` | 파수꾼 | timestamp 기반 + seen/ 인덱스 |
| Slack | `evt-slack-response-{task_id}-{unix_ts}` | 사절 | task_id + timestamp 자연적 유일성 |

### Priority 기준

| Priority | 기준 | 예시 |
|----------|------|------|
| `high` | 즉시 처리 필요, 사람이 기다리는 중 | `slack.human_response` |
| `normal` | 일반 작업 흐름 | PR 리뷰 요청, 티켓 할당 |
| `low` | 급하지 않은 알림 | Issue 멘션, 코멘트 |

왕이 priority에 따라 처리 순서를 결정한다 (high → normal → low).

---

## 확장 시 가이드

### 새 이벤트 소스 추가 (Watcher 축)

1. 이 문서에 이벤트 타입 추가
2. ID 패턴 정의 (중복 방지 전략 포함)
3. 센티널에 새 watcher 스크립트 작성 (`bin/lib/sentinel/{source}-watcher.sh`)
4. 기존 장군 매니페스트의 `subscribes`에 새 타입 추가 (해당 장군이 처리 가능한 경우)

### 새 장군 추가 (General 축)

1. 장군 매니페스트 작성 (`config/generals/gen-{name}.yaml`)
2. `subscribes`에 처리할 이벤트 타입 선언 (기존 타입 중 선택)
3. `schedules`에 정기 작업 선언 (필요 시)
4. 장군 실행 스크립트 작성 (`bin/generals/gen-{name}.sh`)
5. 왕/센티널 코드 수정 불필요 — 매니페스트만 추가하면 자동 인식

---

## 관련 문서

- [message-passing.md](message-passing.md) — 이벤트 큐 구조, 상태 전이
- [roles/sentinel.md](../roles/sentinel.md) — GitHub/Jira 이벤트 감지 상세
- [roles/envoy.md](../roles/envoy.md) — Slack human_response 이벤트 생성
- [roles/king.md](../roles/king.md) — 이벤트 소비, 동적 라우팅, 작업 배정

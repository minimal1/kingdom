# 메시지 패싱 시스템

> 역할 간 통신은 파일 기반 JSON으로 이루어진다. 단순하고 디버깅이 용이하다.

## 설계 원칙

- **외부 의존성 없음**: Redis, RabbitMQ 등 별도 서버 불필요
- **디버깅 용이**: 모든 메시지가 파일로 존재, `cat`으로 확인 가능
- **상태 추적**: 파일의 디렉토리 위치가 곧 상태 (pending → dispatched → completed)

## 메시지 흐름

```
파수꾼 ──event.json──→ queue/events/pending/
                            │
                     왕이 소비 (polling)
                            │
                     왕이 작업 생성
                            ↓
                       queue/tasks/pending/
                            │
                     장군이 소비 (polling)
                            │
                     병사 실행 → 결과 저장
                            ↓
                       state/results/
                            │
                     왕이 확인 (polling)
```

## 이벤트 큐 (`queue/events/`)

### 디렉토리 구조
```
queue/events/
├── pending/         # 파수꾼이 생성, 왕이 아직 안 읽음
├── dispatched/      # 왕이 읽고 작업으로 변환함
└── completed/       # 작업 완료 후 보관
```

### 상태 전이
```
pending → dispatched → completed
                    ↘ failed → completed/ (실패 사유는 결과 파일에 포함, 별도 failed/ 디렉토리 없음)
```

### 이벤트 스키마
```json
{
  "id": "evt-{source}-{source_specific_id}",
  "type": "github.pr.review_requested",
  "source": "github",
  "repo": "querypie/frontend",
  "payload": { },
  "priority": "normal | high | low",
  "created_at": "ISO8601",
  "status": "pending | dispatched | completed | failed"
}
```

이벤트 ID는 소스별 자연 키를 사용하여 자동 중복 방지:
- GitHub: `evt-github-{notification_id}` (예: `evt-github-12345678`) — 파수꾼 생성
- Jira: `evt-jira-{ticket_key}-{updated_timestamp}` (예: `evt-jira-QP-123-20260207100000`) — 파수꾼 생성
- Slack (human_response): `evt-slack-response-{task_id}-{unix_timestamp}` (예: `evt-slack-response-task-20260207-001-1707300000`) — 사절 생성

> 이벤트 타입 전체 카탈로그: [systems/event-types.md](event-types.md)
> 상세: [roles/sentinel.md](../roles/sentinel.md#이벤트-스키마-공통), [roles/envoy.md](../roles/envoy.md#이벤트-타입-정의)

## 작업 큐 (`queue/tasks/`)

### 디렉토리 구조
```
queue/tasks/
├── pending/         # 왕이 생성, 장군이 아직 안 읽음
├── in_progress/     # 장군이 처리 중
└── completed/       # 작업 완료
```

### 상태 전이
```
pending → in_progress → completed
                     ↘ failed
                     ↘ needs_human
```

### 작업 스키마
```json
{
  "id": "task-{YYYYMMDD}-{seq}",
  "event_id": "evt-{source}-{source_specific_id} | schedule-{name}",
  "target_general": "gen-pr | gen-test | gen-jira",
  "type": "{event_type} | resume | {schedule.task_type}",
  "payload": { },
  "priority": "normal | high | low",
  "created_at": "ISO8601",
  "status": "pending | in_progress | completed | failed | needs_human"
}
```

## 알림 큐 (`queue/messages/`)

왕, 장군, 내관이 사절에게 보내는 알림 요청.

### 디렉토리 구조
```
queue/messages/
├── pending/         # 발송 대기
└── sent/            # 발송 완료
```

### 메시지 스키마
```json
{
  "id": "msg-{YYYYMMDD}-{seq}",
  "type": "thread_start | thread_update | human_input_request | notification | report",
  "channel": "dev-eddy",
  "urgency": "normal | high | urgent",
  "content": "사람이 읽을 메시지",
  "context": { },
  "created_at": "ISO8601",
  "status": "pending | sent"
}
```

## Polling 주기

| 역할 | 대상 | 주기 |
|------|------|------|
| 왕 | `queue/events/pending/` | 10초 |
| 왕 | `state/results/` | 10초 |
| 장군 | `queue/tasks/pending/` (자기 도메인) | 10초 |
| 사절 | `queue/messages/pending/` | 5초 |
| 내관 | 시스템 리소스 | 30초 |

## 파일 조작 원자성

파일 기반 시스템에서 경합 조건을 방지하기 위한 규칙:

1. **Write-then-Rename**: 임시 파일에 쓴 후 `mv`로 이동 (원자적)
2. **단일 소비자**: 각 큐는 하나의 역할만 소비 (events→왕, tasks→해당 장군)
3. **상태 변경 = 디렉토리 이동**: `mv pending/file.json dispatched/file.json`

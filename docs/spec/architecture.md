# Kingdom - Architecture Blueprint

> 파일 기반 큐와 역할 분리로 동작하는 자율형 AI 런타임.

## 한 줄 요약

Kingdom은 `sentinel → king → general → soldier` 실행 축과 `envoy`, `chamberlain` 보조 축으로 구성된다. 모든 역할은 디렉토리 기반 상태 전이와 JSON 파일을 통해 통신한다.

## 역할

| 역할 | 책임 |
|------|------|
| `sentinel` | GitHub/Jira polling, 이벤트 생성 |
| `king` | 이벤트 소비, 장군 라우팅, 결과 처리, 스케줄, petition |
| `general` | task claim, workspace, prompt, soldier, result |
| `soldier` | Claude Code `-p` 기반 실제 작업 수행 |
| `envoy` | Slack Socket Mode 인바운드/아웃바운드 |
| `chamberlain` | 리소스, heartbeat, 세션, 로그 정리 |

## 데이터 흐름

```
GitHub/Jira
  ↓
sentinel
  ↓ queue/events/pending
king
  ↓ queue/tasks/pending
general
  ↓ state/results/{task}.json
king
  ↓ queue/messages/pending
envoy
  ↓ Slack
```

부가 흐름:

- Slack DM / app mention / thread reply → `envoy` → `queue/events/pending`
- chamberlain → `state/resources.json`, `queue/messages/pending`

## 핵심 설계 원칙

- Polling 유지: GitHub/Jira는 polling, Slack은 Socket Mode
- 파일이 곧 상태: `pending`, `dispatched`, `in_progress`, `completed`, `sent`, `failed`
- 외부 MQ 없음: Redis/RabbitMQ 없이 동작
- Schema-first: schema → config → docs → code → tests
- macOS bash 3.2 호환

## 런타임 디렉토리

주요 디렉토리:

- `queue/events/`
- `queue/tasks/`
- `queue/messages/`
- `state/results/`
- `state/envoy/`
- `memory/generals/`
- `logs/`
- `workspace/{general}/`

상세는 [systems/filesystem.md](systems/filesystem.md), [systems/message-passing.md](systems/message-passing.md)를 기준으로 한다.

## 현재 구조 포인트

- `king`는 `functions.sh`, `messages.sh`, `schedules.sh`로 분리
- `envoy`는 Socket Mode 전용이며 bridge/outbound/message-processors/socket-inbox로 분리
- `general`은 task-selection/workspace/memory/soldier-lifecycle/results/main-loop로 분리
- 향후 자발적 개발형 장군을 위해 `Harness General Mode` 도입 예정

## 설정 기준

- 시스템 버전: [config/system.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/system.yaml)
- 왕 설정: [config/king.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/king.yaml)
- 사절 설정: [config/envoy.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/envoy.yaml)
- 파수꾼 설정: [config/sentinel.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/sentinel.yaml)

## 관련 문서

- [roles/king.md](roles/king.md)
- [roles/general.md](roles/general.md)
- [harness-general-mode.md](harness-general-mode.md)
- [roles/envoy.md](roles/envoy.md)
- [systems/event-types.md](systems/event-types.md)
- [systems/internal-events.md](systems/internal-events.md)
- [systems/message-passing.md](systems/message-passing.md)

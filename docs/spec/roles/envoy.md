# 사절 (Envoy)

> Slack Socket Mode 전용 통신 게이트웨이.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `envoy` |
| tmux 세션 | `envoy` |
| 실행 형태 | Bash 루프 + Node.js bridge |
| 수명 | 상주 (Always-on) |
| 통신 방식 | Slack Socket Mode + Web API |

## 책임

- Slack 인바운드/아웃바운드 독점
- 작업별 스레드 매핑 관리
- `needs_human` 응답과 대화 스레드 후속 응답을 `slack.thread.reply`로 통합
- 원본 DM/스레드에 상태 리액션 반영

## 비책임

- 작업 판단, 장군 선택, 실행
- GitHub/Jira 감시
- `reply_context` 의미 해석

## 런타임 구조

```
Slack Socket Mode
  ↓
bridge.js
  ↓  socket-inbox/*.json
envoy.sh
  ├─ check_socket_inbox()
  ├─ process_outbound_queue()
  ├─ expire_conversations()
  └─ check_bridge_health()
  ↓
outbox/*.json
  ↓
bridge.js → Slack Web API
  ↓
outbox-results/*.json
```

관련 파일:

- [bin/envoy.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/envoy.sh)
- [bin/lib/envoy/bridge-lifecycle.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/bridge-lifecycle.sh)
- [bin/lib/envoy/bridge.js](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/bridge.js)
- [bin/lib/envoy/slack-api.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/slack-api.sh)
- [bin/lib/envoy/message-processors.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/message-processors.sh)
- [bin/lib/envoy/outbound.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/outbound.sh)
- [bin/lib/envoy/socket-inbox.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/socket-inbox.sh)
- [bin/lib/envoy/thread-manager.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/thread-manager.sh)

## 인바운드

bridge.js가 Slack 이벤트를 받아 `state/envoy/socket-inbox/`에 파일로 기록한다. envoy는 이를 읽어 다음 외부 이벤트를 생성한다.

- DM top-level message → `slack.channel.message`
- app mention → `slack.app_mention`
- thread reply → `slack.thread.reply`

`slack.thread.reply`는 두 흐름을 통합한다.

- `awaiting-responses.json`: `needs_human` 질문에 대한 일회성 응답
- `conversation-threads.json`: 멀티턴 대화 추적

## 아웃바운드

시스템은 `queue/messages/pending/`에 메시지 파일을 쓴다. envoy는 메시지 타입별로 처리하고, 실제 Slack API 호출은 outbox를 통해 bridge.js가 수행한다.

지원 타입:

- `thread_start`
- `thread_update`
- `thread_reply`
- `human_input_request`
- `notification`
- `report`

전송 성공 시 `queue/messages/sent/`, 재시도 초과 시 `queue/messages/failed/`로 이동한다.

## 상태 파일

| 파일 | 용도 |
|------|------|
| `state/envoy/thread-mappings.json` | `task_id ↔ thread_ts/channel` |
| `state/envoy/awaiting-responses.json` | `needs_human` 응답 대기 |
| `state/envoy/conversation-threads.json` | 멀티턴 대화 추적 |
| `state/envoy/socket-inbox/` | bridge 인바운드 이벤트 |
| `state/envoy/outbox/` | Slack API 요청 |
| `state/envoy/outbox-results/` | Slack API 결과 |
| `state/envoy/bridge-health` | bridge 생존 확인 |

## 핵심 동작

### `thread_start`

- 일반 이벤트: 새 부모 메시지 생성 후 스레드 매핑 저장
- DM 이벤트: 기존 DM 메시지를 부모로 재사용하고 답글만 전송

### `human_input_request`

- 기존 매핑이 있으면 해당 스레드에 질문 게시
- DM 원본이면 `channel/thread_ts`를 직접 사용
- 이후 `awaiting-responses.json`에 등록

### `notification`

- 해당 task의 스레드가 있으면 답글
- 없으면 채널 직접 전송
- 완료형 메시지(`✅`, `❌`, `⏭️`)는 스레드 매핑과 awaiting 상태를 정리

## 설정

[config/envoy.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/envoy.yaml)

```yaml
slack:
  bot_token_env: "SLACK_BOT_TOKEN"
  default_channel: "dev-eddy"

socket_mode:
  app_token_env: "SLACK_APP_TOKEN"

intervals:
  outbound_seconds: 5
  loop_tick_seconds: 5
  conversation_ttl_seconds: 3600
```

Envoy는 Socket Mode 전용이므로 `SLACK_APP_TOKEN`이 필수다.

## 테스트

- [tests/test_envoy.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/test_envoy.sh)
- [tests/lib/envoy/test_slack_api.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/envoy/test_slack_api.sh)
- [tests/lib/envoy/test_thread_manager.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/envoy/test_thread_manager.sh)

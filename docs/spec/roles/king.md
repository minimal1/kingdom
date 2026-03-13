# 왕 (King)

> 이벤트를 작업으로 바꾸고, 결과를 후속 조치로 연결하는 중앙 오케스트레이터.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `king` |
| tmux 세션 | `king` |
| 실행 형태 | Bash polling loop |
| 수명 | 상주 |
| 책임 축 | 이벤트 소비, 라우팅, 결과 처리, 스케줄, petition |

관련 파일:

- [bin/king.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/king.sh)
- [bin/lib/king/functions.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/functions.sh)
- [bin/lib/king/messages.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/messages.sh)
- [bin/lib/king/schedules.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/schedules.sh)
- [bin/lib/king/router.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/router.sh)
- [bin/lib/king/resource-check.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/resource-check.sh)
- [bin/lib/king/petition.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/petition.sh)

## 책임

- `queue/events/pending/` 소비
- 이벤트 타입 → 장군 라우팅
- 리소스/동시성 기반 수용 판단
- `queue/tasks/pending/` 작업 생성
- `state/results/` 결과 후처리
- 장군 스케줄 실행
- DM petition 비동기 분류
- `queue/messages/pending/` 알림 생성

## 비책임

- 작업 실행 방법 결정
- 병사 생성/세션 운영
- 외부 감시
- Slack 전송

## 메인 루프

왕은 네 종류의 주기를 반복한다.

1. 이벤트 소비
2. petition 결과 수거
3. 결과 처리
4. 스케줄 검사

실제 루프는 [bin/king.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/king.sh)에 있고, 모든 핵심 로직은 보조 모듈로 위임된다.

## 이벤트 처리

### 일반 이벤트

`process_pending_events()`는 다음 순서로 동작한다.

1. `collect_and_sort_events()`로 우선순위 정렬
2. 리소스 상태 확인
3. `sessions.json` 기반 동시 병사 수 확인
4. `find_general()`로 장군 결정
5. `dispatch_new_task()`로 task + thread_start 생성

매칭 실패 시 이벤트는 `completed/`로 이동하고 `event.discarded` 내부 이벤트를 남긴다.

### `slack.thread.reply`

`process_thread_reply()`는 사람 응답을 `resume` task로 바꾼다. `reply_context`에 담긴 `general`, `session_id`, `repo`를 그대로 사용한다.

### DM petition

DM/app mention은 petition이 켜져 있으면 `petitioning/`으로 이동한 뒤 `bin/petition-runner.sh`를 별도 tmux 세션으로 실행한다. petition 결과는 다시 왕이 수거해 장군 배정, direct response, fallback routing 중 하나로 처리한다.

## 결과 처리

왕이 처리하는 최종 상태:

- `success`
- `failed`
- `killed`
- `needs_human`
- `skipped`

핵심 규칙:

- `success/failed/skipped`는 알림 메시지를 만든 뒤 task/event를 완료 처리
- `needs_human`은 질문 메시지와 `reply_context`를 만들어 사절에 전달
- `killed`는 왕이 직접 재시도 관리

내부 이벤트도 함께 발행한다.

- `task.created`
- `task.completed`
- `task.failed`
- `task.needs_human`
- `task.resumed`
- `event.dispatched`
- `event.discarded`

## 스케줄

스케줄 로직은 [bin/lib/king/schedules.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/schedules.sh)에 분리되어 있다.

핵심 특징:

- cron 표현식 매칭
- `general:schedule` 키 기반 dedup
- catch-up scan 지원
- 리소스 상태가 안 좋으면 실행 보류

## 메시지 생성

왕은 Slack API를 직접 호출하지 않는다. 대신 [bin/lib/king/messages.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/messages.sh)를 통해 메시지 파일만 만든다.

주요 타입:

- `thread_start`
- `thread_update`
- `thread_reply`
- `human_input_request`
- `notification`
- `report`

`source_ref`를 함께 주입해 사절이 원본 DM 리액션을 갱신할 수 있게 한다.

## 상태 파일

| 파일 | 용도 |
|------|------|
| `state/king/task-seq` | task id 시퀀스 |
| `state/king/msg-seq` | message id 시퀀스 |
| `state/king/schedule-sent.json` | 스케줄 dedup 기록 |
| `state/king/petition-results/` | petition 결과 수거 |

## 설정

[config/king.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/config/king.yaml)

주요 필드:

- `slack.default_channel`
- `retry.max_attempts`
- `concurrency.max_soldiers`
- `petition.*`
- `intervals.*`

## 테스트

- [tests/test_king.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/test_king.sh)
- [tests/lib/king/test_router.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/king/test_router.sh)
- [tests/lib/king/test_resource_check.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/tests/lib/king/test_resource_check.sh)

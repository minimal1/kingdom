# gen-pr 동작 시나리오

> 현재 런타임 기준의 축약된 end-to-end 예시.

## 전제

- 이벤트: `github.pr.review_requested`
- 장군: `gen-pr`
- 결과: Slack 스레드 시작 후 리뷰 완료 알림

## 1. 센티널

`github_fetch()`가 GitHub notifications를 읽고, `github_parse()`가 아래 이벤트를 만든다.

```json
{
  "id": "evt-github-12345678-2026-02-07T10:00:00Z",
  "type": "github.pr.review_requested",
  "source": "github",
  "repo": "chequer-io/querypie-frontend",
  "payload": {
    "notification_thread_id": "12345678",
    "pr_number": "1234",
    "subject_title": "feat: add user profile"
  },
  "priority": "normal",
  "status": "pending"
}
```

이 이벤트는 `queue/events/pending/`에 기록되고, 성공 시에만 `seen/` 마커와 GitHub read 처리까지 진행된다.

## 2. 왕

`process_pending_events()`가 이벤트를 소비한다.

- 리소스 상태 확인
- `find_general()` → `gen-pr`
- `dispatch_new_task()` 실행

생성 결과:

- `queue/tasks/pending/task-YYYYMMDD-001.json`
- `queue/messages/pending/msg-YYYYMMDD-001.json` (`thread_start`)
- 원래 이벤트는 `queue/events/dispatched/`로 이동

## 3. 사절

`process_outbound_queue()`가 `thread_start`를 소비한다.

- 일반 GitHub 이벤트이므로 새 Slack 부모 메시지 생성
- `thread_ts`를 `thread-mappings.json`에 저장
- 부모 메시지에 `eyes` 리액션 부여

## 4. 장군

`main_loop()`가 task를 점유한다.

- `pick_next_task("gen-pr")`
- `in_progress/` 이동
- `ensure_workspace()`
- `build_prompt()`
- `spawn_soldier()`
- `wait_for_soldier()`

`gen-pr`의 prompt는 `pr_number`를 치환한 `/friday:review-pr 1234` 형태다.

## 5. 병사

병사는 workspace의 `CLAUDE.md`를 로드하고 raw result를 쓴다.

예시:

```json
{
  "task_id": "task-20260207-001",
  "status": "success",
  "summary": "PR #1234에 대해 5개 코멘트 작성 완료",
  "memory_updates": [
    "이 레포는 barrel export를 선호하지 않음"
  ]
}
```

파일 위치:

- `state/results/{task}-raw.json`
- `state/results/{task}-session-id` (있다면)
- `state/results/{task}-soldier-id`

## 6. 장군 결과 보고

장군은 raw result를 읽고:

- `update_memory()`
- `report_to_king()`

를 수행한다. 최종 결과는 `state/results/{task}.json`에 기록된다.

## 7. 왕 최종 처리

`check_task_results()`가 최종 result를 읽고 `handle_success()`를 호출한다.

결과:

- task → `queue/tasks/completed/`
- event → `queue/events/completed/`
- notification → `queue/messages/pending/`
- 내부 이벤트: `task.completed`

## 8. 사절 최종 알림

`notification` 메시지는 기존 thread mapping을 사용해 스레드 답글로 전송된다.

완료형 메시지면:

- 부모 메시지 `eyes` 제거
- `white_check_mark` 추가
- thread mapping 제거

## `needs_human` 흐름 차이

병사 상태가 `needs_human`이면:

1. 장군이 `checkpoint.json` 생성
2. 왕이 `human_input_request` 생성
3. 사절이 질문 메시지 + `awaiting-responses.json` 등록
4. 사람 답글은 `slack.thread.reply` 이벤트로 재유입
5. 왕이 `resume` task 생성

## 관련 파일

- [bin/lib/sentinel/github-watcher.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/sentinel/github-watcher.sh)
- [bin/lib/king/functions.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/king/functions.sh)
- [bin/lib/general/main-loop.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/general/main-loop.sh)
- [bin/lib/envoy/message-processors.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/bin/lib/envoy/message-processors.sh)
- [docs/spec/roles/king.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/spec/roles/king.md)
- [docs/spec/roles/general.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/spec/roles/general.md)

# gen-pr 동작 시나리오

> **이벤트 기반 장군의 예시.** 파수꾼이 GitHub 이벤트를 감지하면, 왕이 gen-pr에게 작업을 배정하고, friday CC Plugin으로 PR 리뷰를 수행한다.
>
> 사용자는 `subscribes`, `cc_plugins`, `timeout_seconds`를 자기 도메인에 맞게 조정하여 새로운 이벤트 기반 장군을 구성할 수 있다.

---

## 매니페스트 요약

```yaml
# generals/gen-pr/manifest.yaml
name: gen-pr
description: "PR review general"
timeout_seconds: 1800          # 30분
cc_plugins:
  - friday@qp-plugin           # plugin-name@marketplace 형식
subscribes:
  - github.pr.review_requested
schedules: []                  # 이벤트 전용, 스케줄 없음
```

**프롬프트 (prompt.md)**:
```
/friday:review-pr {{payload.pr_number}}
```

---

## Scenario A: Happy Path — PR 리뷰 요청 → 리뷰 완료

**전제**: querypie/frontend PR #1234에 리뷰 요청이 들어옴

### Phase 1: 이벤트 감지 (파수꾼)

```
T+0s   파수꾼 github_fetch()
       → gh api /notifications (ETag: "abc123")
       → 304가 아닌 200 응답 — 새 notification 존재

T+0s   파수꾼 github_parse()
       → reason: "review_requested", subject: "feat: add user profile"
       → 스코프 필터 통과 (querypie/frontend ∈ sentinel.yaml.scope.repos)
       → 이벤트 스키마 변환:
         {
           "id": "evt-github-12345678",
           "type": "github.pr.review_requested",
           "source": "github",
           "repo": "querypie/frontend",
           "payload": { "reason": "review_requested", "subject_title": "feat: add user profile", ... },
           "priority": "normal"
         }

T+0s   파수꾼 sentinel_emit_event()
       → is_duplicate("evt-github-12345678") = false
       → 쓰기: queue/events/pending/.tmp-evt-github-12345678.json
       → mv → queue/events/pending/evt-github-12345678.json
       → touch state/sentinel/seen/evt-github-12345678
```

### Phase 2: 작업 배정 (왕)

```
T+~10s  왕 process_pending_events()
        → queue/events/pending/ 스캔 → evt-github-12345678.json 발견
        → get_resource_health() = "green" → 수용 가능
        → sessions.json wc -l = 1 < max_soldiers(3) → 수용 가능
        → find_general("github.pr.review_requested") → "gen-pr"

T+~10s  왕 dispatch_new_task()
        → task-seq 읽기 → "20260207:0" → 증분 → "20260207:1"
        → 쓰기: queue/tasks/pending/task-20260207-001.json
          {
            "id": "task-20260207-001",
            "event_id": "evt-github-12345678",
            "target_general": "gen-pr",
            "type": "github.pr.review_requested",
            "payload": { ... },
            "priority": "normal",
            "retry_count": 0,
            "status": "pending"
          }
        → mv 이벤트: pending/ → dispatched/

T+~10s  왕 create_thread_start_message()
        → msg-seq 증분 → "20260207:1"
        → 쓰기: queue/messages/pending/msg-20260207-001.json
          { "type": "thread_start", "task_id": "task-20260207-001",
            "content": "[시작] github.pr.review_requested — querypie/frontend" }
```

### Phase 3: Slack 알림 (사절)

```
T+~15s  사절 process_outbound_queue()
        → msg-20260207-001.json 감지 (type: thread_start)
        → Slack API: chat.postMessage → thread_ts = "1707300015.000100"
        → state/envoy/thread-mappings.json에 추가:
          { "task-20260207-001": { "thread_ts": "1707300015.000100", "channel": "dev-eddy" } }
        → mv 메시지: pending/ → sent/
```

### Phase 4: 작업 수행 (장군 → 병사)

```
T+~20s  장군(gen-pr) pick_next_task("gen-pr")
        → queue/tasks/pending/ 스캔 → task-20260207-001.json 발견
        → target_general = "gen-pr" ✓, retry_after = 없음 ✓
        → mv: pending/ → in_progress/

T+~20s  장군 ensure_workspace("gen-pr", "querypie/frontend")
        → workspace/gen-pr/ 존재 확인
        → enabledPlugins 검증: friday@qp-plugin 등록 확인 (객체 키 매칭)
        → git -C workspace/gen-pr/frontend fetch origin

T+~20s  장군 load_domain_memory("gen-pr")
        → memory/generals/gen-pr/*.md 읽기 (patterns.md, repo-frontend.md 등)
        → 50KB 이내로 트림

T+~21s  장군 build_prompt()
        → 템플릿: config/generals/templates/gen-pr.md (install-general.sh가 설치한 런타임 파일)
        → {{payload.pr_number}} 치환: /friday:review-pr 1234
        → 템플릿이 {{payload.*}} 사용 → payload dump 생략
        → 쓰기: state/prompts/task-20260207-001.md
          내용: "/friday:review-pr 1234"

T+~22s  장군 spawn_soldier()
        → bin/spawn-soldier.sh 호출
        → soldier_id = "soldier-1707300022-4567"
        → tmux new-session -d -s soldier-1707300022-4567
          "cd workspace/gen-pr && claude -p --dangerously-skip-permissions
           --output-format json --json-schema '{...결과 스키마...}'
           < state/prompts/task-20260207-001.md
           > state/results/task-20260207-001-raw.json.tmp 2>logs/sessions/soldier-....log;
           mv ...raw.json.tmp ...raw.json;
           tmux wait-for -S soldier-1707300022-4567-done"
        → 쓰기: state/results/task-20260207-001-soldier-id
        → sessions.json에 append (flock):
          {"id":"soldier-1707300022-4567","task_id":"task-20260207-001","started_at":"..."}

T+~22s  장군 wait_for_soldier("task-20260207-001", 1800)
        → 5초 간격으로 state/results/task-20260207-001-raw.json 존재 확인
```

### Phase 5: 병사 실행 (Claude Code)

```
T+~22s ~ T+~200s  병사 (claude -p --output-format json --json-schema ...)
        → workspace/gen-pr/ 에서 실행
        → 전역 enabledPlugins → friday@qp-plugin 자동 로드
        → 프롬프트 "/friday:review-pr 1234" 수신
          → friday 플러그인의 /review-pr 커맨드 실행:
            1. PR #1234의 변경 파일 분석 (gh pr diff 1234)
            2. 코드 품질, 보안, 성능 이슈 식별
            3. 자체 품질 루프 (ralph-loop)로 리뷰 최적화
            4. GitHub에 리뷰 코멘트 작성 (gh api)
        → --json-schema에 의해 구조화된 결과 stdout 출력:
             {
               "task_id": "task-20260207-001",
               "status": "success",
               "summary": "PR #1234에 대해 5개 코멘트 작성 완료",
               "details": { "files_reviewed": 12, "comments_posted": 5 },
               "memory_updates": ["이 레포는 barrel export를 선호하지 않음"]
             }
        → stdout → .tmp 파일 → mv로 atomic write → raw.json 완성
        → tmux wait-for -S soldier-...-done (세션 종료 시그널)
```

### Phase 6: 결과 처리 (장군 → 왕)

```
T+~200s  장군 wait_for_soldier 탈출 (raw 파일 감지)
         → status = "success"
         → update_memory(): memory/generals/gen-pr/learned-patterns.md에 append
         → report_to_king():
           쓰기: state/results/task-20260207-001.json (raw 기반, status 확정)

T+~210s  왕 check_task_results()
         → state/results/task-20260207-001.json 감지
         → status = "success"
         → handle_success():
           - mv 작업: in_progress/ → completed/
           - mv 이벤트: dispatched/ → completed/
           - create_notification_message():
             쓰기: queue/messages/pending/msg-20260207-002.json
             { "type": "notification", "task_id": "task-20260207-001",
               "content": "[완료] PR #1234 리뷰 완료 — 5개 코멘트" }

T+~215s  사절 process_outbound_queue()
         → msg-20260207-002.json 감지 (type: notification)
         → thread_mappings에서 task-20260207-001 조회 → thread_ts 획득
         → Slack API: chat.postMessage (thread reply)
         → "[완료]" 감지 → thread_mapping 항목 제거
         → mv 메시지: pending/ → sent/
```

**최종 상태**:
- `queue/events/completed/evt-github-12345678.json` (7일 후 삭제)
- `queue/tasks/completed/task-20260207-001.json` (7일 후 삭제)
- `state/results/task-20260207-001.json` + `-raw.json` (7일 후 삭제)
- `state/prompts/task-20260207-001.md` (3일 후 삭제)
- `logs/sessions/soldier-1707300022-4567.log` (7일 후 삭제)
- Slack #dev-eddy에 스레드: [시작] → [완료]

---

## Scenario B: needs_human — Breaking Change 판단 필요

**전제**: PR #2000에서 병사가 breaking change를 발견, 사람 판단 필요

```
Phase 1~4: Scenario A와 동일 (이벤트 감지 → 장군 병사 실행)

T+~180s  병사 결과:
         state/results/task-20260207-005-raw.json
         {
           "status": "needs_human",
           "question": "이 PR에 breaking change가 있습니다. major version bump가 필요한가요?",
           "summary": "사람의 판단 필요 — breaking change 여부"
         }

T+~180s  장군 wait_for_soldier 탈출
         → status = "needs_human" → 재시도 없이 즉시 에스컬레이션
         → escalate_to_king():
           쓰기: state/results/task-20260207-005-checkpoint.json
             { "task_id": "task-20260207-005", "target_general": "gen-pr",
               "repo": "querypie/frontend", "payload": { ... } }
           쓰기: state/results/task-20260207-005.json
             { "status": "needs_human", "checkpoint_path": "...checkpoint.json" }

T+~190s  왕 check_task_results()
         → status = "needs_human"
         → handle_needs_human():
           쓰기: queue/messages/pending/msg-...-003.json
             { "type": "human_input_request", "task_id": "task-20260207-005",
               "content": "[질문] breaking change가 있습니다. major version bump가 필요한가요?" }
           ※ 작업은 in_progress/ 에 유지 (대기 중)

T+~195s  사절 → Slack 스레드에 질문 게시
         → awaiting-responses.json에 추가:
           { "task_id": "task-20260207-005", "thread_ts": "...", "asked_at": "..." }

─── 사람 응답 대기 (수 분 ~ 수 시간) ───

T+???    사람이 Slack 스레드에 "아니, patch로 충분해" 답글

T+~30s후 사절 check_awaiting_responses() (30초 주기)
         → conversations.replies API로 새 답글 감지
         → 봇이 아닌 사람 메시지 필터링 → "아니, patch로 충분해"
         → 이벤트 생성:
           queue/events/pending/evt-slack-response-task-20260207-005-{ts}.json
           { "type": "slack.human_response",
             "payload": { "task_id": "task-20260207-005", "human_response": "아니, patch로 충분해" },
             "priority": "high" }
         → awaiting-responses에서 해당 항목 제거

T+~10s후 왕 process_pending_events()
         → slack.human_response 이벤트 감지
         → process_human_response():
           - checkpoint 읽기: state/results/task-20260207-005-checkpoint.json
           - 새 작업 생성:
             queue/tasks/pending/task-20260207-006.json
             { "type": "resume", "target_general": "gen-pr", "priority": "high",
               "payload": { "original_task_id": "task-20260207-005",
                            "checkpoint_path": "...", "human_response": "아니, patch로 충분해" } }
           - 원래 작업 in_progress/ → completed/

T+~20s후 장군 pick_next_task → resume 작업 소비
         → build_prompt에서 checkpoint + human_response 포함
         → 병사 재실행 → 이번에는 patch 기준으로 리뷰 완료
         → success 흐름으로 마무리
```

---

## Scenario C: 실패 → 재시도 → 성공

**전제**: 첫 시도에서 GitHub API rate limit 히트

```
T+~180s  병사 1차 시도 결과:
         { "status": "failed", "error": "GitHub API rate limit exceeded (403)" }

T+~180s  장군 재시도 루프 (attempt=0 → 1)
         → status = "failed" → retry
         → sleep 60 (backoff)
         → rm state/results/{task_id}-raw.json
         → spawn_soldier (2차 시도)

T+~300s  병사 2차 시도 결과:
         { "status": "success", "summary": "PR #1234 리뷰 완료" }

T+~300s  장군 → success 처리 (Scenario A Phase 6과 동일)
```

---

## Scenario D: 최종 실패 (재시도 소진)

```
T+~180s  1차 시도: failed (Permission denied)
T+~300s  2차 시도: failed (Permission denied)
T+~420s  3차 시도(attempt=2): failed (Permission denied)

T+~420s  장군 재시도 루프 종료 (attempt > max_retries)
         → final_status = "failed"
         → report_to_king("task-001", "failed", ...)

T+~430s  왕 handle_failure()
         → complete_task (in_progress → completed)
         → 사절에게 알림: "[실패] Permission denied — 재시도 소진"

T+~435s  사절 → Slack 스레드에 실패 알림
```

---

## Scenario E: 타임아웃 (30분 초과)

```
T+~22s    병사 시작

T+1822s   장군 wait_for_soldier 타임아웃 (1800초 경과, raw 파일 미생성)
          → tmux kill-session -t soldier-...
          → 장군이 직접 failed 결과 파일 생성:
            state/results/{task_id}-raw.json
            { "status": "failed", "error": "Timeout after 1800 seconds" }
          → 재시도 루프 진입 (attempt++)
          → 재시도 or 최종 실패 (Scenario C/D)
```

---

## Scenario F: 여러 PR이 동시에 들어올 때

**전제**: PR #100 (normal), PR #200 (normal), PR #300 (high) 이 거의 동시에 도착

```
T+0s    파수꾼: 3개 이벤트 생성 (각각 queue/events/pending/)

T+10s   왕: 3개 이벤트 순차 처리
        → 리소스 green, sessions.json = 0명
        → task-001 (PR #100, normal) 생성
        → task-002 (PR #200, normal) 생성
        → task-003 (PR #300, high) 생성

T+20s   장군 pick_next_task:
        → priority 정렬: task-003 (high) 먼저 선택
        → task-003 처리 시작

T+~200s task-003 완료
        → pick_next_task: task-001 선택 (같은 priority면 ID 순)

T+~400s task-001 완료
        → pick_next_task: task-002 선택

※ 장군은 단일 스레드이므로 한 번에 1개 작업만 처리
※ 왕은 max_soldiers 기준으로 작업 생성을 제한하지만,
   장군이 직접 동시에 여러 병사를 운영하지는 않음
```

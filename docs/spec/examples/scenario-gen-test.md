# gen-test 동작 시나리오

> **스케줄 기반 장군의 예시.** 파수꾼이 아닌 왕의 cron 스케줄이 트리거하며, 테스트 커버리지를 분석하고 부족한 모듈에 테스트를 작성한다.
>
> 사용자는 `schedules`, `cc_plugins`, `timeout_seconds`, `payload`를 자기 도메인에 맞게 조정하여 새로운 스케줄 기반 장군을 구성할 수 있다.

---

## 매니페스트 요약

```yaml
# generals/gen-test/manifest.yaml
name: gen-test
timeout_seconds: 3600          # 60분
cc_plugins:
  - saturday
subscribes: []                 # 외부 이벤트 없음
schedules:
  - name: daily-test
    cron: "0 22 * * 1-5"
    task_type: "daily-test-generation"
    payload:
      description: "Weekday 22:00 test generation"
```

**gen-pr과의 핵심 차이**: 파수꾼이 트리거하지 않음. 왕이 cron 스케줄로 직접 작업 생성.

---

## gen-pr vs gen-test 비교표

| 항목 | gen-pr | gen-test |
|------|--------|----------|
| 트리거 | 파수꾼 (GitHub 이벤트) | 왕 (cron 스케줄) |
| 파수꾼 관여 | O (이벤트 감지) | X |
| queue/events/ 사용 | O | X (schedule-... ID만) |
| 이벤트 타입 | github.pr.review_requested 등 | test-coverage-analysis |
| CC Plugin | friday (기존) | test-runner (신규) |
| timeout | 1800초 (30분) | 3600초 (60분) |
| 결과물 | GitHub PR 코멘트 | 테스트 코드 + PR 생성 |
| 빈도 | PR 발생 시마다 (수시) | 매주 1회 (스케줄) |
| priority | normal (기본) | low (스케줄 기본값) |
| 작업 없는 경우 | 해당 없음 (이벤트 있으면 항상 작업) | 커버리지 충족 시 "작업 없음" success |

---

## Scenario A: Happy Path — 스케줄 트리거 → 테스트 작성 → PR 생성

**전제**: 매주 월요일 03:00, querypie/frontend에 커버리지 72% 모듈 존재

### Phase 1: 스케줄 트리거 (왕)

```
T+0s (월요일 03:00:00)
        왕 check_general_schedules() (60초 주기)
        → config/generals/gen-test.yaml 읽기
        → schedules[0]: cron "0 3 * * 1"
        → cron_matches("0 3 * * 1") = true (월요일 03:00)
        → already_triggered_today("test-coverage-check") 확인
          → state/king/schedule-sent.json 읽기
          → { "test-coverage-check": "2026-02-03" } → 오늘(02-10)이 아님 → false
        → get_resource_health() = "green" → 수용 가능
        → sessions.json wc -l = 0 < max_soldiers(3) → 수용 가능

T+0s    왕 dispatch_scheduled_task()
        → task-seq 증분
        → 쓰기: queue/tasks/pending/task-20260210-001.json
          {
            "id": "task-20260210-001",
            "event_id": "schedule-test-coverage-check",
            "target_general": "gen-test",
            "type": "test-coverage-analysis",
            "repo": null,
            "payload": {
              "repos": ["querypie/frontend", "querypie/backend"],
              "target": "coverage < 80% 인 모듈"
            },
            "priority": "low",
            "status": "pending"
          }
        → schedule-sent.json 갱신: { "test-coverage-check": "2026-02-10" }

T+0s    왕 create_thread_start_message()
        → 쓰기: queue/messages/pending/msg-20260210-001.json
          { "type": "thread_start",
            "content": "[시작] test-coverage-analysis (스케줄: test-coverage-check)" }
```

**※ 파수꾼은 이 흐름에 관여하지 않음** — 이벤트 큐(queue/events/)도 사용되지 않음.

### Phase 2: Slack 알림 (사절)

```
T+~5s   사절 → Slack #dev-eddy에 스레드 시작
        → thread_mappings에 task-20260210-001 등록
```

### Phase 3: 작업 수행 (장군 → 병사)

```
T+~10s  장군(gen-test) pick_next_task("gen-test")
        → task-20260210-001.json 발견, mv → in_progress/

T+~10s  장군 ensure_workspace("gen-test", null)
        → repo = null이므로 payload.repos에서 대상 결정
        → workspace/gen-test/ 준비
        → workspace/gen-test/frontend/ clone/fetch
        → workspace/gen-test/backend/ clone/fetch
        → .claude/plugins.json: test-runner 플러그인 설정

T+~11s  장군 load_domain_memory("gen-test")
        → memory/generals/gen-test/ 읽기:
          - frameworks.md (Jest, Vitest 설정)
          - patterns.md (효과적 테스트 패턴)
          - coverage-rules.md (커버리지 기준)
          - learned-patterns.md (이전 학습)

T+~12s  장군 build_prompt()
        → 템플릿: config/generals/templates/gen-test.md (install-general.sh가 설치한 런타임 파일)
        → 프롬프트 핵심 내용:
          "대상 레포의 커버리지 < 80% 모듈을 분석하고,
           테스트를 작성하고, 실행하여 커버리지를 개선하고,
           PR을 생성하라."
        → 쓰기: state/prompts/task-20260210-001.md

T+~13s  장군 spawn_soldier → tmux 세션 생성
        장군 wait_for_soldier (timeout: 3600초)
```

### Phase 4: 병사 실행 (Claude Code)

```
T+~13s ~ T+~420s  병사 (claude -p)
        → workspace/gen-test/ 에서 실행
        → test-runner 플러그인 자동 로드

        작업 순서:
        1. querypie/frontend에서 커버리지 분석
           → npx jest --coverage --json
           → coverage < 80% 모듈 식별: src/components/Button (62%), src/utils/format (55%)

        2. querypie/backend에서 커버리지 분석
           → 모든 모듈 80% 이상 → 스킵

        3. frontend 대상 테스트 작성
           → src/components/Button.test.tsx (15개 테스트 추가)
           → src/utils/format.test.ts (10개 테스트 추가)

        4. 테스트 실행 & 검증
           → npx jest --coverage → Button 85%, format 82%

        5. 브랜치 생성 & PR
           → git checkout -b test/improve-coverage-20260210
           → git add & commit
           → gh pr create --title "test: improve coverage for Button, format"

        6. 결과 저장:
           state/results/task-20260210-001-raw.json
           {
             "task_id": "task-20260210-001",
             "soldier_id": "soldier-1707530413-8901",
             "status": "success",
             "summary": "frontend 2개 모듈 테스트 추가, 커버리지 62%→85%, 55%→82%. PR #5678 생성",
             "details": {
               "modules_tested": ["src/components/Button", "src/utils/format"],
               "tests_added": 25,
               "coverage_before": { "Button": 62, "format": 55 },
               "coverage_after": { "Button": 85, "format": 82 },
               "pr_number": 5678,
               "pr_url": "https://github.com/querypie/frontend/pull/5678",
               "backend_skipped": true,
               "backend_reason": "모든 모듈 80% 이상"
             },
             "metrics": { "duration_seconds": 407, "tokens_used": 58000 },
             "memory_updates": [
               "frontend의 Button 컴포넌트는 render props 패턴 사용 — mock 시 주의",
               "format.ts는 순수 함수 — 단위 테스트만으로 충분"
             ],
             "completed_at": "2026-02-10T03:07:00Z"
           }
```

### Phase 5: 결과 처리 (장군 → 왕 → 사절)

```
T+~420s  장군 wait_for_soldier 탈출
         → status = "success"
         → update_memory():
           memory/generals/gen-test/learned-patterns.md에 append
         → report_to_king()

T+~430s  왕 check_task_results()
         → handle_success():
           - complete_task (in_progress → completed)
           - 스케줄 작업이므로 이벤트 이동은 없음 (event_id = schedule-...)
           - 사절 알림: "[완료] 테스트 커버리지 개선 — PR #5678"

T+~435s  사절 → Slack 스레드에 완료 알림 + thread_mapping 제거
```

**최종 상태**:
- `queue/tasks/completed/task-20260210-001.json` (7일 후 삭제)
- `state/results/task-20260210-001.json` + `-raw.json` (7일 후 삭제)
- GitHub에 PR #5678 생성됨
- Slack에 스레드: [시작] → [완료]
- `schedule-sent.json`: `{ "test-coverage-check": "2026-02-10" }` (다음 주까지 재트리거 방지)

---

## Scenario B: 커버리지 이미 충분할 때

**전제**: 모든 모듈이 이미 80% 이상

```
T+~13s ~ T+~60s  병사 실행
        → frontend 커버리지 분석 → 전체 82% 이상
        → backend 커버리지 분석 → 전체 85% 이상
        → 테스트 작성할 대상 없음

        결과:
        {
          "status": "success",
          "summary": "모든 대상 레포의 커버리지가 80% 이상. 추가 작업 없음.",
          "details": {
            "modules_tested": [],
            "tests_added": 0,
            "all_above_threshold": true
          },
          "memory_updates": []
        }

T+~70s  왕 → 완료 처리
        사절 → Slack: "[완료] 커버리지 점검 완료 — 모든 모듈 기준 충족, 작업 없음"
```

**※ PR이 생성되지 않는 정상 케이스** — 병사가 "할 일 없음"을 판단하고 success로 보고.

---

## Scenario C: 테스트 실행 실패 → 재시도 → 성공

```
T+~300s  1차 시도 결과:
         { "status": "failed", "error": "npm install failed: ENOSPC" }

T+~300s  장군 재시도 (attempt 0→1)
         → sleep 60 (backoff)
         → 2차 시도 (내관이 그 사이 디스크 정리했을 수 있음)

T+~480s  2차 시도 결과:
         { "status": "success", ... }

→ 이후 Scenario A Phase 5와 동일
```

---

## Scenario D: needs_human — 테스트 범위 판단 필요

**전제**: 커버리지 기준 미달 모듈이 30개 이상

```
T+~120s  병사 분석 결과:
         커버리지 < 80% 모듈이 32개 발견
         → 전부 처리하면 PR이 거대해짐 (2000줄+)
         → 판단 요청

         결과:
         {
           "status": "needs_human",
           "question": "커버리지 미달 모듈이 32개입니다. 전체 처리 시 PR 규모가 큽니다. 상위 5개 모듈만 처리할까요, 전체를 처리할까요?",
           "summary": "사람의 판단 필요 — 테스트 대상 범위"
         }

→ 이후 gen-pr Scenario B와 동일 흐름:
  장군 escalate → 왕 handle_needs_human → 사절 Slack 질문
  → 사람 응답 → 사절 이벤트 생성 → 왕 resume 작업 생성 → 장군 재실행
```

(needs_human 전체 흐름은 [scenario-gen-pr.md](scenario-gen-pr.md) Scenario B 참조)

---

## Scenario E: 스케줄 중복 실행 방지

```
T+0s (월요일 03:00:00)
     왕 check_general_schedules()
     → cron 매칭 → 작업 생성
     → schedule-sent.json: { "test-coverage-check": "2026-02-10" }

T+60s (월요일 03:01:00)
     왕 check_general_schedules() (다음 주기)
     → cron 매칭 (03시 분 내)
     → already_triggered_today("test-coverage-check") = true
     → SKIP — 이미 오늘 실행됨

T+86400s (화요일 03:00:00)
     → cron "0 3 * * 1" → 화요일이므로 매칭 안됨 → SKIP
```

---

## 열린 질문 (구현 시 결정 필요)

1. **다중 레포 처리**: payload.repos에 여러 레포가 있을 때, 병사 1명이 순차 처리? 아니면 레포별로 별도 작업 생성?
2. **CC Plugin 실체**: test-runner 플러그인을 기존 saturday 플러그인에서 확장? 아니면 완전 신규 작성?
3. **추가 스케줄 가능성**: 현재 주 1회 커버리지 점검만 정의. regression test, flaky test 감지 등 추가?
4. **gen-pr과의 연동**: gen-pr이 리뷰한 PR에 새 커밋이 push되면 재리뷰하는 시나리오 추가?

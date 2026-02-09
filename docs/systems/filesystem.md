# 파일 시스템 구조

> 디렉토리가 곧 상태이고, 파일이 곧 메시지이다.

## 전체 디렉토리 트리

```
/opt/lil-eddy/
│
├── bin/                              # 실행 스크립트
│   ├── start.sh                      # 전체 시스템 시작 + 필수 세션 watchdog (60초)
│   ├── stop.sh                       # 전체 시스템 중지
│   ├── status.sh                     # 시스템 상태 확인
│   │
│   ├── sentinel.sh                   # 파수꾼 메인 루프
│   ├── king.sh                       # 왕 메인 루프
│   ├── envoy.sh                      # 사절 메인 루프
│   ├── chamberlain.sh                # 내관 메인 루프
│   ├── spawn-soldier.sh              # 병사 생성기
│   │
│   ├── generals/                     # 장군별 스크립트
│   │   ├── gen-pr.sh
│   │   ├── gen-test.sh
│   │   └── gen-jira.sh
│   │
│   └── lib/                          # 공통 라이브러리
│       ├── common.sh                 # 공통 함수 (log, get_config, update_heartbeat, emit_event, emit_internal_event)
│       ├── sentinel/
│       │   ├── watcher-common.sh
│       │   ├── github-watcher.sh
│       │   └── jira-watcher.sh
│       ├── king/
│       │   ├── router.sh
│       │   └── resource-check.sh
│       ├── general/
│       │   ├── common.sh
│       │   ├── prompt-builder.sh
│       │   └── quality-gate.sh
│       ├── soldier/                  # (현재 빈 디렉토리 — 향후 확장용)
│       ├── envoy/
│       │   ├── slack-api.sh              # Slack API 공통 함수
│       │   ├── thread-manager.sh         # 스레드 매핑, awaiting 관리
│       │   └── report-generator.sh
│       └── chamberlain/
│           ├── metrics-collector.sh
│           ├── session-checker.sh
│           ├── event-consumer.sh          # 내부 이벤트 소비, 메트릭 집계, 이상 감지
│           ├── auto-recovery.sh
│           └── log-rotation.sh
│
├── config/                           # 설정 파일
│   ├── system.yaml                   # 전체 시스템 설정
│   ├── sentinel.yaml                 # 파수꾼 설정
│   ├── king.yaml                     # 왕 설정 (재시도, 동시성, 인터벌)
│   ├── generals/                     # 장군 매니페스트 (플러거블)
│   │   ├── gen-pr.yaml               # PR 리뷰 장군 (subscribes, schedules)
│   │   ├── gen-jira.yaml             # Jira 구현 장군
│   │   ├── gen-test.yaml             # 테스트 작성 장군
│   │   └── templates/                # 프롬프트 템플릿 (장군별)
│   │       ├── gen-pr.md             # PR 리뷰 프롬프트 템플릿
│   │       ├── gen-jira.md           # Jira 구현 프롬프트 템플릿
│   │       ├── gen-test.md           # 테스트 작성 프롬프트 템플릿
│   │       └── default.md            # 기본 프롬프트 템플릿
│   ├── envoy.yaml                    # 사절 설정 (Slack 채널)
│   └── chamberlain.yaml              # 내관 설정 (임계값)
│
├── queue/                            # 메시지 큐 (파일 기반)
│   ├── events/                       # 파수꾼 → 왕
│   │   ├── pending/
│   │   ├── dispatched/
│   │   └── completed/
│   ├── tasks/                        # 왕 → 장군
│   │   ├── pending/
│   │   ├── in_progress/
│   │   └── completed/
│   └── messages/                     # 왕/장군/내관 → 사절
│       ├── pending/
│       └── sent/
│
├── state/                            # 상태 저장소
│   ├── resources.json                # 현재 리소스 (내관 갱신)
│   ├── sessions.json                 # 활성 병사 세션 레지스트리 (장군 등록, 내관 정리)
│   ├── prompts/                      # 장군이 조립한 프롬프트 (임시)
│   │   └── {task-id}.md
│   ├── results/                      # 작업 결과
│   │   ├── {task-id}.json            # 최종 결과 (장군 → 왕)
│   │   └── {task-id}-raw.json        # 병사 원본 결과 (장군만 읽음)
│   ├── king/                         # 왕 상태
│   │   ├── heartbeat                 # 생존 확인
│   │   ├── task-seq                  # Task ID 시퀀스 (date:seq, 재시작 안전)
│   │   ├── msg-seq                   # Message ID 시퀀스 (date:seq, 재시작 안전)
│   │   └── schedule-sent.json        # 스케줄 트리거 기록 (중복 실행 방지)
│   ├── sentinel/                     # 파수꾼 상태
│   │   ├── heartbeat                 # 생존 확인 (내관이 mtime 체크)
│   │   ├── github-state.json         # ETag 등 GitHub 폴링 상태
│   │   ├── jira-state.json           # last_check, known_issues
│   │   └── seen/                     # 중복 방지 인덱스 (빈 파일, 30일)
│   ├── envoy/                        # 사절 상태
│   │   ├── heartbeat                 # 생존 확인
│   │   ├── thread-mappings.json      # task_id ↔ thread_ts 매핑
│   │   ├── awaiting-responses.json   # needs_human 응답 대기 스레드 목록
│   │   └── report-sent.json          # 리포트 발송 기록 (중복 발송 방지)
│   └── chamberlain/                  # 내관 상태
│       ├── events-offset             # events.log 마지막 읽은 라인 번호 (커서)
│       ├── daily-cleanup             # 만료 파일 정리 마지막 실행일
│       ├── daily-daily-report        # 일일 리포트 마지막 실행일
│       └── daily-events-rotation     # events.log 로테이션 마지막 실행일
│
├── memory/                           # 영구 메모리
│   ├── shared/
│   │   ├── project-context.md
│   │   └── decisions.md
│   └── generals/
│       ├── pr-review/
│       ├── test-code/
│       └── jira-ticket/
│
├── logs/                             # 로그
│   ├── system.log                    # 텍스트 로그 (log 함수)
│   ├── events.log                    # 내부 이벤트 (JSONL, emit_internal_event)
│   ├── tasks.log
│   ├── metrics.log
│   ├── sessions/
│   │   └── {session-name}.log
│   └── analysis/                     # 자동 분석 결과
│       ├── failures.json
│       └── stats.json
│
├── workspace/                        # 코드 작업 공간 (장군별 격리)
│   ├── gen-pr/                       # 자동 생성 (ensure_workspace)
│   │   ├── .claude/
│   │   │   └── plugins.json          # friday plugin 참조 (자동 생성)
│   │   ├── CLAUDE.md                 # gen-pr 도메인 컨텍스트 (선택)
│   │   ├── querypie-frontend/        # 자동 클론
│   │   └── querypie-backend/
│   ├── gen-jira/
│   │   ├── .claude/
│   │   │   └── plugins.json          # sunday plugin 참조 (자동 생성)
│   │   └── ...
│   └── gen-test/
│       ├── .claude/
│       │   └── plugins.json          # test plugin 참조 (자동 생성)
│       └── ...
│
└── plugins/                          # Claude Code 플러그인
    ├── friday/
    ├── saturday/
    ├── sunday/
    └── lil-eddy/                     # 전용 플러그인
```

## 디렉토리별 역할 접근 권한

| 디렉토리 | 파수꾼 | 왕 | 장군 | 병사 | 사절 | 내관 |
|----------|--------|-----|------|------|------|------|
| config/generals/ | - | R | - | - | - | - |
| queue/events/ | W | R/W | - | - | W | - |
| queue/tasks/ | - | W | R/W | - | R | - |
| queue/messages/ | - | W | W | - | R/W | W |
| state/sessions.json | - | R | W | - | - | R/W |
| state/resources.json | - | R | R | - | - | W |
| state/prompts/ | - | - | W | R | - | - |
| state/results/ | - | R | W | W | - | R |
| state/king/ | - | R/W | - | - | - | R |
| state/envoy/ | - | - | - | - | R/W | R |
| state/chamberlain/ | - | - | - | - | - | R/W |
| memory/shared/ | - | R | R | R | - | - |
| memory/generals/ | - | - | R/W | R/W | - | - |
| logs/ | W | W | W | W | W | W |
| workspace/{general}/ | - | - | R/W | R/W | - | - |

W=쓰기, R=읽기, R/W=읽기+쓰기, -=접근 안함

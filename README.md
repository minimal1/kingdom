# Kingdom

> "주니어 시절의 나를 만들어, 쉴새없이 일하게 한다"

EC2 인스턴스 위에서 Claude Code 기반의 자율적인 개발 작업자를 운영하는 시스템.
GitHub PR 리뷰, Jira 티켓 구현, 테스트 코드 작성 등의 개발 업무를 자동으로 감지하고 수행한다.

## Architecture

6개의 역할이 파일 기반 메시지 패싱으로 협력한다:

| 역할 | 영문 | 하는 일 |
|------|------|---------|
| 파수꾼 | Sentinel | 외부 이벤트 감지 (GitHub, Jira polling) |
| 왕 | King | 이벤트 분류, 작업 배정, 리소스 관리 |
| 장군 | General | 도메인별 작업 관리, 프롬프트 조립, 병사 생성 |
| 병사 | Soldier | Claude Code `-p`로 실제 코드 작업 수행 (일회성) |
| 사절 | Envoy | Slack을 통한 사람과의 소통 전담 |
| 내관 | Chamberlain | 시스템 모니터링, 로그 관리, 자동 복구 |

```
GitHub/Jira ──→ 파수꾼 ──→ [queue/events/pending/]
                                    │
                              왕 (King)
                         라우팅 + 태스크 생성
                                    │
                      [queue/tasks/pending/] ──→ 장군 (General)
                                                   │
                                              프롬프트 조립
                                                   │
                                              병사 (Soldier)
                                           claude -p 실행
                                                   │
                                        [state/results/*.json]
                                                   │
                              왕 ──→ [queue/messages/pending/] ──→ 사절 ──→ Slack
                                                                     │
                              내관: 헬스체크, 로그 로테이션, 자동 복구
```

## Tech Stack

| 분류 | 기술 |
|------|------|
| AI | Claude Code (headless `-p` 모드, OAuth 인증) |
| 세션 관리 | tmux |
| 스크립트 | Bash |
| 메시지 큐 | File-based MQ (JSON, 디렉토리 이동 = 상태 전이) |
| 외부 소통 | Slack Web API (curl) |
| 코드 관리 | GitHub CLI (`gh`) |
| 이슈 추적 | Jira REST API (curl) |
| 설정 | YAML (`yq`) |
| 테스트 | bats-core + bats-assert |

## Design Principles

- **Polling, not Webhook** -- 외부 서버 노출 없이 안전하게 이벤트 감지
- **파일 기반 JSON** -- 디렉토리 위치가 곧 상태 (`pending/` → `completed/`)
- **Atomic Write** -- Write-then-Rename 패턴으로 파일 손상 방지
- **단순성 우선** -- Redis, RabbitMQ 등 외부 의존성 없음
- **최소 외부 의존성** -- Bash, jq, yq, tmux, Claude Code만으로 동작
- **플러거블 장군** -- YAML 매니페스트로 새 장군 추가 가능
- **macOS/Linux 호환** -- portable wrapper (date, stat, flock)

## Project Structure

```
kingdom/
├── bin/                        # 실행 스크립트
│   ├── start.sh / stop.sh / status.sh   # 시스템 관리
│   ├── init-dirs.sh                     # 디렉토리 초기화
│   ├── check-prerequisites.sh           # 환경 검증
│   ├── sentinel.sh                      # 파수꾼 메인 루프
│   ├── king.sh                          # 왕 메인 루프
│   ├── envoy.sh                         # 사절 메인 루프
│   ├── chamberlain.sh                   # 내관 메인 루프
│   ├── spawn-soldier.sh                 # 병사 생성 (tmux + claude -p)
│   ├── generals/                        # 장군 엔트리포인트
│   │   ├── gen-pr.sh                    #   PR 리뷰
│   │   ├── gen-jira.sh                  #   Jira 티켓 구현
│   │   └── gen-test.sh                  #   테스트 작성
│   └── lib/                             # 공유 라이브러리
│       ├── common.sh                    #   로깅, 이벤트, 플랫폼 유틸
│       ├── sentinel/                    #   watcher-common, github/jira-watcher
│       ├── king/                        #   router, resource-check
│       ├── general/                     #   common, prompt-builder
│       ├── envoy/                       #   slack-api, thread-manager
│       └── chamberlain/                 #   metrics, sessions, events, logs, recovery
│
├── config/                     # 설정 (YAML)
│   ├── system.yaml / king.yaml / sentinel.yaml / envoy.yaml / chamberlain.yaml
│   └── generals/               # 장군 매니페스트 + 프롬프트 템플릿
│       ├── gen-pr.yaml / gen-jira.yaml / gen-test.yaml
│       └── templates/          # default.md, gen-pr.md, gen-jira.md, gen-test.md
│
├── tests/                      # 테스트 (bats-core)
│   ├── test_helper.bash        # 공통 setup/teardown
│   ├── mocks/                  # gh, curl, tmux, claude, yq, git
│   ├── fixtures/               # 테스트 JSON 데이터
│   ├── test_*.sh               # 단위 테스트 (역할별)
│   ├── lib/                    # 라이브러리 단위 테스트
│   │   ├── sentinel/ king/ general/ envoy/ chamberlain/
│   │   └── test_common.sh
│   └── integration/            # 통합 테스트 (E2E 흐름)
│
├── docs/                       # 문서
│   ├── guides/                 # 운영 가이드 (현행)
│   ├── spec/                   # 설계 명세 (구현 기준)
│   └── archive/                # 히스토리 (참고용)
│
└── (런타임 디렉토리 — init-dirs.sh가 생성)
    ├── queue/                  # 파일 기반 메시지 큐
    ├── state/                  # 상태 저장소
    ├── memory/                 # 장군별 학습 메모리
    ├── logs/                   # 시스템 로그
    ├── workspace/              # 코드 작업 공간
    └── plugins/                # CC 플러그인
```

## Requirements

| 항목 | 스펙 |
|------|------|
| EC2 Instance | M5.xlarge (4 vCPU, 16GB RAM) 또는 macOS Apple Silicon |
| Storage | 100GB GP3 SSD |
| OS | Amazon Linux 2023, Ubuntu 22.04+, macOS 14+ |
| Software | Claude Code, tmux, Git, gh CLI, jq, yq (mikefarah), bc, Node.js 22+ |
| 인증 | Claude OAuth (Max Plan), GitHub (`gh auth`), Jira API Token, Slack Bot Token |

## Quick Start

```bash
# 1. 소스 배포
cp -r bin config /opt/kingdom/
chmod +x /opt/kingdom/bin/*.sh /opt/kingdom/bin/generals/*.sh

# 2. 디렉토리 초기화
/opt/kingdom/bin/init-dirs.sh

# 3. 환경 검증
/opt/kingdom/bin/check-prerequisites.sh

# 4. 시작
/opt/kingdom/bin/start.sh

# 5. 상태 확인
/opt/kingdom/bin/status.sh
```

자세한 설치 가이드: [`docs/guides/install-guide.md`](docs/guides/install-guide.md)

## Tests

```bash
# 전체 테스트 (208개)
bats tests/test_*.sh tests/lib/*/test_*.sh tests/integration/test_*.sh
```

| 영역 | 테스트 수 |
|------|----------|
| 공통 라이브러리 + 초기화 | 21 |
| 파수꾼 (Sentinel) | 15 |
| 사절 (Envoy) | 17 |
| 왕 (King) | 30 |
| 장군 + 병사 | 28 |
| 내관 (Chamberlain) | 46 |
| 시스템 스크립트 | 14 |
| 통합 테스트 (E2E) | 13 |
| **합계** | **208** (macOS/Linux) |

## Documentation

```
docs/
├── guides/                         # 운영 가이드 (현행)
│   ├── install-guide.md            #   Linux/macOS 설치 (systemd, launchd)
│   └── local-install-guide.md      #   로컬 개발 테스트
│
├── spec/                           # 설계 명세 (구현 기준)
│   ├── architecture.md             #   전체 아키텍처
│   ├── roles/                      #   역할 스펙 (6종)
│   ├── systems/                    #   시스템 설계 (7종)
│   └── examples/                   #   장군 동작 시나리오
│
└── archive/                        # 히스토리 (참고용, 실제와 다를 수 있음)
    ├── confluence/                  #   컨셉/동작 구상 초안
    └── infra/                      #   EC2 설정 초안, 로드맵
```

## Status

**구현 완료** -- 208개 테스트 통과, EC2 배포 준비 완료.

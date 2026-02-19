# Kingdom

> 빈 컴퓨터 한 대에 정착하여, 팀의 일원으로 일하는 AI 동료

GitHub·Jira·Slack을 통해 업무를 감지하고, 장군 패키지로 정의된 역할에 따라 자율적으로 작업한다.
모르면 사람에게 물어보고, 일하며 배운 것은 메모리에 축적하여 점점 더 잘 일한다.

**핵심 가치**: 자율성 (이벤트 감지 → 판단 → 실행) · 소통 (Slack 양방향) · 성장 (3계층 메모리)

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
├── generals/                      # 장군 패키지 (소스)
│   ├── gen-pr/                    #   manifest.yaml + prompt.md + install.sh
│   ├── gen-jira/
│   └── gen-test/
│
├── config/                     # 설정 (YAML)
│   ├── system.yaml / king.yaml / sentinel.yaml / envoy.yaml / chamberlain.yaml
│   └── generals/               # 장군 매니페스트 (install-general.sh가 설치)
│       └── templates/          # default.md (fallback)
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
    └── workspace/              # 코드 작업 공간
```

## Requirements

| 항목 | 스펙 |
|------|------|
| EC2 Instance | M5.xlarge (4 vCPU, 16GB RAM) 또는 macOS Apple Silicon |
| Storage | 100GB GP3 SSD |
| OS | Amazon Linux 2023, Ubuntu 22.04+, macOS 14+ |
| Software | Claude Code, tmux, Git, gh CLI, jq, yq, bc, Node.js 22+ (mise로 관리) |
| 인증 | Claude OAuth (Max Plan), GitHub (`gh auth`), Jira API Token, Slack Bot Token |

## Quick Start

```bash
# 1. 소스 배포
DEST="${KINGDOM_BASE_DIR:-/opt/kingdom}"
cp -r bin config "$DEST/"
chmod +x "$DEST"/bin/*.sh

# 2. 디렉토리 초기화
"$DEST/bin/init-dirs.sh"

# 3. 빌트인 장군 설치
for pkg in generals/gen-*; do
  "$DEST/bin/install-general.sh" "$pkg"
done

# 4. 환경 검증
"$DEST/bin/check-prerequisites.sh"

# 5. 시작
"$DEST/bin/start.sh"
```

자세한 설치 가이드: [`docs/guides/install-guide.md`](docs/guides/install-guide.md)

## Tests

```bash
# 전체 테스트 (223개)
bats tests/test_*.sh tests/lib/*/test_*.sh tests/integration/test_*.sh
```

| 영역 | 테스트 수 |
|------|----------|
| 공통 라이브러리 + 초기화 | 22 |
| 설치/제거 | 14 |
| 파수꾼 (Sentinel) | 15 |
| 사절 (Envoy) | 17 |
| 왕 (King) | 30 |
| 장군 + 병사 | 28 |
| 내관 (Chamberlain) | 46 |
| 시스템 스크립트 | 14 |
| 통합 테스트 (E2E) | 13 |
| **합계** | **223** (macOS/Linux) |

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

## Identity

Kingdom은 단순한 작업 자동화가 아니라, **판단이 필요한 업무를 수행하는 AI 팀 동료**다.

| 기존 자동화 (CI/CD, GitHub Actions) | Kingdom |
|-------------------------------------|---------|
| 규칙 기반 (if-then) | LLM 추론 기반 |
| 코드를 실행 | 코드를 읽고/쓰고/판단 |
| 빌드·테스트·배포 파이프라인 | 사고가 필요한 작업 (리뷰, 구현, 테스트 작성) |
| 트리거 → 고정 동작 | 트리거 → 맥락 이해 → 동적 대응 |
| 메모리 없음 | 3계층 메모리로 경험 축적 |

현재는 소프트웨어 개발 작업(PR 리뷰, Jira 구현, 테스트 작성)에 집중하지만,
장군 패키지 시스템은 도메인 무관하게 설계되어 지식 노동 전반으로 확장 가능하다.

## Status

**구현 완료** -- 232개 테스트 통과, EC2 배포 준비 완료.

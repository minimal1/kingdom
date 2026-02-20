# Kingdom

> **빈 컴퓨터 한 대에 정착하여, 팀의 일원으로 일하는 AI 동료**

Kingdom은 GitHub·Jira·Slack을 감시하며 스스로 일감을 찾아 처리하는 자율형 AI 시스템이다.
PR이 올라오면 리뷰하고, Jira 티켓이 할당되면 구현하고, 모르는 건 Slack으로 물어본다.
일하며 배운 것은 메모리에 축적하여, 점점 더 잘 일한다.

```
 ┌─────────────────────────────────────────────────────────┐
 │  GitHub PR opened  ──→  파수꾼이 감지                     │
 │                         왕이 판단: "gen-pr 장군에게"       │
 │                         장군이 프롬프트 조립               │
 │                         병사가 리뷰 수행 (Claude Code)     │
 │                         결과를 Slack으로 보고              │
 │                                                          │
 │  전체 소요: 사람 개입 0                                    │
 └─────────────────────────────────────────────────────────┘
```

## Why Kingdom?

| 기존 자동화 (CI/CD, GitHub Actions) | Kingdom |
|-------------------------------------|---------|
| 규칙 기반 (if-then) | LLM 추론 기반 |
| 코드를 실행 | 코드를 **읽고·쓰고·판단** |
| 빌드→테스트→배포 파이프라인 | 리뷰, 구현, 테스트 작성 등 **사고가 필요한 작업** |
| 트리거 → 고정 동작 | 트리거 → 맥락 이해 → 동적 대응 |
| 메모리 없음 | 3계층 메모리로 경험 축적 |

현재는 소프트웨어 개발(PR 리뷰, Jira 구현, 테스트 작성)에 집중하지만,
장군 패키지 시스템은 도메인 무관하게 설계되어 **지식 노동 전반으로 확장** 가능하다.

## Architecture

6개의 역할이 파일 기반 메시지 패싱으로 협력한다:

```
  GitHub/Jira ──→ 파수꾼(Sentinel) ──→ [이벤트 큐]
                                            │
                                       왕(King)
                                   라우팅 + 태스크 생성
                                            │
                                    [태스크 큐] ──→ 장군(General)
                                                      │
                                                 Soul + 프롬프트 조립
                                                      │
                                                 병사(Soldier)
                                              claude -p 실행
                                                      │
                                               [결과 JSON]
                                                      │
                             왕 ──→ [메시지 큐] ──→ 사절(Envoy) ──→ Slack
                                                        │
                             내관(Chamberlain): 헬스체크, 로그, 자동 복구
```

| 역할 | 하는 일 |
|------|---------|
| **파수꾼** Sentinel | GitHub·Jira 폴링으로 외부 이벤트 감지 |
| **왕** King | 이벤트 분류, 장군 라우팅, 작업 배정 |
| **장군** General | 도메인 전문가 — Soul 주입 + 프롬프트 조립 + 병사 관리 |
| **병사** Soldier | Claude Code `-p` 모드로 실제 작업 수행 (일회성) |
| **사절** Envoy | Slack 양방향 소통 전담 (재시도 + 실패 격리) |
| **내관** Chamberlain | 시스템 모니터링, 로그 로테이션, 세션 관리 |

## Key Features

### Soul System — 아이덴티티 계층

병사는 "내가 누구인지" 알고 일한다. 3계층 Soul이 모든 세션에 자동 주입된다:

```
config/soul.md            → 공통 원칙 (모든 병사)
generals/gen-*/soul.md    → 장군별 성격 (해당 병사만, 선택적)
config/user.md            → 팀/회사 맥락 (모든 병사)
```

### General Packages — 플러거블 도메인 전문가

장군은 5파일로 자기완결적인 패키지다. 새 도메인은 패키지 추가만으로 확장된다:

```
generals/gen-{name}/
├── manifest.yaml   # 이벤트 구독, 스케줄, 메타데이터
├── prompt.md       # 병사 프롬프트 템플릿
├── soul.md         # 장군 고유 성격 (선택적)
├── install.sh      # 설치 스크립트
└── README.md       # 문서
```

**빌트인 장군**: `gen-pr` (PR 리뷰) · `gen-jira` (Jira 구현) · `gen-test` (테스트 작성) · `gen-briefing` (일일 브리핑)

### 3-Layer Memory — 경험으로 성장

```
Session Memory   → 병사 실행 중 임시 컨텍스트
Task Memory      → 작업 단위 결과·교훈 보존
Shared Memory    → 장군 도메인별 장기 지식 축적
```

병사가 작업 완료 시 `memory_updates[]`로 교훈을 기록하면, 같은 장군의 다음 병사가 이를 참조한다.

### File-based MQ — 외부 의존성 제로

```
queue/events/pending/   → (파수꾼 write)  → (왕 read)    → completed/
queue/tasks/pending/    → (왕 write)      → (장군 read)  → completed/
queue/messages/pending/ → (왕 write)      → (사절 read)  → sent/ | failed/
```

디렉토리 위치가 곧 상태. `cat`/`ls`로 즉시 디버깅 가능.
Write-then-Rename 원자성, 실패 메시지 재시도(3회), 영구 실패 격리.

## Design Principles

- **Polling, not Webhook** — 외부 서버 노출 없이 안전하게 이벤트 감지
- **파일이 곧 상태** — Redis, RabbitMQ 없이 디렉토리 이동으로 상태 전이
- **최소 의존성** — Bash, jq, yq, tmux, Claude Code만으로 동작
- **Schema-First** — JSON Schema가 진실의 소스, 하위 레이어 종속
- **macOS/Linux 호환** — portable wrapper (date, stat, flock)

## Tech Stack

| 분류 | 기술 |
|------|------|
| AI | Claude Code (headless `-p` 모드, OAuth 인증) |
| 세션 관리 | tmux |
| 스크립트 | Bash (macOS 3.2 호환) |
| 메시지 큐 | File-based MQ (JSON, atomic write) |
| 외부 소통 | Slack Web API |
| 코드 관리 | GitHub CLI (`gh`) |
| 이슈 추적 | Jira REST API |
| 설정 | YAML + JSON Schema |
| 테스트 | bats-core + bats-assert |

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

## Requirements

| 항목 | 스펙 |
|------|------|
| 하드웨어 | M5.xlarge (4 vCPU, 16GB) 또는 macOS Apple Silicon |
| 스토리지 | 100GB GP3 SSD |
| OS | Amazon Linux 2023, Ubuntu 22.04+, macOS 14+ |
| 소프트웨어 | Claude Code, tmux, Git, gh CLI, jq, yq, bc |
| 인증 | Claude OAuth (Max Plan), GitHub (`gh auth`), Jira API Token, Slack Bot Token |

## Tests

```bash
# 전체 테스트 (262개)
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
| 내관 (Chamberlain) | 85 |
| 시스템 스크립트 | 14 |
| 통합 테스트 (E2E) | 13 |
| **합계** | **262** |

## Documentation

| 경로 | 내용 |
|------|------|
| [`docs/guides/`](docs/guides/) | 운영 가이드 — 설치, 로컬 개발 |
| [`docs/spec/`](docs/spec/) | 설계 명세 — 아키텍처, 역할, 시스템 |
| [`docs/analysis/`](docs/analysis/) | 분석 — OpenClaw 비교, 기술 선택 근거 |
| [`docs/archive/`](docs/archive/) | 히스토리 — 컨셉 초안, 인프라 메모 |

## Project Structure

```
kingdom/
├── bin/                     # 실행 스크립트
│   ├── start.sh / stop.sh   #   시스템 관리
│   ├── sentinel.sh          #   파수꾼
│   ├── king.sh              #   왕 (thin wrapper)
│   ├── envoy.sh             #   사절
│   ├── chamberlain.sh       #   내관
│   ├── spawn-soldier.sh     #   병사 생성
│   ├── generals/            #   장군 엔트리포인트
│   └── lib/                 #   공유 라이브러리
│       ├── king/functions.sh    # 왕 함수 (테스트 가능)
│       ├── general/prompt-builder.sh  # Soul + 프롬프트 조립
│       └── ...
├── generals/                # 장군 패키지 (소스)
│   ├── gen-pr/              #   PR 리뷰
│   ├── gen-jira/            #   Jira 구현
│   ├── gen-test/            #   테스트 작성
│   └── gen-briefing/        #   일일 브리핑
├── config/                  # 설정
│   ├── soul.md / user.md    #   Soul 시스템
│   ├── *.yaml               #   역할별 설정
│   └── generals/            #   설치된 장군 매니페스트
├── schemas/                 # JSON Schema (SSOT)
├── tests/                   # 262개 테스트
└── docs/                    # 문서
```

## Status

**구현 완료** — 262개 테스트 통과, EC2 배포 준비 완료.

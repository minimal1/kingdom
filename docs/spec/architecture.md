# Kingdom - Architecture Blueprint

> 빈 컴퓨터 한 대에 정착하여, 팀의 일원으로 일하는 AI 동료

## 비전

빈 컴퓨터(EC2, Mac 등) 한 대에 셋업하면, 팀의 GitHub·Jira·Slack을 감시하며
주어진 역할(장군 패키지)에 따라 스스로 작업을 수행하는 AI 팀 동료를 만든다.
사람에게 확인이 필요하면 Slack으로 물어보고, 작업하며 배운 것은 메모리에 축적하여 점점 더 잘 일한다.
한번 쓰고 버리는 PoC가 아닌, 계속 발전시킬 장기 프로젝트이다.

### 아이덴티티의 3축

| 축 | 설명 | 구현체 |
|---|------|--------|
| **자율성** | 이벤트 감지 → 판단 → 실행 | 파수꾼 + 왕 + 장군 + 병사 |
| **소통** | 모르면 물어보고, 결과를 보고 | 사절 (Slack 양방향) |
| **성장** | 일하며 배우고, 경험을 축적 | 3계층 메모리 (Session → Task → Shared) |

### 기존 자동화와의 차이

| 기존 자동화 (CI/CD, Actions) | Kingdom |
|------------------------------|---------|
| 규칙 기반 (if-then) | LLM 추론 기반 |
| 코드를 실행 | 코드를 읽고/쓰고/판단 |
| 빌드·테스트·배포 파이프라인 | 사고가 필요한 작업 (리뷰, 구현, 테스트 작성) |
| 트리거 → 고정 동작 | 트리거 → 맥락 이해 → 동적 대응 |
| 메모리 없음 | 3계층 메모리로 경험 축적 |

### 작업 범위

현재는 소프트웨어 개발 작업에 집중하지만, 장군 패키지 시스템은 도메인 무관하게 설계되어 있다.
새 watcher(이벤트 소스)와 장군 패키지를 추가하면 지식 노동 전반으로 확장 가능하다.

## 구성 원칙

| 인간의 요소 | Kingdom 매핑 | 구현체 |
|------------|--------------|--------|
| 지능 | LLM + Prompt | Claude Code + Plugins/Skills |
| 기억 | Memory 관리 | File-based Memory + CLAUDE.md |
| 몸 | 하드웨어 | EC2 / Mac / Cloud Instance |
| 손발 | 도구 | CLI, MCP, GitHub, Jira, Slack |
| 소통 | 사절 | Slack Web API (curl) |

## 전체 아키텍처

```
        ┌──────────────────────┐               ┌──────────────────────┐
        │   External Events    │               │     Slack (사람)      │
        │   GitHub · Jira      │               │   DM · 스레드 응답     │
        └──────────┬───────────┘               └──────────┬───────────┘
                   │                                      │
                   │ events (JSON)                        │ Slack Web API (curl)
                   ▼                                      ▼
    ┌──────────────────────────────────────────────────────────────────┐
    │  🏰 EC2 Instance  (M5.xlarge)                                    │
    │                                                                   │
    │  ┌─────────────────────┐          ┌───────────────────┐          │
    │  │   tmux: sentinel    │          │  tmux: envoy      │          │
    │  │   Polling Loop      │          │  Slack Web API    │ ← 사절   │
    │  └────────┬────────────┘          └───────────────────┘          │
    │           │ event.json          ↗ queue/messages/ 감시           │
    │  ┌────────▼────────────┐  ─────┘                                 │
    │  │   tmux: king        │  ← 왕 (Orchestrator)                    │
    │  └──┬──────┬──────┬────┘                                         │
    │     │      │      │                                              │
    │  ┌──▼──┐┌──▼──┐┌──▼──┐                                          │
    │  │gen- ││gen- ││gen- │  ← 장군 (Generals)                       │
    │  │pr   ││test ││jira │                                           │
    │  └──┬──┘└──┬──┘└──┬──┘                                          │
    │     │      │      │                                              │
    │  ┌──▼──────▼──────▼──┐                                           │
    │  │  tmux: soldiers   │  ← 병사 (Workers)                        │
    │  │  Claude Code ×N   │                                           │
    │  └───────────────────┘                                           │
    │                                                                   │
    │  ┌───────────────────┐                                           │
    │  │  tmux: chamberlain│  ← 내관 (Resource Monitor)                │
    │  └───────────────────┘                                           │
    │                                                                   │
    │  📁 /opt/kingdom/                                               │
    │     ├── queue/           ← 이벤트/작업/메시지 큐                  │
    │     ├── state/           ← 상태 저장소                            │
    │     ├── logs/            ← 로그                                   │
    │     └── memory/          ← 공유 메모리                            │
    └──────────────────────────────────────────────────────────────────┘
```

## 역할 체계

| 역할 | 한글 | 영문 코드명 | tmux 세션 | 상세 문서 |
|------|------|-----------|-----------|----------|
| 외부 경계 | 파수꾼 | `sentinel` | `sentinel` | [roles/sentinel.md](roles/sentinel.md) |
| 중앙 조율 | 왕 | `king` | `king` | [roles/king.md](roles/king.md) |
| 도메인 전문가 | 장군 | `general` | `gen-{domain}` | [roles/general.md](roles/general.md) |
| 작업 실행 | 병사 | `soldier` | `soldier-{id}` | [roles/soldier.md](roles/soldier.md) |
| 대외 소통 | 사절 | `envoy` | `envoy` | [roles/envoy.md](roles/envoy.md) |
| 내부 관리 | 내관 | `chamberlain` | `chamberlain` | [roles/chamberlain.md](roles/chamberlain.md) |

## 시스템 설계

| 문서 | 내용 |
|------|------|
| [systems/message-passing.md](systems/message-passing.md) | 이벤트 큐, 작업 큐, 파일 기반 통신 |
| [systems/memory.md](systems/memory.md) | 3계층 메모리 관리 전략 |
| [systems/logging.md](systems/logging.md) | 로깅 체계 & 개선 포인트 수집 |
| [systems/data-lifecycle.md](systems/data-lifecycle.md) | 데이터 생명주기 & 정리 정책 |
| [systems/filesystem.md](systems/filesystem.md) | 디렉토리 구조 & 데이터 흐름 |
| [systems/event-types.md](systems/event-types.md) | 이벤트 타입 카탈로그 (SSOT) |
| [systems/internal-events.md](systems/internal-events.md) | 내부 이벤트 카탈로그 |

## 인프라 & 운영

| 문서 | 내용 |
|------|------|
| [infra/ec2-setup.md](infra/ec2-setup.md) | EC2 스펙, 소프트웨어, 인증, 비용 |
| [infra/roadmap.md](infra/roadmap.md) | 구현 로드맵 (Phase 1-4) |

## 핵심 설계 결정

| # | 결정 | 선택 | 이유 |
|---|------|------|------|
| 1 | tmux vs CC Native Task | **Hybrid** | tmux는 프로세스 관리, CC `-p`는 작업 실행 |
| 2 | Webhook vs Polling | **Polling** | 공개 endpoint 불필요, 인프라 단순화 |
| 3 | 역할 간 통신 | **파일 기반 JSON** | 단순, 디버깅 용이, 외부 의존성 없음 |
| 4 | 동시 실행 | **최대 3 병사** | M5.xlarge 기준 안전 마진 |
| 5 | 왕 vs 장군 분리 | **3단 계층 유지** | "무엇을/누구에게" vs "어떻게" 분리 → 확장성 |

## 작업 우선순위

1. **PR Review** (`gen-pr`) — friday 플러그인 활용
2. **Briefing** (`gen-briefing`) — 정기 시스템 상태 브리핑 (cron 스케줄)

> Jira 구현(`gen-jira`), 테스트 작성(`gen-test`)은 장군 패키지 시스템으로 추가 가능하나 builtin에서는 제외됨.

## 참고 문서

- [archive/confluence/](../archive/confluence/) — 프로젝트 초기 컨셉 문서 (히스토리, 실제와 다를 수 있음)

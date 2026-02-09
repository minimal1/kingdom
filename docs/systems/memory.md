# 메모리 관리 전략

> CC의 컨텍스트 윈도우는 유한하다. 3계층 메모리로 경험을 축적한다.

## 문제

- Claude Code의 컨텍스트 윈도우: 200K 토큰 (100K 이상에서 성능 저하)
- 병사는 일회성 → 매번 새로운 컨텍스트에서 시작
- 장군은 상주하지만 Bash loop → CC 세션이 아님
- 왕, 장군, 병사 모두 이전 작업의 교훈을 기억해야 함

## 해결: 3계층 메모리

```
┌─────────────────────────────────────────┐
│  Layer 1: Session Memory (휘발)          │
│  CC 내부 컨텍스트                         │
│  수명: 병사 세션 동안만                    │
│  관리: /compact, 자동 압축                │
├─────────────────────────────────────────┤
│  Layer 2: Task Memory (작업 단위)        │
│  state/results/{task-id}.json           │
│  수명: 작업 완료 후 7일 보관              │
│  관리: 내관이 아카이브                    │
├─────────────────────────────────────────┤
│  Layer 3: Shared Memory (영구)           │
│  memory/shared/ + memory/generals/      │
│  수명: 영구                              │
│  관리: 병사가 추가, 정기 정리             │
└─────────────────────────────────────────┘
```

## 역할별 메모리 접근

| 역할 | Layer 1 | Layer 2 | Layer 3 |
|------|---------|---------|---------|
| 왕 | - | Read (결과 확인) | Read (판단 참고) |
| 장군 | - | Read/Write | Read + Write(도메인) |
| 병사 | Own session | Read (작업 컨텍스트) | Read (프롬프트에 포함) |

## Layer 3: 공유 메모리 구조

```
memory/
├── shared/                        # 모든 역할이 읽을 수 있음
│   ├── project-context.md         # 전체 프로젝트 이해
│   └── decisions.md               # 시스템 운영 중 축적된 결정
│
└── generals/                      # 장군별 전용
    ├── pr-review/
    │   ├── patterns.md            # 공통 리뷰 패턴
    │   ├── repo-frontend.md       # querypie/frontend 컨텍스트
    │   └── repo-backend.md        # querypie/backend 컨텍스트
    │
    ├── test-code/
    │   ├── frameworks.md          # 테스트 프레임워크 정보
    │   ├── patterns.md            # 테스트 작성 패턴
    │   └── coverage-rules.md      # 커버리지 기준
    │
    └── jira-ticket/
        ├── codebase-map.md        # 코드베이스 구조
        ├── past-tickets.md        # 이전 티켓 처리 패턴
        └── conventions.md         # 컨벤션 (브랜치, 커밋 등)
```

## 메모리 갱신 흐름

```
병사 작업 완료
     │
     ├─→ state/results/{task-id}.json  (Layer 2: 결과)
     │
     └─→ memory/generals/{domain}/     (Layer 3: 새 패턴)
              │
              │  "이 레포는 barrel export를 선호하지 않음"
              │  → repo-frontend.md에 추가
              ↓
         장군이 다음 작업 시 이 메모리를 프롬프트에 포함
```

## 메모리 크기 관리

Layer 3 파일이 너무 커지면 프롬프트 토큰 낭비. 관리 규칙:

| 파일 | 최대 크기 | 초과 시 |
|------|----------|---------|
| patterns.md | 5KB | 오래된 항목 정리 |
| repo-*.md | 3KB | 핵심만 유지 |
| decisions.md | 3KB | 분기별 요약 |

## 병사에게 전달되는 메모리 구조

장군이 프롬프트를 조립할 때 메모리를 선별적으로 포함:

```
## 프로젝트 컨텍스트 (shared/project-context.md에서 발췌)
{핵심 요약만}

## 이 레포 특성 (generals/{domain}/repo-{name}.md)
{전체 포함}

## 과거 패턴 (generals/{domain}/patterns.md에서 관련 항목만)
{작업과 관련된 패턴만 선별}
```

총 토큰 예산: 프롬프트의 **20% 이내**를 메모리에 할당

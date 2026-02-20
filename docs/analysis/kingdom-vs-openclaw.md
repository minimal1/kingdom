# Kingdom vs OpenClaw — 스펙 비교 분석

> 분석 기준일: 2026-02-20
> Kingdom 버전: post-OpenClaw 개선 (262 tests)
> OpenClaw 버전: v1.1.0+ (GitHub 140k stars)

## 1. 프로젝트 포지셔닝

| 측면 | Kingdom | OpenClaw |
|------|---------|----------|
| **정체성** | 팀의 일원으로 일하는 AI 동료 | 개인형 AI 비서 |
| **대상 사용자** | 개발팀 (B2B, 회사 인프라 내 배포) | 개인 (B2C, 멀티 디바이스) |
| **배포 환경** | 전용 서버 1대 (EC2/Mac) | 사용자 디바이스 + 클라우드 |
| **핵심 가치** | 자율성 · 소통 · 성장 | 편의성 · 연결성 · 개인화 |
| **작업 도메인** | 소프트웨어 개발 (장군 패키지로 확장) | 일상 전반 (10+ 채널 통합) |

### 핵심 차이

Kingdom은 **"빈 컴퓨터 한 대에 정착하는 팀원"** 이라는 명확한 은유를 가진다.
OpenClaw는 **"모든 디바이스에서 접근 가능한 개인 비서"** 를 지향한다.

이 차이가 아래 모든 설계 결정의 근거가 된다.

---

## 2. 아키텍처 비교

### 2.1 기술 스택

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| 언어 | Bash (시스템 스크립트) | TypeScript (Node.js) |
| LLM 호출 | Claude Code `-p` 모드 | OpenAI/Anthropic API 직접 호출 |
| 프로세스 관리 | tmux 세션 | PM2 / Docker |
| 설정 형식 | YAML (6개 역할별 분리) + JSON Schema | 단일 JSON + .env |
| 의존성 | jq, yq, curl, tmux (OS 기본 도구) | Node.js, npm, 30+ packages |

**평가**: Kingdom은 외부 런타임 의존성이 없는 것이 강점. 설치 스크립트 하나로 어떤 Unix 서버에서든 동작한다. OpenClaw는 TypeScript 생태계의 풍부한 라이브러리를 활용하지만 Node.js 런타임이 필수다.

### 2.2 역할 체계

```
Kingdom (6역할 고정 계층)              OpenClaw (Gateway + 동적 세션)
─────────────────────────             ─────────────────────────
파수꾼 (이벤트 감지)                    Gateway (라우팅)
     ↓                                      ↓
왕 (라우팅 + 오케스트레이션)              Agent Session (동적 생성)
     ↓                                      ↓
장군 (도메인 전문가)                    Skill 실행 (단일 파일)
     ↓
병사 (일회성 실행)

+ 사절 (Slack 전담)                   + 10+ Channel Adapters
+ 내관 (리소스 관리)                   + Health Monitor (내장)
```

**평가**: Kingdom의 역할 분리가 더 명확하다. 각 역할의 책임이 코드와 문서에서 완전히 분리되어 있어 디버깅과 확장이 용이하다. OpenClaw는 역할 경계가 코드 레벨에서 덜 명확하지만, 동적 세션 생성으로 더 유연하다.

### 2.3 통신 방식

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| 역할 간 통신 | **파일 기반 JSON MQ** | **WebSocket Gateway** |
| 상태 추적 | 디렉토리 위치 = 상태 | 인메모리 상태 + DB |
| 원자성 | write-then-rename (`mv`) | 트랜잭션 |
| 디버깅 | `cat`, `ls`로 즉시 확인 | 로그 + 대시보드 |
| 처리량 | 분당 수~수십 건 | 초당 수백 건 |
| 실패 복구 | 파일이 남아있으면 재처리 | 재시작 시 인메모리 유실 가능 |

**평가**: Kingdom의 파일 MQ는 처리량이 낮지만, Kingdom의 유스케이스(분당 수 건의 이벤트)에는 과분할 정도로 충분하다. 파일이 곧 상태이므로 서버 재시작 후에도 메시지 유실이 없다. OpenClaw의 WebSocket은 Kingdom 스케일에서는 오버엔지니어링이다.

---

## 3. 아이덴티티 시스템 비교

### 3.1 구조

| 레이어 | Kingdom (개선 후) | OpenClaw |
|--------|------------------|----------|
| 시스템 성격 | `config/soul.md` | `SOUL.md` |
| 역할별 성격 | `generals/gen-{name}/soul.md` | `AGENTS.md` (에이전트별) |
| 사용자 맥락 | `config/user.md` | `USER.md` |
| 작업 지시 | `prompt.md` + payload | Skill 실행 시 동적 생성 |

### 3.2 Kingdom의 계층형 Soul (신규 구현)

```
[config/soul.md]               → 공통 원칙: 정확성, 최소 변경, 성장 규칙
         ↓
[generals/gen-briefing/soul.md] → F.R.I.D.A.Y. 톤, Boss 호칭
         ↓
[config/user.md]               → Chequer/QueryPie, 기술 스택, 컨벤션
         ↓
[prompt.md + payload + memory]  → 구체적 작업 지시
```

### 3.3 OpenClaw의 아이덴티티

```
[SOUL.md]     → 에이전트의 근본 성격, 말투, 가치관
[USER.md]     → 사용자 프로필, 선호도, 히스토리
[AGENTS.md]   → 멀티에이전트 역할 분담 정의
         ↓
모든 세션에 자동 주입
```

**평가**: OpenClaw에서 차용한 계층형 Soul이 Kingdom에 잘 적용되었다. 차이점은:
- Kingdom은 **장군별** 성격 분리 (gen-briefing만 F.R.I.D.A.Y. 톤)
- OpenClaw는 **에이전트별** 성격 분리 (AGENTS.md에 전부 정의)
- Kingdom의 soul.md는 **선택적** — 없으면 스킵되어 기존 장군과 100% 호환

---

## 4. 메모리 시스템 비교

### 4.1 구조

| 계층 | Kingdom | OpenClaw |
|------|---------|----------|
| **세션 메모리** | CC 내부 컨텍스트 (병사 수명) | 세션 내 대화 기록 |
| **작업 메모리** | `state/results/{task-id}.json` (7일 보관) | Daily Logs (`logs/YYYY-MM-DD.md`) |
| **영구 메모리** | `memory/generals/{domain}/` (3계층) | `MEMORY.md` + Heartbeat State |
| **크기 관리** | `head -c 50000` + 200KB 프롬프트 가드 | 컴팩션 전 메모리 플러시 |

### 4.2 메모리 성장 메커니즘

| 항목 | Kingdom (개선 후) | OpenClaw |
|------|------------------|----------|
| **성장 트리거** | 병사 result의 `memory_updates[]` | 컴팩션 전 자동 플러시 |
| **성장 규칙** | `config/soul.md`에 명시 ("배운 패턴을 기록하라") | SOUL.md에 내재 |
| **저장 위치** | `memory/generals/{domain}/learned-patterns.md` | `MEMORY.md` 파일 갱신 |
| **성장 주기** | 매 작업 완료 시 | 30분 주기 (Heartbeat) |

### 4.3 OpenClaw 전용 기법 (Kingdom 미채택, 이유 포함)

| OpenClaw 기법 | Kingdom 미채택 이유 |
|---|---|
| **컴팩션 전 플러시** | 병사가 일회성이라 컨텍스트 압축이 없음 |
| **Heartbeat 자기 점검** | 왕의 cron 스케줄이 동등 기능 수행 |
| **Daily Log 자동 생성** | 내관의 daily report + events.log이 대체 |
| **대화 요약 (chat summary)** | 병사가 단일 작업 → 대화 축적 없음 |
| **사용자 선호도 학습** | 팀 컨텍스트는 `config/user.md`에 정적 정의 |

**평가**: Kingdom의 3계층 메모리는 설계가 더 체계적이나, 개선 전에는 성장 축이 비활성 상태였다. `soul.md`에 성장 규칙을 명시하고 `memory_updates[]`를 output contract에 포함시켜 해결했다. OpenClaw의 "잊히기 전 저장" 철학은 병사 일회성 패턴에서는 불필요하다.

---

## 5. 스킬/패키지 시스템 비교

### 5.1 확장 단위

| 항목 | Kingdom 장군 패키지 | OpenClaw Skill |
|------|-------------------|----------------|
| **파일 구성** | 5파일 (manifest + prompt + soul + install + README) | 1파일 (SKILL.md) |
| **설정 형식** | YAML manifest + JSON Schema 검증 | Markdown 내 YAML frontmatter |
| **설치 방식** | `install.sh` → `install-general.sh` | 디렉토리에 파일 배치 |
| **이벤트 구독** | manifest의 `subscribes[]` 배열 | 없음 (명시적 호출만) |
| **정기 실행** | manifest의 `schedules[]` (cron 표현식) | Heartbeat (30분 고정) |
| **플러그인 연동** | manifest의 `cc_plugins[]` → 전역 검증 | 없음 |
| **진입장벽** | 중 (manifest 작성, Schema 이해 필요) | 낮 (Markdown 1파일) |
| **표현력** | 높 (이벤트 기반 + 스케줄 + 플러그인 + 메모리) | 중 (프롬프트 중심) |

### 5.2 Kingdom 장군 패키지 구조 (현재)

```
generals/gen-{name}/
├── manifest.yaml   # 메타데이터, 이벤트 구독, 스케줄, 플러그인
├── prompt.md       # 병사 지시 프롬프트 템플릿
├── soul.md         # 장군별 성격/톤 (선택적, 신규)
├── install.sh      # CC Plugin 설치 + Kingdom 설치
└── README.md       # 사용자 문서
```

### 5.3 OpenClaw Skill 구조

```
skills/
└── my-skill/
    └── SKILL.md    # 단일 파일: 설명 + 프롬프트 + 사용법
```

**평가**: Kingdom의 장군 패키지는 더 복잡하지만 **자기완결적**이다. manifest로 이벤트 구독과 스케줄을 선언적으로 정의하며, 왕의 라우터가 자동으로 인식한다. OpenClaw의 Skill은 진입장벽이 낮지만, 자동 트리거(이벤트/스케줄)를 지원하지 않아 사용자의 명시적 호출이 필요하다.

---

## 6. 프로액티브 시스템 비교

### 6.1 자율 실행 메커니즘

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **정기 실행** | 왕의 `check_general_schedules()` | Heartbeat (30분 주기) |
| **표현식** | 5필드 cron (`0 22 * * 1-5`) | 고정 30분 간격 |
| **중복 방지** | 분 단위 dedup (`schedule-sent.json`) | 상태 파일 기반 |
| **리소스 체크** | 실행 전 health + token 상태 확인 | 없음 (항상 실행) |
| **예시** | gen-briefing: 매일 09:00 브리핑 | HEARTBEAT.md: 자기 점검 |

### 6.2 이벤트 기반 자율 실행

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **이벤트 소스** | GitHub (Notifications API), Jira (REST) | 10+ 채널 (Email, Calendar, etc.) |
| **감지 방식** | Polling (설정 가능 주기) | Webhook + Polling 혼합 |
| **라우팅** | 왕의 라우터 (이벤트→장군 매핑) | Gateway 라우팅 |
| **우선순위** | high/normal/low + health 기반 throttling | 없음 |

**평가**: Kingdom의 cron 스케줄은 OpenClaw의 고정 Heartbeat보다 유연하다. 또한 리소스 상태(health + token budget)를 확인한 후 실행하므로 더 안전하다.

---

## 7. 안정성 & 운영 비교

### 7.1 실패 처리

| 시나리오 | Kingdom (개선 후) | OpenClaw |
|----------|------------------|----------|
| **작업 실패** | 장군 재시도 (max 2회, backoff) → 왕에 보고 | 자동 재시도 (설정 가능) |
| **메시지 전송 실패** | `failed/` 디렉토리 + retry_count (max 3, 신규) | 큐 기반 재시도 |
| **프로세스 죽음** | 내관 heartbeat 감시 → tmux 재시작 | PM2 자동 재시작 |
| **토큰 예산 초과** | 3단계 throttling (ok→warning→critical) | 없음 |
| **프롬프트 과대** | 200KB 크기 가드 + 자동 truncate (신규) | 컨텍스트 윈도우 가드 (16K 하드) |

### 7.2 리소스 모니터링

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **CPU/메모리** | 내관이 30초마다 수집, 4단계 (green→red) | 기본 OS 모니터링 |
| **디스크** | 내관이 사용률 감시 | 없음 |
| **토큰 비용** | 일별 예산 관리 ($300 기본), Slack 알림 | 없음 |
| **활성 세션** | sessions.json으로 추적 + max_soldiers 제한 | 세션 카운터 |

**평가**: Kingdom의 리소스 관리가 더 정교하다. 토큰 비용 모니터링과 4단계 health 시스템은 프로덕션 운영에 필수적이며, OpenClaw에는 없는 기능이다.

---

## 8. 코드 품질 비교

### 8.1 테스트

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **테스트 프레임워크** | Bats (Bash 테스트) | Jest/Vitest |
| **테스트 수** | 262개 | 500+ |
| **커버리지 영역** | 역할별 함수, 라우터, 파서, MQ | 전 모듈 |
| **통합 테스트** | 파일 MQ E2E (이벤트→작업→결과) | API E2E |

### 8.2 코드 구조 (개선 후)

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **왕(King)** | `king.sh` (래퍼 60줄) + `functions.sh` (460줄) | `gateway.ts` (300줄) |
| **함수 추출** | `write_to_queue()`, `next_seq_id()` 통합 | 유틸리티 모듈 분리 |
| **설정 동기화** | config YAML ↔ 코드 일치 확인 (개선 완료) | 단일 JSON이라 불일치 없음 |
| **원자적 쓰기** | `write_to_queue()` 범용 함수 | DB 트랜잭션 |

---

## 9. 채널 & 소통 비교

| 항목 | Kingdom | OpenClaw |
|------|---------|----------|
| **지원 채널** | Slack 전용 | 10+ (Slack, Discord, Telegram, Email, SMS...) |
| **양방향 소통** | Slack 스레드 질문→답변→작업 재개 | 모든 채널에서 양방향 |
| **메시지 유형** | 5종 (thread_start, update, notification, human_input, report) | 범용 메시지 |
| **실패 처리** | failed/ + 재시도 (신규) | 채널별 재시도 |

**평가**: Kingdom은 Slack 전용을 **의도적으로** 선택했다. "회사 동료"는 회사 메신저에서만 소통하는 것이 자연스럽다. 10+ 채널 지원은 "개인 비서" 아이덴티티에 적합하지만 Kingdom에는 오버엔지니어링이다.

---

## 10. 종합 평가 매트릭스

| 측면 | Kingdom | OpenClaw | 승자 |
|------|---------|----------|------|
| **아키텍처 명확성** | 6역할 고정 계층 | 동적 세션 | Kingdom |
| **설치 단순성** | 스크립트 1개 | npm install + 설정 | Kingdom |
| **확장 유연성** | 장군 패키지 (5파일) | Skill (1파일) | OpenClaw |
| **메모리 체계** | 3계층 + Soul + 성장 규칙 | MEMORY.md + Daily Logs | Kingdom |
| **프로액티브** | cron 스케줄 + health 체크 | 30분 Heartbeat | Kingdom |
| **채널 다양성** | Slack 전용 | 10+ 채널 | OpenClaw |
| **리소스 관리** | 4단계 health + 토큰 예산 | 기본 | Kingdom |
| **실패 복구** | 파일 기반 (재시작 안전) + 재시도 | 인메모리 (재시작 위험) | Kingdom |
| **생태계** | CC Plugin 연동 | 풍부한 npm 패키지 | OpenClaw |
| **커뮤니티** | 단일 팀 운영 | 140k stars | OpenClaw |

---

## 11. 차용 결과 요약

### OpenClaw에서 차용한 것 (구현 완료)

| # | 차용 포인트 | Kingdom 구현 | 효과 |
|---|------------|-------------|------|
| 1 | SOUL.md 계층형 아이덴티티 | `config/soul.md` + `generals/*/soul.md` + `config/user.md` | 병사에 일관된 성격 주입 |
| 2 | 메모리 성장 규칙 명시 | soul.md에 Growth 섹션, output contract에 `memory_updates[]` | 3계층 메모리 실제 활성화 |
| 3 | 컨텍스트 크기 가드 | `check_prompt_size()` (200KB 제한 + 자동 truncate) | 프롬프트 폭발 방지 |

### OpenClaw에서 차용하지 않은 것 (Kingdom 강점 유지)

| OpenClaw 특징 | 미채택 이유 |
|---|---|
| WebSocket Gateway | 파일 MQ가 Kingdom 스케일에 더 적합, 재시작 안전 |
| 멀티채널 (10+) | Slack 전용 = 회사 동료 아이덴티티 |
| TypeScript/Node.js | Bash = 최소 의존성, 시스템 도구 직접 통합 |
| 장기 세션 메모리 (컴팩션 등) | 병사가 일회성이라 해당 없음 |
| 디바이스 페어링 | 서버 사이드 전용 |
| HEARTBEAT.md 자연어 점검 | 왕의 cron 스케줄이 더 유연 |
| 단일 파일 Skill | 장군 패키지의 이벤트/스케줄 선언이 더 강력 |

### 자체 개선 (OpenClaw 무관)

| # | 개선 | 효과 |
|---|------|------|
| 1 | king.sh 함수/실행 분리 | 테스트 500줄 → 260줄, 유지보수성 향상 |
| 2 | `write_to_queue()` 범용 함수 | 인라인 atomic write 22회 → 함수 호출 |
| 3 | config ↔ 코드 불일치 해소 | chamberlain 설정값이 실제로 적용됨 |
| 4 | 메시지 실패 재시도 | `failed/` 디렉토리 + retry_count (메시지 유실 방지) |
| 5 | metrics 테스트 수정 | 토큰 변수 초기화 누락 해결 (232 → 262 테스트) |

---

## 12. 향후 고려 사항

### 단기 (다음 개선 사이클)

1. **이벤트 dispatched/ 단계 간소화**: pending → completed 2단계로 mv 1회 절감
2. **bc 과다 호출 최적화**: `metrics-collector.sh`의 `evaluate_health()`에서 bc 6회 → awk 1회
3. **중복 방지 간소화**: `seen/` 마커 하나면 충분 (3중 체크 불필요)

### 장기 (아키텍처 레벨)

1. **장군 패키지 진입장벽 낮추기**: `soul.md`처럼 선택적 파일 패턴 확대, manifest 자동 생성 도구
2. **메모리 정기 정리**: learned-patterns.md가 무한 성장하지 않도록 주기적 요약/정리
3. **멀티 인스턴스**: 여러 Kingdom이 협업하는 시나리오 (현재는 단일 서버 전제)

---

*이 문서는 분석 시점의 비교이며, 양쪽 프로젝트 모두 활발히 발전 중이다.*

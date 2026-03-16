# gen-pr — PR Review General

프로젝트 규칙 기반 자립형 PR 코드 리뷰 장군.

## 아키텍처

두 가지 태스크 타입으로 "규칙 학습"과 "PR 리뷰"를 분리:

| 태스크 | 트리거 | 비용 |
|--------|--------|------|
| `refresh_rules` | 스케줄 (매일 02:00) | ~10K tokens |
| PR 리뷰 | `github.pr.review_requested` | ~15-40K tokens |

```
refresh_rules 병사:
  frontend-doc 전체 읽기 → 3KB digest → memory 저장

PR 리뷰 병사:
  memory에서 digest 읽기 → 리뷰 → Agent(meta-reviewer) → 제출
```

## 패키지 구조

```
generals/gen-pr/
├── manifest.yaml          # subscribes + schedules
├── prompt.md              # 공통 fallback 프롬프트
├── prompt-claude.md       # Claude 전용 PR 리뷰 프롬프트
├── prompt-codex.md        # Codex 전용 PR 리뷰 프롬프트
├── prompts/
│   └── refresh-rules.md   # 규칙 학습 프롬프트
│   └── refresh-rules-codex.md # Codex용 규칙 학습 프롬프트
├── agents/
│   └── meta-reviewer.md   # 메타리뷰 에이전트 정의
├── general-claude.md      # 리뷰 원칙 Soul
├── general-codex.md       # Codex 리뷰 지침
├── install.sh
└── README.md
```

## 설치

```bash
./install.sh
```

`install.sh`가 수행하는 작업:
1. Kingdom 런타임에 장군 설치 (`install-general.sh` 호출)
2. 추가 템플릿 복사 (`gen-pr-refresh_rules.md`)
3. 에이전트 복사 (`config/generals/agents/gen-pr/`)
4. Memory 디렉토리 초기화
5. Codex용 refresh_rules 템플릿이 있으면 함께 복사

## 구독 이벤트

| 이벤트 | 설명 |
|--------|------|
| github.pr.review_requested | PR 리뷰 요청 |

## 스케줄

| cron | 타입 | 설명 |
|------|------|------|
| `0 2 * * *` | refresh_rules | 프로젝트 리뷰 규칙 갱신 |

## 설정

- timeout: 1800초 (30분)
- cc_plugins: 없음 (자립형)
- supported_engines: `claude`, `codex`

## 엔진별 자산

- Claude: `prompt-claude.md`, `general-claude.md`
- Codex: `prompt-codex.md`, `general-codex.md`
- 규칙 학습도 `refresh-rules-codex.md`로 엔진별 분기 가능

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-pr
```

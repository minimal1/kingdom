---
name: general-creator
description: Kingdom 장군 패키지를 대화형으로 생성합니다
when_to_use: 장군(general) 패키지를 만들거나, 장군 시스템에 대해 질문할 때
---

# Kingdom 장군 패키지 생성 가이드

Kingdom의 "장군(General)"은 특정 도메인의 작업을 전담하는 자율 에이전트 단위다. 각 장군은 `generals/gen-{name}/` 디렉토리에 자기완결적 패키지로 구성되며, `install-general.sh`로 런타임에 설치된다.

---

## 1. 패키지 구조

모든 장군 패키지는 정확히 4개 파일로 구성된다:

```
generals/gen-{name}/
├── manifest.yaml   # 장군 메타데이터 + 이벤트/스케줄 설정
├── prompt.md       # Claude Code에 전달할 프롬프트 템플릿
├── install.sh      # 설치 스크립트 (CC Plugin + install-general.sh)
└── README.md       # 사용자 문서
```

---

## 2. manifest.yaml 스키마

```yaml
# 필수
name: gen-{name}              # ^gen-[a-z0-9]([a-z0-9-]*[a-z0-9])?$ 패턴
description: "장군 설명"       # 한줄 설명

# 필수 (기본값 있음)
timeout_seconds: 1800          # 병사 실행 제한시간 (초)

# CC Plugin 의존성 (없으면 빈 배열)
cc_plugins:
  - friday@qp-plugin           # {plugin}@{marketplace} 형식

# 이벤트 구독 (없으면 빈 배열)
subscribes:
  - github.pr.review_requested

# 스케줄 (없으면 빈 배열)
schedules:
  - name: daily-test           # 스케줄 고유 이름
    cron: "0 22 * * 1-5"       # cron 표현식
    task_type: "daily-test"    # 태스크 타입 식별자
    payload:                   # 태스크에 전달할 데이터
      description: "설명"
```

**검증 규칙:**
- `name`은 반드시 `gen-` 접두사 + 소문자/숫자/하이픈
- `subscribes`의 이벤트는 다른 장군과 중복 불가 (1 event = 1 general 원칙)
- `cc_plugins` 항목은 `{plugin}@{marketplace}` 형식 권장
- `timeout_seconds` 최소 60, 최대 7200 권장

---

## 3. 이벤트 카탈로그

파수꾼(sentinel)이 emit하는 이벤트 타입 목록:

### GitHub 이벤트

| 이벤트 타입 | 트리거 조건 |
|------------|------------|
| `github.pr.review_requested` | PR 리뷰 요청 |
| `github.pr.assigned` | PR 할당 |
| `github.pr.mentioned` | PR에서 멘션 |
| `github.pr.comment` | PR 코멘트 |
| `github.pr.state_change` | PR 상태 변경 (open/close/merge) |
| `github.issue.assigned` | Issue 할당 |
| `github.issue.mentioned` | Issue에서 멘션 |
| `github.issue.comment` | Issue 코멘트 |
| `github.issue.state_change` | Issue 상태 변경 |

### Jira 이벤트

| 이벤트 타입 | 트리거 조건 |
|------------|------------|
| `jira.ticket.assigned` | 티켓이 나에게 할당됨 |
| `jira.ticket.updated` | 할당된 티켓 상태 변경 |

### Slack 이벤트

| 이벤트 타입 | 트리거 조건 |
|------------|------------|
| `slack.human_response` | 사절(envoy) 경유 사람 응답 |

---

## 4. prompt.md 패턴

prompt.md는 병사(soldier)가 Claude Code `-p` 모드로 실행할 프롬프트 템플릿이다. prompt-builder.sh가 템플릿 변수를 치환한 뒤 병사에게 전달한다.

### 템플릿 변수

| 변수 | 설명 | 치환 시점 |
|------|------|----------|
| `{{TASK_ID}}` | 태스크 고유 ID | prompt-builder |
| `{{TASK_TYPE}}` | 태스크 타입 (이벤트 타입 또는 스케줄 task_type) | prompt-builder |
| `{{REPO}}` | 대상 레포지토리 (owner/repo) | prompt-builder |
| `{{payload.KEY}}` | 페이로드의 특정 필드값 (인라인 치환) | prompt-builder |
| `{{DOMAIN_MEMORY}}` | 장군 도메인 메모리 | prompt-builder (동적 섹션) |

`{{payload.KEY}}` 사용 시 페이로드 덤프 섹션이 자동으로 생략된다.

### 패턴 1: CC Plugin 호출형 (가장 단순)

```markdown
/friday:review-pr {{payload.pr_number}}
```

CC Plugin의 슬래시 커맨드를 직접 호출. 프롬프트가 곧 명령어.

### 패턴 2: 구조화 지시형

```markdown
# Task: {{TASK_ID}}

## Instructions
Use the sunday plugin to implement this Jira ticket.

## Ticket Information
- Key: {{payload.ticket_key}}
- Summary: {{payload.summary}}

## Memory
{{DOMAIN_MEMORY}}

## Output
Provide summary with:
1. Changes made
2. Files modified
3. Tests added/updated
```

CC Plugin을 사용하되, 구조화된 지시사항과 함께 호출.

### 패턴 3: Bash 다단계형 (복잡한 워크플로우)

```markdown
# Task

## 1단계: 정보 수집
Bash 도구로 아래 명령을 실행한다.
\```bash
# 상태 수집 명령
\```

## 2단계: 분석 및 처리
수집한 정보를 분석하여...

## 3단계: 결과 보고
결과를 JSON으로 작성한다.
```

CC Plugin 없이 Bash + Claude Code 능력만으로 수행. gen-briefing이 이 패턴.

---

## 5. install.sh 템플릿

### CC Plugin이 있는 경우

```bash
#!/usr/bin/env bash
# gen-{name} 장군을 Kingdom에 설치
set -euo pipefail

KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CC Plugin 설치: {plugin}@{marketplace} ---
if command -v claude &>/dev/null; then
  SETTINGS="$HOME/.claude/settings.json"
  MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"

  # 마켓플레이스 등록
  if [ ! -f "$MARKETPLACES" ] || ! jq -e '.["MARKETPLACE"]' "$MARKETPLACES" &>/dev/null; then
    echo "Adding MARKETPLACE marketplace..."
    claude plugin marketplace add OWNER/MARKETPLACE
  fi

  # 플러그인 설치
  if [ ! -f "$SETTINGS" ] || ! jq -e '.enabledPlugins["PLUGIN@MARKETPLACE"]' "$SETTINGS" &>/dev/null; then
    echo "Installing PLUGIN plugin..."
    claude plugin install PLUGIN@MARKETPLACE
  else
    echo "Plugin PLUGIN@MARKETPLACE already installed."
  fi
else
  echo "WARN: claude CLI not found. Install CC plugins manually:"
  echo "  claude plugin marketplace add OWNER/MARKETPLACE"
  echo "  claude plugin install PLUGIN@MARKETPLACE"
fi

# --- Kingdom에 장군 설치 ---
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"
```

### CC Plugin이 없는 경우

```bash
#!/usr/bin/env bash
set -euo pipefail
KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"
```

---

## 6. README.md 구조

```markdown
# gen-{name} — {제목}

{한줄 설명}

## 사전 요구사항

- Kingdom 시스템 설치 완료
- (CC Plugin이 있으면) `claude` CLI 설치

## 설치

\```bash
./install.sh
\```

## 구독 이벤트 (이벤트 기반인 경우)

| 이벤트 | 설명 |
|--------|------|
| ... | ... |

## 스케줄 (스케줄 기반인 경우)

| 이름 | cron | 설명 |
|------|------|------|
| ... | ... | ... |

## 설정

- timeout: {N}초
- CC Plugins: {목록 또는 "없음"}

## 제거

\```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-{name}
\```
```

---

## 7. 기존 장군 예시

### gen-pr (이벤트 + CC Plugin)
- **구독**: `github.pr.review_requested`
- **플러그인**: `friday@qp-plugin`
- **프롬프트**: `/friday:review-pr {{payload.pr_number}}` (1줄 호출형)
- **timeout**: 1800초

### gen-jira (이벤트 + CC Plugin)
- **구독**: `jira.ticket.assigned`, `jira.ticket.updated`
- **플러그인**: `sunday`
- **프롬프트**: 구조화 지시형 (Ticket 정보 + 지시사항 + Memory + Output)
- **timeout**: 5400초

### gen-test (스케줄 + CC Plugin)
- **구독**: 없음
- **스케줄**: `0 22 * * 1-5` (평일 22시)
- **플러그인**: `saturday`
- **프롬프트**: 구조화 지시형 (커버리지 분석 지시)
- **timeout**: 3600초

### gen-briefing (스케줄 + 플러그인 없음)
- **구독**: 없음
- **스케줄**: `*/1 * * * *` (매 1분)
- **프롬프트**: Bash 다단계형 (상태 수집 → 브리핑 작성 → Slack 전송)
- **timeout**: 120초

---

## 8. 검증 규칙 요약

| 항목 | 규칙 |
|------|------|
| 이름 | `^gen-[a-z0-9]([a-z0-9-]*[a-z0-9])?$` |
| 필수 파일 | manifest.yaml, prompt.md (install.sh, README.md 권장) |
| 이벤트 충돌 | 동일 이벤트를 구독하는 다른 장군이 없어야 함 |
| CC Plugin | `{plugin}@{marketplace}` 형식, install.sh에서 설치 로직 일치 |
| cron 표현식 | 5필드 표준 cron (분 시 일 월 요일) |
| timeout | 최소 60초, 최대 7200초 권장 |

---

## 9. 생성 워크플로우

장군 생성 시 아래 순서를 따른다:

1. **이름 결정**: `gen-` 접두사 정규화 + regex 검증 + 기존 장군 중복 확인
2. **설명 작성**: 한줄 description
3. **트리거 설정**: 이벤트 구독 / cron 스케줄 / 둘 다
4. **CC Plugin 확인**: 필요한 플러그인과 마켓플레이스 지정
5. **timeout 설정**: 작업 복잡도에 따라 결정
6. **prompt.md 설계**: 3가지 패턴 중 선택하여 핵심 로직 작성
7. **파일 생성**: manifest.yaml → prompt.md → install.sh → README.md
8. **검증**: 이벤트 충돌 확인, manifest↔install.sh 일관성 체크
9. **안내**: `./install.sh` 또는 `install-general.sh` 실행 방법 안내

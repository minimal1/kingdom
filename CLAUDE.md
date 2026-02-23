# Kingdom

빈 컴퓨터 한 대에 정착하여 팀의 일원으로 일하는 AI 동료. Claude Code + tmux 하이브리드 아키텍처.

> **코드 탐색 시 `CODE_GRAPH.yaml`을 먼저 읽어라.** 역할별 entry_point, key_files, functions, dependencies, data_flow가 모두 매핑되어 있다. 맹목적 Glob/Grep 대신 지도를 따라 목적 파일에 바로 도달할 것.

GitHub·Jira·Slack을 통해 업무를 감지하고, 장군 패키지로 정의된 역할에 따라 자율적으로 작업한다.
모르면 사람에게 물어보고, 일하며 배운 것은 메모리에 축적한다.

역할 체계: **파수꾼(sentinel)** → **왕(king)** → **장군(general)** → **병사(soldier)** / **사절(envoy)** / **내관(chamberlain)**

- 파수꾼: GitHub·Jira 폴링으로 이벤트 감지
- 왕: 이벤트 소비 → 장군 라우팅 → 병사 배정
- 장군: 도메인 전문가 (manifest + prompt 패키지)
- 병사: Claude Code `-p` 모드로 실제 작업 실행
- 사절: Slack 양방향 소통 전담
- 내관: 리소스 모니터링, 로그 로테이션, 세션 관리

배포 경로: `/opt/kingdom/`

## Schema-First 개발 규칙

기능 변경 시 반드시 이 순서를 따른다:

```
schemas/ → config/ → docs/spec/ → bin/ (+ bin/lib/) → tests/
```

스키마가 진실의 소스(SSOT)이며, 하위 레이어는 스키마에 종속된다.

## 핵심 역할 파일 매핑

역할 코드 수정 시 매핑 테이블의 **모든 관련 파일**을 확인한다.

| 역할 | schema | config | spec | bin | test |
|------|--------|--------|------|-----|------|
| king | `schemas/king.schema.json` | `config/king.yaml` | `docs/spec/roles/king.md` | `bin/king.sh`, `bin/lib/king/functions.sh` | `tests/test_king.sh` |
| envoy | `schemas/envoy.schema.json` | `config/envoy.yaml` | `docs/spec/roles/envoy.md` | `bin/envoy.sh` | `tests/test_envoy.sh` |
| sentinel | `schemas/sentinel.schema.json` | `config/sentinel.yaml` | `docs/spec/roles/sentinel.md` | `bin/sentinel.sh` | `tests/test_sentinel.sh` |
| chamberlain | `schemas/chamberlain.schema.json` | `config/chamberlain.yaml` | `docs/spec/roles/chamberlain.md` | `bin/chamberlain.sh` | 개별 lib 테스트 |

시스템 공통: `schemas/system.schema.json`, `config/system.yaml`

## Builtin 장군 파일 매핑

소스 레포에 포함된 predefined 장군. 수정 시 관련 파일을 모두 확인한다.

| 장군 | manifest | prompt | install | spec 참조 |
|------|----------|--------|---------|-----------|
| gen-pr | `generals/gen-pr/manifest.yaml` | `generals/gen-pr/prompt.md` | `generals/gen-pr/install.sh` | `architecture.md`, `event-types.md` |
| gen-jira | `generals/gen-jira/manifest.yaml` | `generals/gen-jira/prompt.md` | `generals/gen-jira/install.sh` | `architecture.md`, `event-types.md` |
| gen-test | `generals/gen-test/manifest.yaml` | `generals/gen-test/prompt.md` | `generals/gen-test/install.sh` | `architecture.md` |
| gen-briefing | `generals/gen-briefing/manifest.yaml` | `generals/gen-briefing/prompt.md` | `generals/gen-briefing/install.sh` | `architecture.md` |

공통 schema: `schemas/general-manifest.schema.json`
공통 spec: `docs/spec/roles/general.md`

### 장군 패키지 구조

각 패키지는 `generals/gen-{name}/` 아래 자기완결적:

```
generals/gen-{name}/
├── manifest.yaml   # 메타데이터 + 이벤트/스케줄 설정
├── prompt.md       # 병사에게 전달할 프롬프트 템플릿
├── general-claude.md  # 장군별 성격/톤 (선택적, 설치 시 CLAUDE.md로 변환)
├── install.sh      # 설치 스크립트
└── README.md       # 사용자 문서
```

### Soul 시스템 (프롬프트 조립 순서)

```
config/workspace-claude.md     → workspace/CLAUDE.md로 복사 (압축에 안전)
                                  공통 원칙 + 팀 맥락 + 결과 보고 형식
generals/gen-{name}/general-claude.md → workspace/gen-{name}/CLAUDE.md (장군별 성격, 선택적)
prompt.md + payload + memory   → 작업 지시
```

모든 Soul이 CLAUDE.md 스펙으로 전달되어 context 압축에서 보호됨. `prompt-builder.sh`는 작업 지시(template + payload + memory)만 조립. 200KB 크기 가드 포함.

## 변경 체크리스트

### 역할 코드 수정 시

1. 매핑 테이블의 schema, config, spec, bin, test 모두 동기화 확인
2. `docs/spec/architecture.md` 역할 체계와 일관성 확인
3. 관련 시스템 문서 (`event-types.md`, `message-passing.md` 등) 영향 확인
4. `CODE_GRAPH.yaml` — 함수 추가/제거/이동 시 해당 모듈의 functions 목록 갱신

### Builtin 장군 수정 시

1. `manifest.yaml` ↔ `schemas/general-manifest.schema.json` 정합성
2. `manifest.yaml`의 `subscribes`가 `docs/spec/systems/event-types.md`에 존재하는지
3. `manifest.yaml`의 `cc_plugins`가 `install.sh`의 설치 로직과 일치하는지
4. `docs/spec/architecture.md` 작업 우선순위 목록과 일치하는지

### 새 이벤트 타입 추가 시

1. `docs/spec/systems/event-types.md` 카탈로그에 추가
2. 파수꾼 watcher 코드에 파싱 로직 추가 (`bin/lib/sentinel/`)
3. 구독할 장군의 `manifest.yaml` subscribes 업데이트
4. 라우터 테스트 업데이트

## Bash 코딩 규칙

- **macOS bash 3.2 호환** 필수: `declare -A` (연관 배열) 사용 금지
- `|| true` 패턴으로 파이프라인 중단 방지 (`|| echo 0` 안티패턴)
- `if/fi` 구문 선호 (`[ -f "$f" ] && cmd` 패턴은 함수 exit 코드 문제 유발)
- `date -u -j -f` — macOS에서 `-u` 필수 (UTC 파싱)
- JSON 파싱: `jq` 사용

## 테스트

```bash
bats tests/test_*.sh tests/lib/*/test_*.sh
```

## 슬래시 커맨드

| 커맨드 | 설명 |
|--------|------|
| `/verify` | 코드/문서/스키마/장군 정합성 검증 (6항목) |
| `/schema-first <대상>` | Schema-First 개발 워크플로우 안내 (역할명 또는 gen-* 장군명) |
| `/add-general` | 새 builtin 장군 추가 파이프라인 |
| `/add-event-type` | 새 이벤트 타입 추가 파이프라인 |

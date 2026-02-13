새 builtin 장군을 소스 레포에 추가한다.

장군 패키지는 `generals/gen-{name}/` 디렉토리에 4개 파일(manifest.yaml, prompt.md, install.sh, README.md)로 구성되는 자기완결적 단위다.

---

## Step 1: 기본 정보 결정

사용자에게 아래를 확인한다:

- **이름**: `gen-` 접두사 + 소문자/숫자/하이픈 (`^gen-[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)
- **설명**: 한줄 description
- **트리거**: 이벤트 구독 / cron 스케줄 / 둘 다
- **CC Plugin 의존성**: 필요한 플러그인과 마켓플레이스 (없으면 빈 배열)
- **timeout**: 작업 복잡도에 따라 결정 (기본 1800초, 범위 60~7200)

## Step 2: 이벤트 충돌 검증

트리거가 이벤트 기반이면, 기존 builtin 장군의 subscribes와 충돌이 없는지 확인한다.

기존 장군의 manifest를 모두 읽는다:
```bash
for f in generals/gen-*/manifest.yaml; do echo "=== $f ==="; cat "$f"; done
```

**1 event = 1 general 원칙**: 동일한 이벤트를 구독하는 장군이 이미 있으면 충돌.
충돌 발견 시 사용자에게 알리고 대안을 논의한다.

구독할 이벤트가 `docs/spec/systems/event-types.md`에 존재하는지도 확인한다.
없는 이벤트라면 `/add-event-type`을 먼저 실행하도록 안내한다.

## Step 3: 패키지 파일 생성

`generals/gen-{name}/` 디렉토리를 만들고 4개 파일을 생성한다.

### manifest.yaml

```yaml
# yaml-language-server: $schema=../../schemas/general-manifest.schema.json
name: gen-{name}
description: "{설명}"
timeout_seconds: {timeout}

cc_plugins:
  - {plugin}@{marketplace}   # 또는 빈 배열 []

subscribes:
  - {event.type}             # 또는 빈 배열 []

schedules:                    # 또는 빈 배열 []
  - name: {schedule-name}
    cron: "{cron expression}"
    task_type: "{task-type}"
    payload:
      description: "{설명}"
```

### prompt.md

3가지 패턴 중 적합한 것을 선택:
- **패턴 1 — CC Plugin 호출형**: `/plugin:command {{payload.KEY}}` (1줄)
- **패턴 2 — 구조화 지시형**: 섹션별 지시사항 + 템플릿 변수
- **패턴 3 — Bash 다단계형**: 플러그인 없이 Bash + Claude Code로 수행

템플릿 변수: `{{TASK_ID}}`, `{{TASK_TYPE}}`, `{{REPO}}`, `{{payload.KEY}}`, `{{DOMAIN_MEMORY}}`

### install.sh

CC Plugin이 있는 경우와 없는 경우를 구분하여 생성한다.
`plugins/general-creator/skills/general-creator/SKILL.md`의 섹션 5 템플릿을 참조.

install.sh 끝은 반드시:
```bash
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"
```

### README.md

```markdown
# gen-{name} - {제목}

{설명}

## 사전 요구사항
## 설치
## 구독 이벤트 / 스케줄
## 설정
## 제거
```

## Step 4: Architecture 문서 업데이트

`docs/spec/architecture.md`의 "작업 우선순위" 섹션에 새 장군을 추가한다.

## Step 5: Event Types 문서 업데이트

이벤트 구독 장군이면 `docs/spec/systems/event-types.md`에서:
- 해당 이벤트의 "구독 장군 없음" 주석이 있으면 제거
- 라우팅 예시에 새 장군 매핑 추가

## Step 6: 정합성 검증

`/verify`를 실행하여 전체 정합성을 확인한다.

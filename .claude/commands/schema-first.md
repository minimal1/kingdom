Schema-First 개발 워크플로우를 안내한다.

대상: $ARGUMENTS

---

## 워크플로우 분기

`$ARGUMENTS`가 역할명(king, envoy, sentinel, chamberlain)인지, builtin 장군명(gen-pr, gen-briefing 등)인지 판단하여 해당 워크플로우를 따른다.

---

## A. 역할 변경 워크플로우

대상이 king, envoy, sentinel, chamberlain 중 하나일 때.

### Step 1: Schema 확인

해당 역할의 스키마 파일을 읽고, 변경이 필요한지 확인한다.

| 역할 | schema |
|------|--------|
| king | `schemas/king.schema.json` |
| envoy | `schemas/envoy.schema.json` |
| sentinel | `schemas/sentinel.schema.json` |
| chamberlain | `schemas/chamberlain.schema.json` |

새 필드가 필요하면 스키마부터 수정한다. 스키마가 SSOT(Single Source of Truth).

### Step 2: Config 업데이트

스키마 변경에 맞춰 `config/{역할}.yaml`을 업데이트한다.

### Step 3: Spec 문서 업데이트

`docs/spec/roles/{역할}.md`에 변경 사항을 반영한다.
- 새 기능이면 해당 섹션 추가
- 기존 동작 변경이면 설명 수정

### Step 4: 코드 구현

`bin/{역할}.sh` 및 `bin/lib/{역할}/` 하위 라이브러리를 수정한다.

Bash 규칙 준수:
- macOS bash 3.2 호환 (`declare -A` 금지)
- `|| true` 패턴, `if/fi` 선호
- JSON 파싱은 `jq`

### Step 5: 테스트 작성/수정

`tests/test_{역할}.sh` 또는 `tests/lib/{역할}/test_*.sh`에 테스트를 추가/수정한다.

### Step 6: 정합성 검증

`/verify`를 실행하여 전체 정합성을 확인한다.

---

## B. Builtin 장군 변경 워크플로우

대상이 gen-pr, gen-briefing 등 `gen-` 접두사일 때.

### Step 1: Manifest Schema 확인

`schemas/general-manifest.schema.json`을 읽고, 새 필드가 필요한지 확인한다.
필요하면 스키마부터 수정.

### Step 2: Manifest 업데이트

`generals/{장군명}/manifest.yaml`을 수정한다.
- `subscribes` 변경 시 → 다른 장군과 이벤트 충돌 여부 확인 (1 event = 1 general)
- `cc_plugins` 변경 시 → Step 4에서 install.sh도 반드시 수정

### Step 3: Prompt 업데이트

`generals/{장군명}/prompt.md`를 수정한다.
- 템플릿 변수: `{{TASK_ID}}`, `{{TASK_TYPE}}`, `{{REPO}}`, `{{payload.KEY}}`, `{{DOMAIN_MEMORY}}`

### Step 4: Install 업데이트

`generals/{장군명}/install.sh`를 수정한다.
- `cc_plugins` 변경 시: 마켓플레이스 등록 + 플러그인 설치 로직을 manifest와 일치시킨다

### Step 5: 문서 확인

- `docs/spec/architecture.md` 작업 우선순위 목록에 해당 장군이 있는지 확인
- `docs/spec/systems/event-types.md`에서 구독 이벤트 관련 주석이 정확한지 확인

### Step 6: 정합성 검증

`/verify`를 실행하여 전체 정합성을 확인한다.

---

## 참고

- CLAUDE.md의 "핵심 역할 파일 매핑" / "Builtin 장군 파일 매핑" 테이블을 참조
- 변경 범위가 여러 역할/장군에 걸치면, 각각에 대해 이 워크플로우를 적용

Kingdom 정합성 검증을 수행한다. 아래 6개 항목을 순서대로 검증하고, 각 항목에 PASS/FAIL을 표시한다.

## 검증 항목

### 1. Schema ↔ Config 정합성

각 역할의 config YAML이 대응하는 JSON Schema의 필수 필드와 구조를 따르는지 확인한다.

대상:
- `schemas/king.schema.json` ↔ `config/king.yaml`
- `schemas/envoy.schema.json` ↔ `config/envoy.yaml`
- `schemas/sentinel.schema.json` ↔ `config/sentinel.yaml`
- `schemas/chamberlain.schema.json` ↔ `config/chamberlain.yaml`
- `schemas/system.schema.json` ↔ `config/system.yaml`

JSON Schema의 `required` 필드가 YAML에 존재하는지, 타입이 일치하는지 확인한다.

### 2. Code ↔ Docs 정합성

`bin/*.sh` 스크립트의 주요 함수와 동작이 `docs/spec/roles/*.md` 문서와 일치하는지 확인한다.

대상 매핑:
- `bin/king.sh` ↔ `docs/spec/roles/king.md`
- `bin/envoy.sh` ↔ `docs/spec/roles/envoy.md`
- `bin/sentinel.sh` ↔ `docs/spec/roles/sentinel.md`
- `bin/chamberlain.sh` ↔ `docs/spec/roles/chamberlain.md`

확인 포인트:
- spec에 기술된 주요 동작이 코드에 구현되어 있는지
- 코드에 있는 기능이 spec에 누락되지 않았는지

### 3. Event Catalog 정합성

`docs/spec/systems/event-types.md`의 이벤트 목록이 실제 시스템과 일치하는지 확인한다.

- 파수꾼 watcher 코드(`bin/lib/sentinel/`)가 emit하는 이벤트 타입이 event-types.md에 모두 있는지
- 장군 manifest의 `subscribes`에 있는 이벤트가 event-types.md에 모두 있는지
- event-types.md에 "구독 장군 없음" 표기가 정확한지 (실제 어떤 장군도 구독하지 않는 이벤트인지)

### 4. Builtin Generals 패키지 정합성

`generals/gen-*/` 각 패키지를 개별 검증한다.

각 장군별로:
- `manifest.yaml`이 `schemas/general-manifest.schema.json` 스키마를 따르는지
- `manifest.yaml`의 `subscribes`에 있는 이벤트가 `docs/spec/systems/event-types.md`에 존재하는지
- `manifest.yaml`의 `cc_plugins`가 `install.sh`의 설치 로직과 일치하는지 (플러그인명, 마켓플레이스명)
- 패키지 필수 파일 존재: manifest.yaml, prompt.md, install.sh, README.md

### 5. Architecture ↔ Generals 정합성

`docs/spec/architecture.md`의 작업 우선순위 목록에 나열된 장군이 실제 `generals/` 디렉토리의 builtin 장군과 일치하는지 확인한다.

- architecture.md에 있는데 generals/ 에 없는 장군이 있는지
- generals/ 에 있는데 architecture.md에 없는 장군이 있는지

### 6. Tests

전체 테스트 스위트를 실행한다.

```bash
bats tests/test_*.sh tests/lib/*/test_*.sh
```

모든 테스트가 통과하면 PASS, 하나라도 실패하면 FAIL.

## 출력 형식

```
## Kingdom 정합성 검증 결과

| # | 항목 | 결과 |
|---|------|------|
| 1 | Schema ↔ Config | PASS/FAIL |
| 2 | Code ↔ Docs | PASS/FAIL |
| 3 | Event Catalog | PASS/FAIL |
| 4 | Builtin Generals | PASS/FAIL |
| 5 | Architecture ↔ Generals | PASS/FAIL |
| 6 | Tests | PASS/FAIL |

### 불일치 상세
(FAIL 항목에 대해 구체적인 불일치 내용을 나열)
```

FAIL이 있을 경우, 각 불일치 사항에 대해 구체적인 파일 경로와 불일치 내용을 제시한다.

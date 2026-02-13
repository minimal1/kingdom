새 이벤트 타입을 시스템에 추가한다.

이벤트 타입은 `docs/spec/systems/event-types.md`가 SSOT(Single Source of Truth)이며, 파수꾼 코드·장군 manifest·라우터 테스트가 이 카탈로그와 일치해야 한다.

---

## Step 1: 이벤트 카탈로그 업데이트

`docs/spec/systems/event-types.md`를 읽고, 적절한 섹션에 새 이벤트를 추가한다.

사용자에게 아래를 확인한다:
- **Type**: `{source}.{category}.{action}` 형식 (예: `github.pr.comment`, `jira.ticket.commented`)
- **소스**: github / jira / slack
- **발생 조건**: 어떤 상황에서 이벤트가 발생하는지
- **Priority**: low / normal / high
- **ID 패턴**: `evt-{source}-{source_specific_id}` 형식

이벤트 타입 테이블에 행을 추가하고, 필요 시 주석(현재 구독 장군 없음 등)도 추가한다.

## Step 2: 파수꾼 Watcher 코드 수정

이벤트 소스에 따라 해당 watcher에 파싱 로직을 추가한다.

| 소스 | watcher 파일 |
|------|-------------|
| GitHub | `bin/lib/sentinel/github-watcher.sh` |
| Jira | `bin/lib/sentinel/jira-watcher.sh` |

**구현 포인트:**
- 외부 API 응답에서 새 이벤트 조건을 감지하는 로직
- 이벤트 JSON 파일 생성 (공통 스키마 준수)
- ID 패턴에 따른 중복 방지 로직

Bash 규칙: macOS bash 3.2 호환, `declare -A` 금지, `|| true` 패턴.

## Step 3: 장군 Manifest 업데이트 (선택)

새 이벤트를 처리할 builtin 장군이 있다면, 해당 장군의 `generals/gen-{name}/manifest.yaml`에서 `subscribes`에 새 이벤트를 추가한다.

처리할 장군이 없다면:
- event-types.md에 "구독 장군 없음" 주석을 추가
- 향후 `/add-general`로 전담 장군을 생성하도록 안내

**주의**: 1 event = 1 general 원칙. 다른 장군이 이미 구독 중인 이벤트와 충돌하지 않는지 확인.

## Step 4: 라우터 테스트 업데이트

`tests/lib/king/test_router.sh`에 새 이벤트 타입의 라우팅 테스트를 추가한다.

테스트 항목:
- 새 이벤트 타입이 올바른 장군으로 라우팅되는지 (구독 장군이 있는 경우)
- 구독 장군이 없는 경우 경고 로그 후 폐기되는지

## Step 5: 정합성 검증

`/verify`를 실행하여 전체 정합성을 확인한다.

특히 아래 항목에 주목:
- Event Catalog 정합성 (항목 3): 새 이벤트가 watcher 코드·장군 subscribes와 일치하는지
- Tests (항목 6): 라우터 테스트 포함 전체 통과

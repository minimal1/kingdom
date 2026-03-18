# 테스트 코드 자동 작성 (Draft, Codex)

> 아직 활성 템플릿이 아니다. Codex용 자립화 설계 초안이다.

`{{REPO}}` 레포에서 테스트 코드 1개를 작성한다.

- **mode**: `{{payload.mode}}`
- **base_branch**: `{{payload.base_branch}}`

## 목표

- 최근 변경과 테스트 공백을 보고 가치 있는 테스트 1개를 선택
- 기존 테스트 스타일에 맞춰 구현
- 가능한 최소 범위만 검증
- commit/push/PR 흐름은 기존 장군 규칙 유지

---

## mode: write

### Step 1. 브랜치 준비

기존 장군과 동일하게 `test/auto-writer/*` 브랜치를 재사용하거나 새로 만든다.

### Step 2. 테스트 대상 선정

다음 순서로 후보를 좁힌다.

1. 최근 변경 파일과 인접한 로직
2. 테스트가 없거나 약한 파일
3. 분기/예외/경계값이 있는 코드

선정 이유를 먼저 짧게 정리한 뒤 작성한다.

### Step 3. 테스트 작성

- 테스트는 1개만
- 기존 테스트 헬퍼/fixture를 우선 활용
- 도메인 의미가 분명한 assertion 사용
- snapshot 남용 금지

### Step 4. 검증

가장 작은 실행 단위부터 시도한다.

- 단일 파일 테스트
- 관련 패키지 테스트
- 최소 lint/typecheck

### Step 5. 결과 판단

- 성공: commit / push / draft PR
- 검증 실패 but 수정 가능: 1회 보정
- 환경 제약/범위 과도: `skipped` + 구체적 이유

---

## mode: merge

기존 장군과 동일하게 draft PR을 찾아 ready + auto-merge를 설정한다.

---

## 결과 보고

- `summary`에 사람이 읽을 수 있는 결과를 간결히 작성
- `skipped`일 때는 왜 안전하게 건너뛰는지 분명히 적을 것
- 프로젝트별 테스트 패턴을 발견하면 `memory_updates`에 기록

# 테스트 코드 자동 작성 (Draft, plugin-free)

> 아직 활성 템플릿이 아니다. `/friday:test` 의존을 제거하기 위한 설계 초안이다.

`{{REPO}}` 레포에서 테스트 코드 1개를 작성한다.

- **mode**: `{{payload.mode}}`
- **base_branch**: `{{payload.base_branch}}`
- **branch 패턴**: `test/auto-writer/<YYYYMMDD>`

---

## mode: write

### Step 1. base 브랜치 최신화

```bash
git fetch origin {{payload.base_branch}}
```

### Step 2. 작업 브랜치 준비

`test/auto-writer/*` 패턴의 브랜치가 remote에 이미 존재하면 checkout 후 rebase, 없으면 오늘 날짜로 새로 생성한다.

### Step 3. 테스트 후보 선정

아래 기준으로 **가치가 높은 테스트 1개**만 선택한다.

- 최근 변경 파일과 인접한 코드
- 기존 테스트가 부족하거나 없는 영역
- 버그 가능성이 높은 분기 / edge case
- 비교적 짧은 시간 안에 검증 가능한 단위

피해야 할 것:

- 대규모 fixture 추가가 필요한 테스트
- 환경 의존성이 큰 E2E
- flaky 가능성이 높은 통합 테스트

### Step 4. 테스트 작성

선정한 대상에 대해 테스트 1개만 작성한다.

작성 원칙:

- 기존 테스트 스타일을 따른다
- 가장 작은 유효 검증을 추가한다
- 의미 없는 snapshot 확대는 피한다
- 테스트 이름은 의도를 드러내야 한다

### Step 5. 최소 검증

가능하면 다음 우선순위로 검증한다.

1. 해당 테스트 파일만 실행
2. 관련 패키지/모듈 테스트만 실행
3. 그것도 어려우면 lint/typecheck 등 최소 검증

실패 시:

- 원인 명확하면 수정 후 1회 재시도
- 환경 문제/과도한 범위면 `skipped`

### Step 6. 커밋 및 Push

```bash
git add -A
git commit -m "test: add auto-generated test

— General Test Writer of Kingdom"
git push origin "$BRANCH"
```

### Step 7. Draft PR 생성 (없을 때만)

이 브랜치에 대한 열린 PR이 없으면 draft PR을 생성한다.

### 결과 보고

- `summary`: "테스트 커밋 완료: <대상 요약> (브랜치: $BRANCH)"
- `memory_updates`: 테스트 스타일/검증 패턴에서 얻은 프로젝트 특이사항

---

## mode: merge

### Step 1. Draft PR 확인

`test/auto-writer/*` 패턴의 열린 PR을 찾는다.

PR이 없으면 "머지할 PR 없음"으로 종료한다.

### Step 2. Ready for Review + Auto-merge

```bash
gh pr ready "$PR_NUMBER" --repo "{{REPO}}"
gh pr merge "$PR_NUMBER" --repo "{{REPO}}" --auto --squash
```

### 결과 보고

- `summary`: "테스트 PR #<number> ready + auto-merge 설정 완료"
- PR이 없었으면: "머지할 PR 없음"

# 테스트 코드 자동 작성

`{{REPO}}` 레포에서 테스트 코드를 작성한다.

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

```bash
EXISTING=$(git ls-remote --heads origin 'test/auto-writer/*' | head -1 | sed 's|.*refs/heads/||')
if [ -n "$EXISTING" ]; then
  BRANCH="$EXISTING"
  git fetch origin "$BRANCH"
  git checkout -b "$BRANCH" "origin/$BRANCH"
  git rebase "origin/{{payload.base_branch}}"
else
  BRANCH="test/auto-writer/$(date +%Y%m%d)"
  git checkout "{{payload.base_branch}}"
  git pull origin "{{payload.base_branch}}"
  git checkout -b "$BRANCH"
fi
```

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

선정 이유를 먼저 짧게 정리한 뒤 테스트를 작성하라.

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

```bash
EXISTING_PR=$(gh pr list --head "$BRANCH" --base "{{payload.base_branch}}" --repo "{{REPO}}" --json number --jq '.[0].number')
if [ -z "$EXISTING_PR" ]; then
  gh pr create --base "{{payload.base_branch}}" --head "$BRANCH" --draft \
    --title "test: auto-generated tests ($(date +%Y-%m-%d))" \
    --body "자동 생성 테스트 누적 PR.

테스트 커밋이 누적되며, 주기적으로 머지됩니다.

— General Test Writer of Kingdom"
fi
```

### Step 8. base 브랜치로 복귀

```bash
git checkout {{payload.base_branch}}
```

### 결과 보고

- `summary`: "테스트 커밋 완료: <대상 요약> (브랜치: $BRANCH)"
- `skipped`일 때는 구체적 이유를 `reason`에 넣는다

---

## mode: merge

### Step 1. Draft PR 확인

`test/auto-writer/*` 패턴의 열린 PR을 찾는다.

```bash
PR_NUMBER=$(gh pr list --search "head:test/auto-writer/" --base "{{payload.base_branch}}" --repo "{{REPO}}" --json number --jq '.[0].number')
```

PR이 없으면 "머지할 PR 없음"으로 보고하고 종료.

### Step 2. Ready for Review + Auto-merge

squash merge 후 브랜치 자동 삭제는 GitHub 레포 설정(Automatically delete head branches)에 의존한다. 이 설정이 켜져 있어야 다음 주기에 새 브랜치가 정상 생성된다.

```bash
gh pr ready "$PR_NUMBER" --repo "{{REPO}}"
gh pr merge "$PR_NUMBER" --repo "{{REPO}}" --auto --squash
```

### 결과 보고

- `summary`: "테스트 PR #<number> ready + auto-merge 설정 완료"
- PR이 없었으면: "머지할 PR 없음"

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

### Step 3. 테스트 코드 작성

friday 플러그인의 write-test 스킬을 실행하여 테스트 코드 **1개**를 작성하라.

```
/friday:write-test
```

스킬이 대상 파일을 자동 선택한다. 스킬 실행 결과를 확인하고, 테스트 코드가 정상 작성되었는지 검증하라.

### Step 4. 커밋 및 Push

```bash
git add -A
git commit -m "test: add auto-generated test

— General Test Writer of Kingdom"
git push origin "$BRANCH"
```

### Step 5. Draft PR 생성 (없을 때만)

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

### Step 6. base 브랜치로 복귀

```bash
git checkout {{payload.base_branch}}
```

### 결과 보고

- `summary`: "테스트 커밋 완료: <테스트 대상 파일 요약> (브랜치: $BRANCH)"
- 실패 시 `summary`에 실패 원인을 명시하라.

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

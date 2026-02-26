# 테스트 코드 자동 작성

`{{REPO}}` 레포의 `{{payload.base_branch}}` 브랜치에서 테스트 코드 1개를 작성하고 PR을 오픈하라.

## 작업 절차

### Step 1. develop 브랜치 최신화

현재 워크스페이스 아래 레포 디렉토리로 이동하라.

```bash
cd {{REPO_DIR}}
git checkout {{payload.base_branch}}
git pull origin {{payload.base_branch}}
```

### Step 2. 작업 브랜치 생성

`{{payload.base_branch}}` 기준으로 새 브랜치를 생성하라.

```bash
BRANCH_NAME="test/auto-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH_NAME"
```

### Step 3. 테스트 코드 작성

friday 플러그인의 write-test 스킬을 실행하여 테스트 코드 **1개**를 작성하라.

```
/friday:write-test
```

스킬이 대상 파일을 자동 선택한다. 스킬 실행 결과를 확인하고, 테스트 코드가 정상 작성되었는지 검증하라.

### Step 4. 커밋 및 PR 오픈

작성된 테스트 파일을 커밋하고 PR을 오픈하라.

```bash
git add -A
git commit -m "test: add auto-generated test

— General Test Writer of Kingdom"
git push origin "$BRANCH_NAME"
```

PR을 `{{payload.base_branch}}` 브랜치 기준으로 오픈하라. PR 제목과 본문은 작성한 테스트의 내용을 반영하라.

```bash
gh pr create --base {{payload.base_branch}} --title "test: <테스트 대상 요약>" --body "<본문>

— General Test Writer of Kingdom"
```

### Step 5. develop 브랜치로 복귀

```bash
git checkout {{payload.base_branch}}
```

## 결과 보고

- `summary`: "테스트 PR 오픈 완료: <PR URL> (<테스트 대상 파일 요약>)"
- 실패 시 `summary`에 실패 원인을 명시하라.

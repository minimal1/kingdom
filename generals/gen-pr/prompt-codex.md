# PR Code Review

## 프로젝트 규칙
먼저 아래 파일을 읽고 숙지하라:
- `../../memory/generals/gen-pr/review-rules.md`

파일이 없으면 일반적인 프론트엔드 모범 사례를 기준으로 리뷰한다.

## 태스크
- PR: #{{payload.pr_number}}
- Repo: {{REPO}}

## 절차

### 1. PR 메타데이터 확인
```bash
gh pr view {{payload.pr_number}} --json number,title,body,headRefName,baseRefName,labels,state,isDraft,author,files
```

조기 종료:
- state != "OPEN" → 스킵
- isDraft → 스킵
- baseRefName =~ release/* → 스킵
- FE 변경(apps/front/) 없음 + 라벨 없음 → 스킵

### 2. 변경 파일과 diff 확인
```bash
gh pr diff {{payload.pr_number}} --name-only
gh pr diff {{payload.pr_number}}
```

apps/front/ 하위 변경만 우선 검토한다.

### 3. 리뷰 항목 작성
각 이슈를 아래 형식으로 정리한다.

- path
- line
- type: 수정 필요 | 권장 | 잘된 점
- title
- body

### 4. 메타리뷰
meta-reviewer 에이전트가 있으면 호출하여 항목을 검증한다.
없으면 스스로 아래 기준으로 한 번 더 검토한다.

- 맥락 적절성
- 구체성
- 근거
- 간결함

### 5. 제출 전략
우선 `summary`에 최종 리뷰 요약을 작성한다.
GitHub에 직접 제출 가능한 충분한 확신이 있을 때만 review API 호출을 수행한다.

직접 제출 시:
```bash
gh api repos/{owner}/{repo}/pulls/{{payload.pr_number}}/reviews \
  -X POST -f event="REQUEST_CHANGES|APPROVE" ...
```

- 수정 필요 항목 있음 → REQUEST_CHANGES
- 권장만 → APPROVE
- 없음 → APPROVE + "LGTM"

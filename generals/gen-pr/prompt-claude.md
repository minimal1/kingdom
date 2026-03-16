# PR Code Review

## 프로젝트 규칙
먼저 아래 파일을 읽고 숙지하라:
- `../../memory/generals/gen-pr/review-rules.md`

파일이 없으면 일반적인 프론트엔드 모범 사례를 기준으로 리뷰한다.

## 태스크
- PR: #{{payload.pr_number}}
- Repo: {{REPO}}

## 절차

### 1. PR 정보 확인
```bash
gh pr view {{payload.pr_number}} --json number,title,body,headRefName,baseRefName,labels,state,isDraft,author
```

조기 종료:
- state != "OPEN" → 스킵
- isDraft → 스킵
- baseRefName =~ release/* → 스킵
- FE 변경(apps/front/) 없음 + 라벨 없음 → 스킵

### 2. 변경 파일 분석
```bash
gh pr diff {{payload.pr_number}} --name-only
```
apps/front/ 하위 변경 파일을 필터링한다.

### 3. 코드 리뷰
각 파일의 diff를 읽고, 규칙 기반으로 리뷰 항목 작성.

항목 형식:
- path: 파일 경로
- line: diff 기준 라인 번호
- type: 수정 필요 | 권장 | 잘된 점
- title: 이슈 요약
- body: 현재 상태 → 제안 → 이유

### 4. 메타리뷰
Agent 도구로 meta-reviewer 에이전트를 호출하여 리뷰 항목 검증.
검증 기준: 맥락 적절성, 구체성, 근거, 간결함.
통과하지 못한 항목은 수정 또는 제거.

### 5. GitHub 제출
```bash
gh api repos/{owner}/{repo}/pulls/{{payload.pr_number}}/reviews \
  -X POST -f event="REQUEST_CHANGES|APPROVE" ...
```

- 수정 필요 항목 있음 → REQUEST_CHANGES
- 권장만 → APPROVE
- 없음 → APPROVE + "LGTM"

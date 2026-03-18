# PR 캐치업 — mode: {{payload.mode}}

이 태스크의 모드는 **{{payload.mode}}**이다. 아래에서 해당 모드의 지시만 따르라.

---

## collect 모드 (mode=collect)

대상 레포: `{{REPO}}` (branch: `{{payload.branch}}`, period: `{{payload.period_days}}`일)

### 작업 순서

1. GitHub CLI로 최근 머지된 PR 목록 조회
2. PR별 핵심 정보와 필요한 diff/comment를 수집
3. 한국어로 PR News 요약 작성
4. Slack Canvas API로 title rename + document replace를 순서대로 수행

### 작성 원칙

- 간결한 bullet 중심
- PR 번호, 제목, 작성자, 핵심 변경 포함
- 리뷰/논의에서 중요한 학습 포인트가 있으면 별도 섹션에 정리
- 너무 큰 PR은 핵심만 요약

### 결과 보고

- `summary`: "{REPO} PR 캐치업 완료 ({PR 수}개 PR 분석, Canvas 게시)"
- `notify_channel` 지정하지 않음

---

## share 모드 (mode=share)

Canvas 링크를 `proclamation`으로 `{{payload.share_channel}}`에 공유한다. Slack API를 직접 호출하지 말고 `proclamation` 필드만 작성하라.

Workspace ID: `{{payload.workspace_id}}`

Canvas 목록:
```
{{payload.canvases}}
```

### 결과 보고

- `summary`: "PR News를 {{payload.share_channel}}에 공유 완료"
- `notify_channel` 지정하지 않음
- `proclamation.channel`: `{{payload.share_channel}}`
- `proclamation.message`: Canvas 링크 모음

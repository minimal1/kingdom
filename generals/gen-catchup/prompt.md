# PR 캐치업 — mode: {{payload.mode}}

이 태스크의 모드는 **{{payload.mode}}**이다. 아래에서 해당 모드의 지시만 따르라.

---

## collect 모드 (mode=collect)

대상 레포: `{{REPO}}` (branch: `{{payload.branch}}`, period: `{{payload.period_days}}`일)

### 작업 순서

1. **PR 목록 조회**: CLAUDE.md의 PR 조회 워크플로우(Step 2)에 따라 머지된 PR 수집
2. **PR 상세 분석**: CLAUDE.md의 상세 데이터 수집(Step 3) + 분석(Step 4) 규칙에 따라 요약 작성
3. **Slack Canvas 게시**: Canvas ID `{{payload.canvas_id}}`에 결과 게시 (CLAUDE.md의 Canvas API 규칙 참조)

### 결과 보고

- `summary`: "{REPO} PR 캐치업 완료 ({PR 수}개 PR 분석, Canvas 게시)"
- `notify_channel` 지정하지 않음 (운영 채널로 기본 전송)

---

## share 모드 (mode=share)

Canvas 링크를 `proclamation`으로 `{{payload.share_channel}}`에 공유한다. **Slack API를 직접 호출하지 말 것** — 왕이 사절을 통해 발송한다.

Workspace ID: `{{payload.workspace_id}}`

Canvas 목록 (JSON):
```
{{payload.canvases}}
```

### 결과 보고

결과 JSON에 `proclamation` 필드를 포함하라. 위 Canvas 목록의 각 항목으로 Slack link를 구성한다. CLAUDE.md의 Proclamation 형식을 참조하라.

- `summary`: "PR News를 {{payload.share_channel}}에 공유 완료"
- `notify_channel` 지정하지 않음

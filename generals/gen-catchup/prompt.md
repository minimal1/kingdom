# 일간 PR 캐치업 요약

아래 레포별로 순차 처리하라.

## 대상 레포

| # | 레포 | 브랜치 | 기간 | Canvas ID |
|---|------|--------|------|-----------|
| 1 | `TODO_REPO_A` | `TODO_BRANCH_A` | 1d | `TODO_CANVAS_ID_A` |
| 2 | `TODO_REPO_B` | `TODO_BRANCH_B` | 1d | `TODO_CANVAS_ID_B` |

## 공유 설정

| 항목 | 값 |
|------|-----|
| share_channel | `TODO_SHARE_CHANNEL_ID` |
| workspace_id | `TODO_WORKSPACE_ID` |

## 처리 절차

각 레포에 대해:

### Step 1. PR 캐치업 분석

friday 플러그인의 pr-catchup 기능을 사용하여 지난 1일간 머지된 PR을 분석하라.

```
/friday:pr-catchup {레포} --branch {브랜치} --days 1
```

결과를 마크다운으로 정리하라.

### Step 2. Slack Canvas에 게시

Step 1의 분석 결과를 해당 레포의 Canvas에 게시하라.

**중요: `operation: replace`로 Canvas 전체를 덮어쓴다.** 기존 문서 내용은 초기화되고, 분석 결과가 Title부터 새로 작성된다. 절대로 기존 내용에 이어쓰지 않는다.

```bash
curl -s -X POST "https://slack.com/api/canvases.edit" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "canvas_id": "{Canvas ID}",
    "changes": [{
      "operation": "replace",
      "document_content": {
        "type": "markdown",
        "markdown": "{분석 결과 마크다운}"
      }
    }]
  }'
```

API 응답의 `ok` 필드가 `true`인지 확인하라. 실패 시 에러를 보고하라.

### Step 3. 팀 채널에 PR News 공유

**모든 레포** 처리가 끝난 후, 결과 보고 시 `proclamation` 필드를 사용하여 share_channel로 PR News 요약을 공표하라. Slack API를 직접 호출하지 말 것 — 왕이 사절을 통해 발송한다.

결과 JSON의 `proclamation` 필드에 다음을 포함:

```json
"proclamation": {
  "channel": "{share_channel}",
  "message": "PR News\n1. {레포A 이름} — https://app.slack.com/client/{workspace_id}/unified-files/doc/{Canvas ID A}\n2. {레포B 이름} — https://app.slack.com/client/{workspace_id}/unified-files/doc/{Canvas ID B}\n\n— General Catchup of Kingdom"
}
```

## 결과 보고

결과를 보고하라. `notify_channel`은 지정하지 않는다 (운영 채널로 기본 전송).

- `summary`: "PR News를 {share_channel}에 공유 완료 ({처리된 레포 수}개 레포)"

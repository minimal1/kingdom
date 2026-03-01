# 일간 PR 캐치업 요약

Task Payload의 `repos` 배열을 순차 처리하라. 각 항목에는 `repo`, `branch`, `period_days`, `canvas_id`가 포함되어 있다.

## 처리 절차

각 레포에 대해:

### Step 1. PR 캐치업 분석

friday 플러그인의 pr-catchup 기능을 사용하여 지난 `period_days`일간 머지된 PR을 분석하라.

```
/friday:pr-catchup {repo} --branch {branch} --days {period_days}
```

결과를 마크다운으로 정리하라.

### Step 2. Slack Canvas에 게시

Step 1의 분석 결과를 해당 레포의 Canvas에 게시하라.

**중요: Canvas 전체를 덮어쓴다.** 기존 문서 내용은 초기화되고, 분석 결과가 새로 작성된다. 절대로 기존 내용에 이어쓰지 않는다. API는 호출당 operation 1개만 허용되므로 2번 호출한다.

**호출 1 — Title 변경** (`rename`):

```bash
curl -s -X POST "https://slack.com/api/canvases.edit" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "canvas_id": "{canvas_id}",
    "changes": [{
      "operation": "rename",
      "title_content": {
        "type": "markdown",
        "markdown": "{레포 이름} PR News — {YYYY-MM-DD}"
      }
    }]
  }'
```

**호출 2 — 본문 덮어쓰기** (`replace`):

```bash
curl -s -X POST "https://slack.com/api/canvases.edit" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "canvas_id": "{canvas_id}",
    "changes": [{
      "operation": "replace",
      "document_content": {
        "type": "markdown",
        "markdown": "{분석 결과 마크다운}"
      }
    }]
  }'
```

각 호출의 `ok` 필드가 `true`인지 확인하라. 실패 시 에러를 보고하라.

### Step 3. 팀 채널에 PR News 공유

**모든 레포** 처리가 끝난 후, 결과 보고 시 `proclamation` 필드를 사용하여 `share_channel`로 PR News 요약을 공표하라. Slack API를 직접 호출하지 말 것 — 왕이 사절을 통해 발송한다.

결과 JSON의 `proclamation` 필드에 다음을 포함:

```json
"proclamation": {
  "channel": "{share_channel}",
  "message": "PR News\n1. <https://chequer.slack.com/docs/{workspace_id}/{canvas_id_A}|{레포A 이름}>\n2. <https://chequer.slack.com/docs/{workspace_id}/{canvas_id_B}|{레포B 이름}>\n\n— General Catchup of Kingdom"
}
```

## 결과 보고

결과를 보고하라. `notify_channel`은 지정하지 않는다 (운영 채널로 기본 전송).

- `summary`: "PR News를 {share_channel}에 공유 완료 ({처리된 레포 수}개 레포)"

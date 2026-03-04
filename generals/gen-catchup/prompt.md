# 일간 PR 캐치업 요약

Task Payload의 `repos` 배열을 순차 처리하라. 각 항목에는 `repo`, `branch`, `period_days`, `canvas_id`가 포함되어 있다.

각 레포에 대해:

1. **PR 캐치업 분석**: `/friday:pr-catchup {repo} --branch {branch} --days {period_days}`
2. **Slack Canvas에 게시**: 결과를 해당 레포의 Canvas(`canvas_id`)에 게시 (CLAUDE.md의 Canvas API 규칙 참조)
3. **모든 레포 완료 후**: `proclamation` 필드로 `share_channel`에 PR News 공유 (CLAUDE.md의 Proclamation 형식 참조)

## 결과 보고

`notify_channel`은 지정하지 않는다 (운영 채널로 기본 전송).

- `summary`: "PR News를 {share_channel}에 공유 완료 ({처리된 레포 수}개 레포)"

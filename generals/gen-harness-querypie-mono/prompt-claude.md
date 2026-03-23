# querypie-mono Harnessed Development

이 태스크는 `querypie-mono` 레포 전용 `harnessed_dev` 프로토콜을 따른다.

## Trigger Context

- 이벤트 소스: Jira 또는 petition-routed Slack 요청
- repo: `{{REPO}}`

## Bootstrap

먼저 `harness.md`, `decision-rules.md`, `validation-rules.md`를 읽어라.

그리고 `querypie-mono`의 관련 문서/skills를 읽어 bootstrap knowledge를 확보하라.

## Intake

- 작업 요청을 5줄 이내로 요약
- 요구사항, 제약, open question을 정리

## Plan

- 변경 파일 후보
- 구현 단계
- 검증 계획
- 리스크

## Execute

작은 단위로 수정한다.

## Review

계획이 과하거나 모호하면 축소/재정렬한다.

## Validate

가장 작은 검증 단위부터 수행한다.

## Decide

최종 상태:

- `success`
- `failed`
- `skipped`
- `needs_human`

## Report

최종 요약을 `summary`에 넣는다.

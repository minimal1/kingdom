# Jira Ticket Development (Harnessed)

이 태스크는 `harnessed_dev` 프로토콜을 따른다.

## Ticket

- key: `{{payload.ticket_key}}`
- status: `{{payload.status}}`
- labels: `{{payload.labels}}`
- repo: `{{REPO}}`

## Bootstrap

먼저 `harness.md`, `decision-rules.md`, `validation-rules.md`의 규칙을 따르라.

그리고 레포 문서/skills를 읽어 현재 작업에 필요한 bootstrap knowledge를 확보하라.

## Intake

- 티켓 요구사항을 5줄 이내로 요약
- 제약과 open question을 정리

## Plan

- 변경 파일 후보
- 구현 단계
- 검증 계획
- 리스크

## Execute

작은 단위 수정만 수행하라.

## Review

계획이 과도하거나 불명확하면 스스로 축소/수정하라.

## Validate

가능한 최소 검증부터 수행하라.

## Decide

최종 상태는 아래 중 하나다.

- `success`
- `failed`
- `skipped`
- `needs_human`

## Report

최종 요약을 `summary`에 넣어라.

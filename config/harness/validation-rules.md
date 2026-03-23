# Kingdom Harness Validation Rules

## Validation Order

1. 변경 파일과 가장 가까운 테스트
2. 관련 모듈 테스트
3. 최소 빌드 / 타입체크

## Failure Handling

- 코드 문제면 수정 후 재검증
- 환경 문제면 `needs_human` 또는 `failed`
- 범위 과대면 `skipped`

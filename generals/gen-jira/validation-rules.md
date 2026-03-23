# gen-jira Validation Rules

## Minimum Validation

가능하면 다음 순서로 검증한다.

1. 변경 파일과 가장 가까운 테스트
2. 관련 모듈 테스트
3. 최소 빌드 / 타입체크

## Failure Classification

- 테스트/빌드 오류가 코드 원인 → 수정 후 재시도
- 환경/권한/외부 서비스 문제 → `needs_human` 또는 `failed`
- 범위 과도 / 근거 부족 → `skipped`

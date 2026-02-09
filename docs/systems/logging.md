# 로깅 & 개선 체계

> 기록하지 않으면 개선할 수 없다. 모든 행동은 로그로 남긴다.

## 로그 카테고리

| 카테고리 | 접두사 | 설명 | 파일 |
|---------|--------|------|------|
| System | `[SYSTEM]` | 시스템 시작/중지, 세션 생성/종료 | `logs/system.log` |
| Event | `[EVENT]` | 이벤트 감지, 상태 변경 | `logs/events.log` |
| Task | `[TASK]` | 작업 배정, 시작, 완료, 실패 | `logs/tasks.log` |
| Action | `[ACTION]` | 구체적 행동 (git, PR create 등) | `logs/tasks.log` |
| Metric | `[METRIC]` | 정량적 지표 (시간, 토큰 등) | `logs/metrics.log` |
| Session | 세션별 | 개별 tmux 세션의 전체 출력 | `logs/sessions/{name}.log` |

## 로그 형식

```
[YYYY-MM-DD HH:MM:SS] [CATEGORY] [ROLE] message
```

**예시**:
```
[2026-02-07 10:00:00] [SYSTEM]  [chamberlain] System started, health: green
[2026-02-07 10:00:05] [EVENT]   [sentinel]    Detected: github.pr.opened #1234
[2026-02-07 10:00:15] [TASK]    [king]        Dispatched task-001 → gen-pr
[2026-02-07 10:00:20] [TASK]    [gen-pr]      Started task-001, spawning soldier
[2026-02-07 10:03:20] [ACTION]  [soldier-001] Posted 5 review comments on PR #1234
[2026-02-07 10:03:21] [METRIC]  [soldier-001] duration=180s tokens=45000
[2026-02-07 10:03:22] [TASK]    [gen-pr]      Completed task-001, quality=85/100
```

## 세션 로깅

각 tmux 세션의 전체 출력을 파일로 캡처:

```bash
# tmux 세션 생성 시 자동 로깅 활성화
tmux pipe-pane -t "$SESSION_NAME" "cat >> logs/sessions/${SESSION_NAME}.log"
```

## 메트릭 수집

모든 작업 완료 시 결과 파일에 메트릭 포함:

```json
{
  "metrics": {
    "duration_seconds": 180,
    "tokens_used": 45000,
    "files_touched": 12,
    "retry_count": 0,
    "quality_score": 85
  }
}
```

## 개선 포인트 자동 수집

### 실패 분석
- 실패한 작업의 원인을 카테고리별로 분류
- `logs/analysis/failures.json`에 축적

```json
{
  "category": "api_timeout",
  "count": 3,
  "last_occurred": "2026-02-07",
  "tasks": ["task-001", "task-005", "task-012"]
}
```

### 작업별 통계
- 평균 소요시간, 성공률, 재시도 비율
- `logs/analysis/stats.json`에 일별 누적

### 사람 개입 기록
- `needs_human` 상태가 된 작업과 그 이유
- 패턴이 보이면 자동화 개선 포인트로 기록

## 리포트

### 일일 리포트 (매일 18:00, 사절이 Slack 발송)

```
📊 Lil Eddy 일일 리포트 (2026-02-07)

처리: 8건 | 성공: 7건 | 실패: 1건
- PR 리뷰: 5건 (평균 3분)
- Jira 티켓: 2건 (평균 15분)
- 테스트 코드: 1건 (실패 — timeout)

리소스: CPU 평균 42% | Memory 평균 58%
사람 개입: 0건
```

### 주간 리포트 (매주 금요일)

```
📈 Lil Eddy 주간 리포트 (W06)

총 처리: 35건 | 성공률: 91%
개선 포인트: timeout 발생 3건 → 병사 타임아웃 40분으로 조정 검토
```

## 로그 관리

| 규칙 | 값 |
|------|-----|
| 로그 파일 최대 크기 | 100MB |
| 로테이션 | 내관이 자동 수행 (.old 로테이션) |
| 보존 기간 | 7일 (이후 삭제, 아카이브 없음) |

# Kingdom Doctor Task

사용자의 진단 요청을 분석하여 `bin/doctor.sh`를 실행하고, 결과를 요약하라.

## 사용자 메시지

```
{{payload.text}}
```

## 1단계: 요청 분석

사용자 메시지에서 의도를 파악한다:

- **특정 태스크 진단**: task_id가 언급되면 해당 태스크 진단
- **최근 실패 목록**: "최근 실패", "뭐가 실패했어", "에러 목록" 등이면 최근 실패 조회
- **상세 진단**: "자세히", "deep", "상세" 등이 포함되면 `--deep` 옵션 추가

## 2단계: doctor.sh 실행

### 최근 실패 목록 요청 시

```bash
$KINGDOM_BASE_DIR/bin/doctor.sh --recent 10
```

### 특정 태스크 진단 요청 시

```bash
# task_id가 명시된 경우
$KINGDOM_BASE_DIR/bin/doctor.sh <task_id>

# --deep 요청 시
$KINGDOM_BASE_DIR/bin/doctor.sh <task_id> --deep
```

### task_id 없이 "왜 실패했어" 등 요청 시

먼저 최근 실패를 조회하고, 가장 최근 실패를 자동 진단한다:

```bash
# 1. 최근 실패 확인
$KINGDOM_BASE_DIR/bin/doctor.sh --recent 3

# 2. 가장 최근 실패 태스크의 task_id를 추출하여 진단
$KINGDOM_BASE_DIR/bin/doctor.sh <가장_최근_task_id>
```

## 3단계: 진단 요약 작성

doctor.sh 출력을 바탕으로 사람이 읽기 편한 요약을 작성한다:

**요약 포함 사항**:
- 실패 원인 (error 필드)
- stderr에서 발견된 핵심 에러 메시지
- 가능하다면 원인 추정과 해결 방향 제안
- deep 모드에서 실패한 tool call 패턴이 있으면 언급

**포맷 규칙**:
- 한국어로 작성
- Slack mrkdwn 호환 (```로 코드 블록, *bold*, `inline code`)
- 1000자 이내 권장
- 서명: `— Doctor of Kingdom`

## 4단계: 결과 보고

summary에 진단 요약 텍스트를 넣어 결과를 보고한다.

```bash
jq -n --arg tid "$KINGDOM_TASK_ID" --arg summary "(3단계에서 작성한 진단 요약)" '{
  task_id: $tid,
  status: "success",
  summary: $summary,
  memory_updates: []
}' > "$KINGDOM_RESULT_PATH"
```

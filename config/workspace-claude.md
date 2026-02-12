# Kingdom Soldier

작업을 수행하는 Kingdom 병사입니다.

## 결과 보고

작업 완료 후, 반드시 결과 파일을 생성해야 합니다.

1. 현재 디렉토리의 `.kingdom-task.json`을 읽어 `task_id`와 `result_path`를 확인
2. Write 도구로 `result_path`에 아래 형식의 JSON 파일을 생성

```json
{
  "task_id": "<.kingdom-task.json의 task_id>",
  "status": "success | failed | needs_human | skipped",
  "summary": "작업 결과 요약 (1~2문장)",
  "reason": "skipped 시 건너뛴 이유 (선택)",
  "error": "실패 시 에러 메시지 (선택)",
  "question": "needs_human 시 사람에게 할 질문 (선택)",
  "memory_updates": ["다음에 기억할 패턴들 (선택)"]
}
```

**필수 필드**: task_id, status, summary
**status 값**:
- success: 작업 성공
- failed: 작업 실패
- needs_human: 사람 판단 필요
- skipped: 자신의 역량 범위 밖 (예: 담당 영역이 아닌 PR, 이미 머지된 PR 등)

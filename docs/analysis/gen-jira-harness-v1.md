# gen-jira Harness v1

> `gen-jira`를 범용 Jira 장군이 아니라, repo-bound harnessed_dev 장군으로 재설계하는 초안.

## 제안 이름

- `gen-dev-querypie-mono`

이유:

- bootstrap 지식이 레포마다 다름
- validation 규칙도 레포마다 다름
- memory가 섞이면 품질이 떨어짐

## 기본 트리거

- `jira.ticket.assigned`
- `jira.ticket.updated`

추가 가드:

- `payload.status == "In Progress"`
- `payload.labels`에 특정 AI 라벨 포함
- repo가 `querypie-mono`로 명확히 매핑
- 구현 가능한 타입의 티켓

즉 “아무 Jira 티켓”이 아니라 “실행 가능한 개발 티켓”만 받는다.

## phase

1. `bootstrap`
   레포 문서/skills 읽기
2. `intake`
   티켓 해석
3. `plan`
   구현 계획
4. `execute`
   코드 수정
5. `review`
   내부 심의
6. `validate`
   테스트/빌드
7. `decide`
   성공/질문/실패 판단
8. `report`
   왕에게 결과 보고

## Bootstrap Knowledge 예시

```md
## Bootstrap Knowledge

작업 시작 전 아래 문서를 읽어라.

1. `apps/front/.claude/skills/frontend-doc/SKILL.md`
2. 필요하면 `.codex/skills/frontend-doc/`도 확인하라
3. 핵심 규칙을 1~2KB digest로 정리해 작업 중 계속 참조하라
```

## 내부 오케스트레이터

### planner

- 구현 계획 작성
- 변경 범위 제한

### risk-judge

- 요구사항 불명확성
- breaking change 가능성
- 범위 과대 여부

### validation-judge

- 테스트 결과가 충분한가
- 추가 검증이 필요한가
- 사람 판단 없이 종료 가능한가

## 사람 개입

기본 정책:

- 바로 사람에게 묻지 않음
- 내부 judge가 먼저 판단
- 마지막에만 `needs_human`

## Why Deferred Today

현재 `gen-jira`는:

- `friday:jira` 의존
- Claude 경로에서도 완성도가 낮음

그래서 바로 Codex 포팅보다, 하네스 장군으로 재설계하는 것이 우선이다.

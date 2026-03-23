# Operational Validation Checklist

> `4.0.0` multi-engine runtime 이후, 실제 운영에서 확인해야 할 항목을 정리한 체크리스트.

## 목적

- dual-engine 장군이 Claude/Codex 모두에서 기대한 품질로 동작하는지 확인
- 스케줄, Slack, GitHub side effect가 실제 운영 환경에서도 안전한지 검증
- 모든 builtin 장군의 실사용 준비 상태를 판단

## 우선순위

1. `gen-pr`
2. `gen-test-writer`
3. `gen-catchup`
4. `gen-briefing`
5. `gen-doctor`
6. `gen-herald`

이 순서는 실패 비용과 사용자 체감 가치 기준이다.

## 공통 검증 항목

모든 dual-engine 장군 및 active harness 장군에 대해 Claude/Codex 각각 확인:

- [ ] manifest의 `supported_engines`와 실제 runtime 동작이 일치
- [ ] engine별 prompt 자산이 올바르게 선택됨
- [ ] `CLAUDE.md` / `AGENTS.md`가 workspace에 배치됨
- [ ] `agents/`, `skills/`가 `.claude/`, `.codex/`로 동기화됨
- [ ] 결과 JSON이 schema에 맞게 생성됨
- [ ] `summary`가 Slack 전송에 적합한 길이/형식인지 확인
- [ ] `memory_updates`가 과도하거나 무의미하지 않은지 확인

## gen-pr

### 성공 조건

- [ ] Claude에서 PR 리뷰가 정상 생성됨
- [ ] Codex에서 동일 PR에 대해 리뷰 요약/코멘트가 품질 기준을 충족
- [ ] `refresh_rules`가 `.codex/skills/frontend-doc/` 또는 fallback 경로를 읽어 digest 생성
- [ ] meta-reviewer 단계가 과도한 false positive 없이 동작
- [ ] GitHub review 제출이 정상 동작

### 확인 포인트

- [ ] skip 기준 (`draft`, `release/*`, FE 변경 없음) 일관성
- [ ] `REQUEST_CHANGES` / `APPROVE` 판단 품질
- [ ] line comment와 summary의 구체성

### 실패 신호

- 리뷰 코멘트가 지나치게 일반적임
- 근거 없는 nitpick 과다
- meta-review 결과가 실제 품질 향상에 기여하지 않음

## gen-test-writer

### 성공 조건

- [ ] Claude에서 plugin-free workflow로 테스트 1개를 안정적으로 작성
- [ ] Codex에서도 대상 선정과 테스트 작성이 과도하게 흔들리지 않음
- [ ] commit / push / draft PR 생성 흐름이 재현됨
- [ ] merge 모드에서 ready + auto-merge가 안전하게 동작

### 확인 포인트

- [ ] 테스트 대상 선정 기준이 납득 가능함
- [ ] 작성된 테스트가 “작은 유효 검증”인지
- [ ] snapshot/fixture 남용 여부
- [ ] 최소 검증 단계가 너무 무겁지 않은지

### 실패 신호

- 매번 무작위성 높은 파일 선택
- flaky test 또는 과도한 integration test 작성
- PR 누적 전략이 브랜치/merge 흐름과 충돌

## gen-catchup

### 성공 조건

- [ ] collect 모드에서 PR 목록 수집이 정확함
- [ ] 요약이 스탠드업용으로 충분히 간결함
- [ ] Canvas rename + replace 2단계 호출이 안정적임
- [ ] share 모드에서 proclamation 링크가 정확함

### 확인 포인트

- [ ] large/small PR 분류 품질
- [ ] review comments에서 학습 포인트 추출 품질
- [ ] Canvas API 실패 시 에러 보고 품질

### 실패 신호

- PR 수집 누락
- 요약이 장황하거나 PR 번호/링크 누락
- Canvas overwrite 규칙 위반

## gen-briefing

### 성공 조건

- [ ] 리소스/heartbeat/queue 상태가 실제 상태와 맞음
- [ ] 브리핑 형식이 한눈에 읽힘
- [ ] Heads Up 판단이 과하지 않음

### 실패 신호

- 단순 수집값 나열에 그침
- 실제 이상을 놓침

## gen-doctor

### 성공 조건

- [ ] 최근 실패 목록 요청이 자연스럽게 동작
- [ ] task_id 기반 상세 진단이 유의미함
- [ ] 원인 추정과 해결 방향이 구체적임

### 실패 신호

- 증거 없이 추측만 많음
- stderr/raw/result를 제대로 엮지 못함

## gen-herald

### 성공 조건

- [ ] 일상 DM 응답이 짧고 자연스러움
- [ ] 시스템 질문을 `gen-briefing`으로 잘 유도
- [ ] Codex와 Claude의 톤 차이가 과하지 않음

### 실패 신호

- 지나치게 길거나 generic한 답변
- 브리핑 요청 유도가 어색함

## gen-harness-querypie-mono

### 성공 조건

- [ ] Jira 이벤트에서 올바른 intake/plan이 생성됨
- [ ] petition-routed Slack 요청도 동일한 하네스 흐름으로 처리됨
- [ ] bootstrap knowledge가 실제 querypie-mono 문서를 충분히 반영함
- [ ] Codex/Claude 모두에서 plan / validate / decide 품질이 과도하게 흔들리지 않음

### 확인 포인트

- [ ] repo-bound 범위를 벗어나지 않는지
- [ ] `needs_human`이 너무 늦지 않은지
- [ ] 계획이 과도하게 커지지 않는지

### 실패 신호

- bootstrap 없이 바로 구현으로 들어감
- plan이 모호하거나 과하게 큼
- validation이 형식적이거나 누락됨

## 운영 판단 기준

각 장군에 대해 아래 3단계로 판단한다.

- `ready`: 운영 투입 가능
- `watch`: 동작은 하나 품질/안정성 추가 관찰 필요
- `deferred`: 구조상 더 손봐야 함

현재 예상:

- `gen-pr`: watch
- `gen-test-writer`: watch
- `gen-catchup`: watch
- `gen-briefing`: ready
- `gen-doctor`: ready
- `gen-herald`: ready
- `gen-harness-querypie-mono`: watch

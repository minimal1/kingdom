# Harness General Mode

> 자발적 개발형 장군을 위한 실행 프로토콜.

## 목적

기존 장군은 크게 두 부류로 나뉜다.

- `automation`: 절차가 명확한 장군
- `harnessed_dev`: 스스로 계획하고 구현하고 검증해야 하는 장군

`gen-harness-querypie-mono` 같은 장군은 후자에 해당한다. 이 문서는 그런 장군의 공통 하네스 모드를 정의한다.

## 왜 필요한가

단일 프롬프트만으로는 다음을 안정적으로 강제하기 어렵다.

- 요구사항 해석
- 작업 계획
- 범위 통제
- 검증
- 리스크 판단
- 사람 질문 조건

하네스 모드는 장군 내부에 이 절차를 명시적으로 둔다.

## 장군 모드

manifest 예시:

```yaml
mode: harnessed_dev
harness:
  profile: querypie-mono-dev
  phases:
    - bootstrap
    - intake
    - plan
    - execute
    - review
    - validate
    - decide
    - report
```

## 기본 원칙

1. 하네스 장군은 가능하면 레포 1:1로 운용한다
2. 문서 원문은 레포가 소유한다
3. 장군은 bootstrap 단계에서 문서를 읽고 digest만 memory에 남긴다
4. 사람 질문은 기본 경로가 아니라 예외 경로다
5. 구현 판단은 장군이, 리스크 판단은 내부 judge가 맡는다

## Phase 정의

### 1. bootstrap

목적:

- 레포 문서/skills/bootstrap knowledge 읽기
- 작업 전 필요한 배경지식 확보

예:

- `.claude/skills/...`
- `.codex/skills/...`
- 레포 문서
- 이전 memory digest

### 2. intake

목적:

- 티켓/요청 해석
- 범위, 제약, open question 식별

산출물:

- 문제 요약
- 범위
- 불명확한 점

### 3. plan

목적:

- 구현 계획 수립

산출물:

- 변경 파일 후보
- 작업 순서
- 위험 요소
- 검증 계획

### 4. execute

목적:

- 작은 단위 수정

원칙:

- 큰 변경을 한 번에 하지 않는다
- 계획과 어긋나면 다음 phase에서 재검토

### 5. review

목적:

- 내부 오케스트레이터의 첫 심의

판단:

- 계획이 여전히 타당한가
- 범위가 과도한가
- 추가 질문 없이 진행 가능한가

### 6. validate

목적:

- 테스트, 빌드, 정적 검증

### 7. decide

목적:

- 최종 분기 결정

가능한 판단:

- `success`
- `failed`
- `skipped`
- `needs_human`
- 내부 재시도
- 범위 축소 후 재수행

### 8. report

목적:

- 최종 요약 생성
- memory 업데이트 생성

## 내부 오케스트레이터

하네스 장군 내부에는 최소 세 역할이 있다고 본다.

- `planner`
- `risk-judge`
- `validation-judge`

이들은 별도 프로세스라기보다, 장군 prompt 안에서 분리된 판단 레이어로 구현될 수 있다.

## 사람 개입

사람 개입은 즉시 발생하지 않는다.

순서:

1. 장군 내부 judge가 먼저 판단
2. 그래도 불확실하면 `needs_human`

즉 `needs_human`는 마지막 안전장치다.

## 적용 대상

예상 대상:

- `gen-harness-querypie-mono`
- 미래의 repo-bound 개발 장군
- 큰 리팩터링 장군

비대상:

- `gen-briefing`
- `gen-herald`
- `gen-doctor`
- `gen-catchup`

## 관련 문서

- [docs/spec/roles/general.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/spec/roles/general.md)
- [docs/analysis/gen-jira-deferred.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/analysis/gen-jira-deferred.md)

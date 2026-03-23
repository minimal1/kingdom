# gen-harness-querypie-mono

`querypie-mono` 레포 전용 harnessed_dev 장군.

## 목적

- Jira 티켓 기반 개발
- Slack 요청 기반 개발 (petition 결과로 라우팅)
- repo-bound bootstrap / plan / validate 프로토콜 적용

## Trigger Model

### 직접 구독

- `jira.ticket.assigned`
- `jira.ticket.updated`

### 간접 라우팅

- Slack DM / mention은 왕의 petition 결과를 통해 이 장군으로 라우팅

즉 Slack 이벤트를 직접 subscribe하지 않고, petition judgement를 통해 들어오는 구조를 권장한다.

## 자산

- `prompt-codex.md`
- `prompt-claude.md`
- `general-codex.md`
- `general-claude.md`
- `bootstrap-knowledge.md`
- `repo-rules.md`

## 상태

활성 장군. `gen-jira`의 successor로 간주한다.

공통 하네스 규칙은 package 안에 두지 않고 Kingdom 시스템의 `config/harness/*.md`를 사용한다.

## 엔진 지원

- Claude: 지원
- Codex: 지원 (운영 검증 필요)

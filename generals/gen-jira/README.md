# gen-jira — Jira Ticket Implementation General

Jira 티켓을 자동으로 구현하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- `claude` CLI 설치 (CC Plugin 자동 설치에 필요)

## 설치

```bash
./install.sh
```

`install.sh`가 자동으로 수행하는 작업:
1. `qp-plugin` 마켓플레이스 등록 (`eddy-jeon/qp-plugin`)
2. `sunday` CC Plugin 설치 (`sunday@qp-plugin`)
3. Kingdom 런타임에 장군 설치 (`install-general.sh` 호출)

수동 설치도 가능:

```bash
# 플러그인 별도 설치
claude plugin marketplace add eddy-jeon/qp-plugin
claude plugin install sunday@qp-plugin

# Kingdom에 장군만 설치
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-jira
```

## 구독 이벤트

| 이벤트 | 설명 |
|--------|------|
| jira.ticket.assigned | Jira 티켓 할당 |
| jira.ticket.updated | Jira 티켓 업데이트 |

## 설정

- timeout: 5400초 (90분)
- 스케줄: 없음 (이벤트 기반)

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-jira
```

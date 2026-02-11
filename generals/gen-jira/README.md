# gen-jira — Jira Ticket Implementation General

Jira 티켓을 자동으로 구현하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- CC Plugin `sunday` 전역 설치: `claude plugin install /path/to/sunday`

## 설치

```bash
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-jira
```

또는 패키지 디렉토리에서:

```bash
./install.sh
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

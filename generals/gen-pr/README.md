# gen-pr — PR Review General

PR 리뷰를 자동으로 수행하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- CC Plugin `friday` 전역 설치: `claude plugin install /path/to/friday`

## 설치

```bash
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-pr
```

또는 패키지 디렉토리에서:

```bash
./install.sh
```

## 구독 이벤트

| 이벤트 | 설명 |
|--------|------|
| github.pr.review_requested | PR 리뷰 요청 |
| github.pr.mentioned | PR 멘션 |
| github.pr.assigned | PR 할당 |

## 설정

- timeout: 1800초 (30분)
- 스케줄: 없음 (이벤트 기반)

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-pr
```

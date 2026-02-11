# gen-pr — PR Review General

PR 리뷰를 자동으로 수행하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- `claude` CLI 설치 (CC Plugin 자동 설치에 필요)

## 설치

```bash
./install.sh
```

`install.sh`가 자동으로 수행하는 작업:
1. `qp-plugin` 마켓플레이스 등록 (`eddy-jeon/qp-plugin`)
2. `friday` CC Plugin 설치 (`friday@qp-plugin`)
3. Kingdom 런타임에 장군 설치 (`install-general.sh` 호출)

수동 설치도 가능:

```bash
# 플러그인 별도 설치
claude plugin marketplace add eddy-jeon/qp-plugin
claude plugin install friday@qp-plugin

# Kingdom에 장군만 설치
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-pr
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

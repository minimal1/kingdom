# gen-test — Test Writing General

테스트 코드를 자동으로 작성하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- `claude` CLI 설치 (CC Plugin 자동 설치에 필요)

## 설치

```bash
./install.sh
```

`install.sh`가 자동으로 수행하는 작업:
1. `qp-plugin` 마켓플레이스 등록 (`eddy-jeon/qp-plugin`)
2. `saturday` CC Plugin 설치 (`saturday@qp-plugin`)
3. Kingdom 런타임에 장군 설치 (`install-general.sh` 호출)

수동 설치도 가능:

```bash
# 플러그인 별도 설치
claude plugin marketplace add eddy-jeon/qp-plugin
claude plugin install saturday@qp-plugin

# Kingdom에 장군만 설치
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-test
```

## 구독 이벤트

없음 (스케줄 기반)

## 스케줄

| 이름 | cron | 설명 |
|------|------|------|
| daily-test | `0 22 * * 1-5` | 평일 22:00 테스트 생성 |

## 설정

- timeout: 3600초 (60분)

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-test
```

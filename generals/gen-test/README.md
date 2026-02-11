# gen-test — Test Writing General

테스트 코드를 자동으로 작성하는 장군.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- CC Plugin `saturday` 전역 설치: `claude plugin install /path/to/saturday`

## 설치

```bash
$KINGDOM_BASE_DIR/bin/install-general.sh /path/to/gen-test
```

또는 패키지 디렉토리에서:

```bash
./install.sh
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

# gen-herald — Kingdom 전령관

DM 대화, 시스템 정보 조회, 일상 소통을 담당하는 장군.
petition 분류 실패 시 catch-all로 동작한다.

## 사전 요구사항

- Kingdom 시스템 설치 완료

## 설치

```bash
./install.sh
```

CC 플러그인 없이 `install-general.sh`만 호출한다.

## 처리 범위

- **시스템 상태**: 역할 heartbeat, 큐 현황, 리소스, 병사 수
- **시스템 정보**: 장군 목록, Kingdom 구조
- **일상 대화**: 인사, 잡담, 기타 DM

## 이벤트 구독

| 이벤트 | 설명 |
|--------|------|
| `slack.channel.message` | DM 메시지 catch-all |

## 설정

- timeout: 120초 (2분)
- 스케줄: 없음 (이벤트 기반)

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-herald
```

# gen-briefing — Kingdom Briefing General

Kingdom 시스템 상태를 브리핑하는 장군.
DM으로 브리핑을 요청하면 petition이 gen-briefing으로 라우팅한다.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- `SLACK_BOT_TOKEN` 환경변수 설정

## 설치

```bash
./install.sh
```

CC 플러그인 없이 `install-general.sh`만 호출한다.

## 설정

- timeout: 120초 (2분)
- 이벤트 구독: 없음 (petition 라우팅으로 트리거)
- 스케줄: 없음

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-briefing
```

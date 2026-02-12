# gen-briefing — Kingdom Briefing Cat General

Kingdom 시스템 상태를 10분마다 Slack에 브리핑하는 장군.
고양이 말투(~냥)로 가독성 높은 포맷을 사용한다.

## 사전 요구사항

- Kingdom 시스템 설치 완료
- `SLACK_BOT_TOKEN` 환경변수 설정

## 설치

```bash
./install.sh
```

CC 플러그인 없이 `install-general.sh`만 호출한다.

## 스케줄

| 이름 | cron | 설명 |
|------|------|------|
| briefing-10min | `*/10 * * * *` | 10분마다 시스템 브리핑 |

## Slack 채널

기본 채널은 `#kingdom`이며, `prompt.md`에서 직접 지정한다.
변경하려면 `prompt.md`의 채널명을 수정하면 된다.

## 설정

- timeout: 120초 (2분)
- 이벤트 구독: 없음 (스케줄 기반)

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-briefing
```

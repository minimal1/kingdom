# gen-catchup — 일간 PR 캐치업 장군

매일 오전 9시(KST), 지정된 레포의 지난 1일간 머지된 PR을 분석하여 Slack Canvas에 게시한다.

## 사전 요구사항

1. **Slack Bot OAuth scope**: `canvases:write` 추가 필요
2. **Slack Canvas 생성**: 레포별 Canvas를 미리 생성하고 Canvas ID(F로 시작) 확보
3. **Slack Bot OAuth scope**: `chat:write` (PR News 공유용)
4. **공유 채널**: PR News를 게시할 팀 채널 ID 확인

### Canvas ID 확보 방법

1. Slack에서 Canvas를 생성
2. Canvas 우측 상단 `...` → `Copy link`
3. URL에서 Canvas ID 추출: `https://app.slack.com/docs/T.../F07XXXXXXXX` → `F07XXXXXXXX`

## 설치

```bash
# prompt.md의 TODO 항목을 먼저 채운 후 실행
./install.sh
```

## 설정

- **timeout**: 900초 (15분)
- **이벤트 구독**: 없음 (순수 스케줄 기반)
- **스케줄**: 매일 09:00 KST (`0 0 * * *` UTC)
- **플러그인**: friday@qp-plugin (pr-catchup 스킬)

## prompt.md 설정

설치 전 `prompt.md`의 TODO 항목을 채워야 한다:

| placeholder | 설명 | 예시 |
|-------------|------|------|
| `TODO_REPO_A` | 첫 번째 레포 | `chequer-io/querypie-frontend` |
| `TODO_BRANCH_A` | 첫 번째 브랜치 | `main` |
| `TODO_CANVAS_ID_A` | 첫 번째 Canvas ID | `F07XXXXXXXXX` |
| `TODO_REPO_B` | 두 번째 레포 | `chequer-io/querypie-api` |
| `TODO_BRANCH_B` | 두 번째 브랜치 | `main` |
| `TODO_CANVAS_ID_B` | 두 번째 Canvas ID | `F07YYYYYYYYY` |
| `TODO_SHARE_CHANNEL_ID` | PR News 공유 채널 | `C07ZZZZZZZZZ` |
| `TODO_WORKSPACE_ID` | Slack 워크스페이스 ID | `T07XXXXXXXXX` |

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-catchup
```

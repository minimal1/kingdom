# gen-test-writer — 테스트 자동 작성 장군

30분마다 `chequer-io/querypie-mono` 레포의 `develop` 브랜치에서 테스트 코드 1개를 자동 작성하고 PR을 오픈한다.

현재는 자립형 Claude workflow를 사용하며, Codex 자산도 추가되었다.

## 사전 요구사항

1. **GitHub 접근**: `chequer-io/querypie-mono` 레포에 push 및 PR 생성 권한
2. **워크스페이스**: `~/workspace/chequer-io/querypie-mono` 클론 필요

## 설치

```bash
./install.sh
```

## 설정

- **timeout**: 1800초 (30분)
- **이벤트 구독**: 없음 (순수 스케줄 기반)
- **스케줄**: 30분 주기 (`*/30 * * * *`)
- **플러그인**: 없음 (자립형)

## Codex 포팅 상태

Codex 자산을 추가했다. 현재 `supported_engines`는 `claude`, `codex`를 모두 포함한다.

정리 문서:

- [docs/analysis/gen-test-writer-portability.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/analysis/gen-test-writer-portability.md)

초안 자산:

- `design/prompt-claude-draft.md`
- `design/prompt-codex-draft.md`

활성 자산:

- `prompt.md` (Claude 기본)
- `prompt-codex.md`
- `general-codex.md`

## 동작 흐름

1. `develop` 브랜치 최신화 (`git pull`)
2. `test/auto-{timestamp}` 브랜치 생성
3. 테스트 후보를 스스로 선정하고 테스트 코드 1개 작성
4. 커밋 → push → `develop` 기준 PR 오픈
5. `develop` 브랜치로 복귀

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-test-writer
```

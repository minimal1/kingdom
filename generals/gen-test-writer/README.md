# gen-test-writer — 테스트 자동 작성 장군

30분마다 `chequer-io/querypie-mono` 레포의 `develop` 브랜치에서 테스트 코드 1개를 자동 작성하고 PR을 오픈한다.

## 사전 요구사항

1. **friday@qp-plugin**: `write-test` 스킬이 포함된 CC 플러그인
2. **GitHub 접근**: `chequer-io/querypie-mono` 레포에 push 및 PR 생성 권한
3. **워크스페이스**: `~/workspace/chequer-io/querypie-mono` 클론 필요

## 설치

```bash
./install.sh
```

## 설정

- **timeout**: 1800초 (30분)
- **이벤트 구독**: 없음 (순수 스케줄 기반)
- **스케줄**: 30분 주기 (`*/30 * * * *`)
- **플러그인**: friday@qp-plugin (write-test 스킬)

## 동작 흐름

1. `develop` 브랜치 최신화 (`git pull`)
2. `test/auto-{timestamp}` 브랜치 생성
3. `/friday:write-test` 스킬로 테스트 코드 1개 작성
4. 커밋 → push → `develop` 기준 PR 오픈
5. `develop` 브랜치로 복귀

## 제거

```bash
$KINGDOM_BASE_DIR/bin/uninstall-general.sh gen-test-writer
```

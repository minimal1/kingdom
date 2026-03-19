# gen-test-writer Portability Assessment

> `gen-test-writer`는 이제 Claude 경로에서 `friday:test` 의존을 제거했고, 다음 단계로 Codex 포팅을 준비하는 장군이다.

## 현재 상태

관련 파일:

- [generals/gen-test-writer/manifest.yaml](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/manifest.yaml)
- [generals/gen-test-writer/prompt.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/prompt.md)
- [generals/gen-test-writer/install.sh](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/install.sh)
- [generals/gen-test-writer/README.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/README.md)

현재 장군은 `supported_engines: [claude]`이며, Codex 포팅은 아직 열지 않았다.

## 무엇이 이미 분리돼 있는가

`friday:test` 바깥의 orchestration은 이미 명확하다.

1. base branch 최신화
2. `test/auto-writer/*` 브랜치 준비
3. 테스트 1개 작성
4. commit / push
5. draft PR 생성
6. 주기적 merge 시 ready + auto-merge

즉 장군의 바깥 흐름은 Codex/Claude 공통으로 유지 가능하다.

## 진짜 문제

불명확한 것은 `/friday:test` 내부 판단이다.

- 어떤 파일을 테스트 대상으로 고르는가
- 테스트 프레임워크를 어떻게 고르는가
- 기존 테스트가 있는 파일을 어떻게 다루는가
- flaky / integration / unit 범위를 어떻게 제한하는가
- 생성 후 무엇을 검증하는가

즉 Codex 포팅의 핵심 난도는 “테스트 생성 전략”이 plugin 안에 숨어 있다는 점이다.

## 진행 상태

이미 반영된 것:

- Claude 경로는 plugin-free workflow로 전환
- `prompt.md`가 테스트 대상 선정/작성/최소 검증 절차를 직접 지시
- install 경로에서 `friday` 플러그인 설치 제거

남은 것:

- Codex용 자산(`prompt-codex.md`, `general-codex.md`) 추가
- 실제 Codex 포팅 시 검증 전략 튜닝

## 권장 방향

다음 단계는 Stage 2, 즉 Codex 자산 추가다.

1. `prompt-codex.md`
2. 필요 시 `general-codex.md`
3. `supported_engines: [claude, codex]`

## plugin-free target workflow (draft)

### mode: write

1. `git fetch origin {base}`
2. 작업 브랜치 준비
3. 최근 변경 파일 / 테스트 부족 후보 탐색
4. 테스트 1개 작성
5. 관련 테스트만 우선 실행
6. commit / push
7. draft PR 생성 또는 기존 PR 누적

### mode: merge

1. `test/auto-writer/*` PR 탐색
2. ready 상태 전환
3. auto-merge 설정

## Codex migration checklist

- [ ] 테스트 대상 선정 규칙 정의
- [ ] 테스트 작성 범위 정의 (unit 우선인지, integration 허용인지)
- [ ] 최소 검증 명령 정의
- [ ] PR body 템플릿 정의
- [ ] 실패/skip 기준 정의
- [ ] Claude/Codex 공통 prompt 초안 작성
- [ ] 그 후에만 Codex 자산 추가

## Draft assets

초안 자산은 장군 패키지 안에 추가되었고, Claude 쪽은 이미 활성 템플릿으로 승격되었다. Codex 초안은 아직 비활성 설계 자산이다.

- [generals/gen-test-writer/design/prompt-claude-draft.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/design/prompt-claude-draft.md)
- [generals/gen-test-writer/design/prompt-codex-draft.md](/Users/eddy/Documents/worktree/lab/lil-eddy/generals/gen-test-writer/design/prompt-codex-draft.md)

## 결론

`gen-test-writer`는 이제 plugin-free Claude 장군이 되었고, 다음 단계로 Codex 포팅을 진행할 수 있다.

- 현재: `claude-only` 유지, plugin-free workflow 활성
- 다음 작업: Codex 자산 추가

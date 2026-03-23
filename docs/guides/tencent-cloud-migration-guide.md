# Tencent Cloud Migration Guide

> Kingdom `1.0.0` 환경을 Tencent Cloud Ubuntu 서버에서 `4.0.0`으로 마이그레이션하는 가이드.

## 원칙

`1.0.0 -> 4.0.0`은 **인플레이스 업그레이드보다 신규 설치 + 선별 이관**이 안전하다.

이유:

- 런타임 구조가 크게 바뀌었다
- Socket Mode 전용 Slack 경로가 들어갔다
- multi-engine runtime 설정이 생겼다
- builtin 장군 구조와 자산 배치가 달라졌다

권장 전략:

1. 기존 `/opt/kingdom`은 보존
2. 새 버전은 `/opt/kingdom-v4`에 설치
3. 설정/메모리만 선별 이관
4. 검증 후 cutover

## 1. 기존 환경 백업

```bash
cp -R /opt/kingdom /opt/kingdom-backup-1.0.0
```

## 2. 기존 런타임 중지

세션 확인:

```bash
tmux ls
```

Core 세션 중지:

```bash
tmux kill-session -t chamberlain || true
tmux kill-session -t sentinel || true
tmux kill-session -t envoy || true
tmux kill-session -t king || true
```

장군 / 병사 세션 중지:

```bash
tmux ls | awk -F: '/^gen-/{print $1}' | xargs -I{} tmux kill-session -t {} || true
tmux ls | awk -F: '/^soldier-/{print $1}' | xargs -I{} tmux kill-session -t {} || true
```

## 3. 새 코드 배치

```bash
git clone <REPO_URL> /opt/kingdom-v4
cd /opt/kingdom-v4
git checkout <4.0.0 tag or production branch>
```

## 4. 의존성 설치

Ubuntu 기준:

```bash
sudo apt update
sudo apt install -y git tmux jq bc curl
```

Node 의존성:

```bash
cd /opt/kingdom-v4
npm install --production
```

필수 도구:

- `gh`
- `yq`
- `node`
- `claude` and/or `codex`

## 5. 새 런타임 초기화

```bash
cd /opt/kingdom-v4
bin/init-dirs.sh
```

## 6. 무엇을 이관할 것인가

### 복사해도 되는 것

- `.env`
- `memory/shared/*`
- `memory/generals/*`
- 기존 config의 **운영값**

### 복사하면 안 되는 것

- `queue/`
- `state/`
- `logs/`
- `workspace/`
- `sessions.json`

이들은 상태 찌꺼기이므로 새 버전에 그대로 넣지 않는다.

## 7. 설정/메모리 이관

### `.env`

```bash
cp /opt/kingdom/.env /opt/kingdom-v4/.env
sed -n '1,200p' /opt/kingdom-v4/.env
```

확인할 값:

- `GH_TOKEN`
- `JIRA_API_TOKEN`
- `JIRA_URL`
- `JIRA_USER_EMAIL`
- `SLACK_BOT_TOKEN`
- `SLACK_APP_TOKEN`

### memory

```bash
mkdir -p /opt/kingdom-v4/memory/shared /opt/kingdom-v4/memory/generals
cp -R /opt/kingdom/memory/shared/. /opt/kingdom-v4/memory/shared/ 2>/dev/null || true
cp -R /opt/kingdom/memory/generals/. /opt/kingdom-v4/memory/generals/ 2>/dev/null || true
```

### config

직접 diff를 보고 필요한 값만 반영:

```bash
diff -u /opt/kingdom/config/sentinel.yaml /opt/kingdom-v4/config/sentinel.yaml || true
diff -u /opt/kingdom/config/king.yaml /opt/kingdom-v4/config/king.yaml || true
diff -u /opt/kingdom/config/envoy.yaml /opt/kingdom-v4/config/envoy.yaml || true
```

## 8. 장군 설정 이관

설치된 장군 목록 비교:

```bash
find /opt/kingdom/config/generals -maxdepth 1 -name '*.yaml' | sort
find /opt/kingdom-v4/config/generals -maxdepth 1 -name '*.yaml' | sort
```

주의:

- `gen-catchup`은 `TODO_*`를 운영값으로 다시 채워야 한다
- `gen-jira`는 현재 보류 권장

## 9. 실행 엔진 확인

현재 기본 엔진은 `claude`다.

```bash
sed -n '1,80p' /opt/kingdom-v4/config/system.yaml
```

Codex를 기본으로 쓸 경우:

```yaml
runtime:
  engine: "codex"
```

## 10. 사전 점검

```bash
cd /opt/kingdom-v4
bin/check-prerequisites.sh
```

중요 확인 항목:

- `Claude Code` 또는 `Codex`
- `GitHub`
- `Slack`
- `Slack App`

## 11. 기동

```bash
cd /opt/kingdom-v4
bin/start.sh
bash bin/status.sh
```

## 12. 운영 검증 순서

우선순위:

1. `gen-briefing`
2. `gen-doctor`
3. `gen-herald`
4. `gen-pr`
5. `gen-catchup`
6. `gen-test-writer`

체크리스트:

- [docs/guides/operational-validation-checklist.md](/Users/eddy/Documents/worktree/lab/lil-eddy/docs/guides/operational-validation-checklist.md)

## 13. Cutover

검증이 끝나면 운영 경로를 새 버전으로 전환한다.

### 방법 A: 서비스/unit 파일의 working directory 변경

기존 서비스 정의에서 `/opt/kingdom`을 `/opt/kingdom-v4`로 교체

### 방법 B: symlink 사용

```bash
ln -sfn /opt/kingdom-v4 /opt/kingdom-current
```

이후 서비스는 `/opt/kingdom-current`를 기준으로 보게 한다.

## 14. Rollback

문제가 생기면:

1. 새 런타임 중지
2. 기존 `/opt/kingdom` 세션 재기동
3. 필요 시 백업 사용

```bash
cp -R /opt/kingdom-backup-1.0.0 /opt/kingdom-rollback
```

## 요약

- `1.0.0 -> 4.0.0`은 재설치가 맞다
- 상태 디렉토리는 옮기지 않는다
- 설정과 memory만 선별 이관한다
- 운영 검증 후에만 cutover 한다

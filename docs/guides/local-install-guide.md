# Kingdom 로컬 설치 & 테스트 가이드

## 1. 사전 준비

### 1.1 CLI 도구 (macOS)

```bash
brew install jq tmux bc
brew install mise

# mise로 런타임 설치
mise use --global node@22
mise use --global yq@latest

# claude code (이미 설치되어 있을 것)
```

### 1.2 환경변수

```bash
# ~/.zshrc 또는 ~/.bashrc에 추가
export JIRA_URL="https://chequer.atlassian.net"
export JIRA_API_TOKEN="..."          # Atlassian API Token
export SLACK_BOT_TOKEN="xoxb-..."    # Slack Bot Token (사절 역할에 필요)

# GitHub: gh auth login 으로 인증 (GH_TOKEN 불필요 — gh CLI가 keyring 사용)
```

> **최소 요구:** GitHub 인증만 있으면 핵심 파이프라인(Sentinel→King→General) 테스트 가능.
> Jira/Slack은 해당 역할(파수꾼 Jira watcher, 사절)에만 필요.

### 1.3 설치 경로 결정

| 환경 | 경로 | 비고 |
|------|------|------|
| 로컬 테스트 | `~/kingdom` | sudo 불필요 |
| EC2 프로덕션 | `/opt/kingdom` | systemd 서비스와 연동 |

```bash
export KINGDOM_BASE_DIR=~/kingdom
```

---

## 2. 설치

### 2.1 소스 복사

```bash
# 프로젝트 루트에서 실행
SRC=$(pwd)
mkdir -p $KINGDOM_BASE_DIR

# 실행 파일 복사
cp -r $SRC/bin $KINGDOM_BASE_DIR/
cp -r $SRC/config $KINGDOM_BASE_DIR/

# 실행 권한 부여
chmod +x $KINGDOM_BASE_DIR/bin/*.sh
```

### 2.2 디렉토리 초기화

```bash
$KINGDOM_BASE_DIR/bin/init-dirs.sh
```

### 2.2.1 빌트인 장군 설치

```bash
for pkg in $SRC/generals/gen-*; do
  $KINGDOM_BASE_DIR/bin/install-general.sh "$pkg"
done
```

출력 예시:
```
Kingdom directories initialized at /Users/eddy/kingdom
```

생성되는 구조:
```
~/kingdom/
├── bin/                  # 실행 파일 (복사됨)
├── config/               # YAML 설정 (복사됨)
├── queue/
│   ├── events/{pending,dispatched,completed}/
│   ├── tasks/{pending,in_progress,completed}/
│   └── messages/{pending,sent}/
├── state/
│   ├── king/             # task-seq, msg-seq
│   ├── sentinel/         # heartbeat, seen/
│   ├── envoy/            # thread-mappings, awaiting-responses
│   ├── chamberlain/
│   ├── results/          # 병사 실행 결과
│   ├── prompts/          # 프롬프트 파일
│   ├── sessions.json     # 활성 병사 목록
│   └── resources.json    # 시스템 헬스
├── memory/               # 장군별 학습 메모리
├── logs/                 # system.log, events.log
└── workspace/            # 장군별 작업 디렉토리
```

> 이전 버전에서는 `plugins/` 디렉토리와 workspace별 `.claude/plugins.json`이 있었으나, 현재는 전역 설치 방식으로 변경.

### 2.3 환경 검증

```bash
$KINGDOM_BASE_DIR/bin/check-prerequisites.sh
```

출력 예시:
```
Kingdom Prerequisites Check
═══════════════════════════════════
  [OK] jq          1.8.1
  [OK] yq          4.47.2
  [OK] gh          2.74.0
  [OK] tmux        3.6a
  [OK] bc          installed
  [OK] node        22.19.0
  [OK] claude      installed
═══════════════════════════════════
  [OK] GitHub       authenticated (eddy-jeon)
  [FAIL] Jira      JIRA_URL not set          ← Jira 미사용 시 무시 가능
  [FAIL] Slack     SLACK_BOT_TOKEN not set   ← Slack 미사용 시 무시 가능
═══════════════════════════════════
```

---

## 3. CC 플러그인 설정 (선택)

장군들이 `claude -p` 실행 시 사용하는 플러그인. 없어도 동작하지만 리뷰 품질이 달라짐.
플러그인은 **전역 설치** (`~/.claude/settings.json`의 `enabledPlugins`)가 필요하다.

각 장군 패키지의 `install.sh`가 CC Plugin 설치를 자동 수행하므로, 별도 설치가 불필요할 수 있다. 수동으로 설치하려면:

```bash
# 마켓플레이스 등록
claude plugin marketplace add eddy-jeon/qp-plugin

# 플러그인 설치
claude plugin install friday@qp-plugin

# 설치 확인 (객체 형식)
cat ~/.claude/settings.json | jq '.enabledPlugins'
# → { "friday@qp-plugin": true }
```

장군 매니페스트에서 필요한 플러그인 확인:
```yaml
# generals/gen-pr/manifest.yaml (소스) → install 후 config/generals/gen-pr.yaml (런타임)
cc_plugins:
  - friday@qp-plugin    # plugin-name@marketplace 형식
```

> `ensure_workspace`가 매니페스트의 `cc_plugins`를 읽어 전역 settings의 `enabledPlugins` 객체 키에서 해당 플러그인이 있는지 검증한다.

---

## 4. 실행

### 4.1 전체 시작

```bash
$KINGDOM_BASE_DIR/bin/start.sh
```

시작 순서: chamberlain → sentinel → envoy → king → gen-pr → gen-briefing

### 4.2 상태 확인

```bash
$KINGDOM_BASE_DIR/bin/status.sh
```

출력 예시:
```
Kingdom Status
═══════════════════════════════════════════

Core Sessions:
  [OK]   chamberlain      heartbeat: 3s
  [OK]   sentinel         heartbeat: 5s
  [OK]   envoy            heartbeat: 2s
  [OK]   king             heartbeat: 1s

Generals:
  [OK]   gen-pr           heartbeat: 8s
  [OK]   gen-briefing     heartbeat: 7s

Soldiers:
  Active: 0

Resources:
  Health: green  CPU: 12%  MEM: 45%  DISK: 30%

═══════════════════════════════════════════
```

### 4.3 전체 종료

```bash
$KINGDOM_BASE_DIR/bin/stop.sh
```

### 4.4 개별 역할 직접 실행 (디버깅용)

tmux 없이 포그라운드로 실행해서 로그를 직접 볼 수 있음:

```bash
# 파수꾼만 실행
KINGDOM_BASE_DIR=~/kingdom bash $KINGDOM_BASE_DIR/bin/sentinel.sh

# 왕만 실행
KINGDOM_BASE_DIR=~/kingdom bash $KINGDOM_BASE_DIR/bin/king.sh

# 장군만 실행
KINGDOM_BASE_DIR=~/kingdom bash $KINGDOM_BASE_DIR/bin/generals/gen-pr.sh
```

Ctrl+C로 종료 (graceful shutdown).

---

## 5. 수동 E2E 테스트

자동 테스트(bats 232개)와 별개로, 실제 외부 서비스를 사용하는 수동 테스트.

### 5.1 테스트 A: 이벤트 수동 주입 → 태스크 처리

Sentinel을 거치지 않고 이벤트를 직접 주입:

```bash
# 1. 가짜 GitHub PR 이벤트 생성
jq -n '{
  id: "evt-manual-test-001",
  type: "github.pr.review_requested",
  source: "github",
  priority: "normal",
  repo: "chequer/qp",
  payload: {pr_number: 999, title: "Manual test event"}
}' > $KINGDOM_BASE_DIR/queue/events/pending/evt-manual-test-001.json

# 2. King이 처리할 때까지 대기 (10초 간격으로 폴링)
# 또는 로그 확인:
tail -f $KINGDOM_BASE_DIR/logs/system.log | grep -E '\[king\]|\[gen-pr\]'
```

기대 흐름:
```
[king]    Dispatched: evt-manual-test-001 -> gen-pr (task: task-YYYYMMDD-001)
[gen-pr]  Task claimed: task-YYYYMMDD-001
[gen-pr]  Soldier spawned: soldier-...
           ↓ (claude -p 실행 — 실제 PR이 없으므로 실패할 수 있음)
[gen-pr]  Reported to king: task-YYYYMMDD-001 (success|failed)
[king]    Task completed: task-YYYYMMDD-001
```

### 5.2 테스트 B: 실제 GitHub 알림 감지

GitHub에서 PR 리뷰 요청을 받으면 Sentinel이 자동 감지:

```bash
# Sentinel 로그 확인
tail -f $KINGDOM_BASE_DIR/logs/system.log | grep '\[sentinel\]'
```

> **주의:** Sentinel은 `gh api /notifications`으로 알림을 폴링함.
> 테스트하려면 실제 PR에서 리뷰를 요청받거나, 자신에게 assign 해야 함.

### 5.3 테스트 C: 결과 파일 직접 확인

```bash
# 생성된 태스크 확인
ls $KINGDOM_BASE_DIR/queue/tasks/pending/
ls $KINGDOM_BASE_DIR/queue/tasks/in_progress/
ls $KINGDOM_BASE_DIR/queue/tasks/completed/

# 결과 파일 확인
ls $KINGDOM_BASE_DIR/state/results/

# 프롬프트 파일 확인 (병사에게 전달된 지시문)
cat $KINGDOM_BASE_DIR/state/prompts/task-*.md

# Slack 메시지 큐 확인 (Envoy가 처리 전)
ls $KINGDOM_BASE_DIR/queue/messages/pending/
cat $KINGDOM_BASE_DIR/queue/messages/pending/*.json | jq .
```

---

## 6. 로그 & 디버깅

### 6.1 로그 파일

```bash
# 전체 시스템 로그
tail -f $KINGDOM_BASE_DIR/logs/system.log

# 내부 이벤트 (JSONL)
tail -f $KINGDOM_BASE_DIR/logs/events.log | jq .

# 특정 역할만 필터
tail -f $KINGDOM_BASE_DIR/logs/system.log | grep '\[sentinel\]'
tail -f $KINGDOM_BASE_DIR/logs/system.log | grep '\[king\]'
tail -f $KINGDOM_BASE_DIR/logs/system.log | grep '\[gen-pr\]'

# 병사 실행 로그
ls $KINGDOM_BASE_DIR/logs/sessions/
```

### 6.2 tmux 세션 직접 접근

```bash
# 세션 목록
tmux ls

# 특정 세션 접속 (실시간 출력 확인)
tmux attach -t king
tmux attach -t sentinel
tmux attach -t gen-pr

# 빠져나오기: Ctrl+B, D (detach)
```

### 6.3 헬스 체크

```bash
# 리소스 상태
cat $KINGDOM_BASE_DIR/state/resources.json | jq .

# heartbeat 확인 (각 역할이 살아있는지)
ls -la $KINGDOM_BASE_DIR/state/*/heartbeat

# 활성 병사
cat $KINGDOM_BASE_DIR/state/sessions.json | jq .
```

---

## 7. 설정 튜닝

### 7.1 폴링 간격 (개발 중 빠르게)

```yaml
# config/sentinel.yaml
intervals:
  github_seconds: 30     # 기본 60 → 30으로 줄이면 빠른 감지
  jira_seconds: 60

# config/king.yaml
intervals:
  event_check_seconds: 5  # 기본 10 → 5
  result_check_seconds: 5
```

### 7.2 병사 동시 실행 수

```yaml
# config/king.yaml
concurrency:
  max_soldiers: 2         # 로컬 테스트 시 2로 제한 (리소스 절약)
```

### 7.3 GitHub 스코프 (감시 대상 레포)

```yaml
# config/sentinel.yaml
scope:
  repos:
    - "chequer/qp"
    - "chequer/qp-fe"
  reasons:
    - "review_requested"
    - "assign"
```

---

## 8. 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| `[DOWN] sentinel` | tmux 세션 크래시 | `bin/start.sh` 재실행 (watchdog이 자동 복구) |
| King이 이벤트 무시 | `resources.json` health가 yellow/red | `echo '{"health":"green"}' > state/resources.json` |
| 병사가 안 생김 | `max_soldiers` 초과 | `state/sessions.json`에서 죽은 세션 정리 |
| Sentinel 알림 없음 | GitHub 알림이 없음 | `gh api /notifications --jq 'length'`로 직접 확인 |
| `yq: command not found` | Python yq 설치됨 | `brew install mikefarah/yq/yq` (Go 버전) |
| 프롬프트가 비어있음 | 템플릿 파일 누락 | `config/generals/templates/` 확인 |

---

## 9. 정리 (언인스톨)

```bash
# 모든 세션 종료
$KINGDOM_BASE_DIR/bin/stop.sh

# 혹시 남은 세션 강제 종료
tmux kill-server  # 주의: 다른 tmux 세션도 종료됨

# 디렉토리 삭제
rm -rf $KINGDOM_BASE_DIR
```

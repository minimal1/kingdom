# Kingdom 설치 가이드

Linux(EC2) 또는 macOS 머신에 Kingdom을 설치하고 운영하는 가이드.

---

## 1. 요구 사항

### 1.1 하드웨어

| 환경 | 최소 | 권장 | 비고 |
|------|------|------|------|
| EC2 | M5.large (2 vCPU, 8GB) | M5.xlarge (4 vCPU, 16GB) | 동시 병사 3~5 |
| macOS | Apple Silicon 8GB | 16GB+ | 로컬 개발 또는 상시 운영 |
| 스토리지 | 50GB | 100GB GP3 SSD | 코드베이스 + 로그 + 메모리 |

### 1.2 OS 지원

| OS | 버전 | 비고 |
|------|------|------|
| Amazon Linux | 2023 | EC2 기본 |
| Ubuntu | 22.04+ | EC2 또는 자체 서버 |
| macOS | 14+ (Sonoma) | Apple Silicon |

---

## 2. 소프트웨어 설치

### Linux (Amazon Linux 2023)

```bash
# 시스템 업데이트
sudo dnf update -y

# 필수 패키지
sudo dnf install -y git tmux jq bc

# GitHub CLI
(type -p wget >/dev/null || sudo dnf install -y wget) \
  && wget -qO- https://cli.github.com/packages/rpm/gh-cli.repo \
  | sudo tee /etc/yum.repos.d/github-cli.repo \
  && sudo dnf install -y gh

# mise (런타임 매니저 — node, yq 등 통합 관리)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# mise 설정 디렉토리 소유권 확보 (root로 생성된 경우)
sudo chown -R $USER:$USER ~/.config/

# Node.js + yq (mise로 설치)
# AL2023의 gnupg2-minimal은 --trust-model 미지원 → GPG 검증 비활성화
MISE_NODE_VERIFY=false mise use --global node@22
mise use --global yq@latest

# Claude Code
curl -fsSL https://claude.ai/install.sh | sh
```

### Linux (Ubuntu 22.04+)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git tmux jq bc

# GitHub CLI
(type -p wget >/dev/null || sudo apt install -y wget) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update && sudo apt install -y gh

# mise (런타임 매니저)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# Node.js + yq (mise로 설치)
mise use --global node@22
mise use --global yq@latest

# Claude Code
curl -fsSL https://claude.ai/install.sh | sh
```

### macOS

```bash
brew install jq tmux bc gh

# mise (런타임 매니저)
brew install mise
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc

# Node.js + yq (mise로 설치)
mise use --global node@22
mise use --global yq@latest

# Claude Code
curl -fsSL https://claude.ai/install.sh | sh
```

---

## 3. 외부 서비스 인증

Kingdom은 4개 외부 서비스에 연동한다.

### 3.1 Claude Code (병사 실행)

```bash
# OAuth 기반 인증 (Max Plan 구독 필요)
claude login
# → 브라우저에서 Anthropic 계정 인증
# → 토큰이 로컬에 자동 저장

# EC2 headless 환경:
#   방법 1) 로컬에서 인증 후 ~/.claude/ 디렉토리를 EC2에 복사
#   방법 2) SSH 포트 포워딩으로 브라우저 인증
#           ssh -L 8080:localhost:8080 ec2-user@your-ec2
```

> API Key(`CLAUDE_CODE_API_KEY`)가 아닌 OAuth 인증. 환경변수 불필요.

### 3.2 GitHub (파수꾼 — 알림 폴링)

```bash
# gh CLI 인증 (두 가지 방법)

# 방법 1: 브라우저 인증
gh auth login

# 방법 2: 토큰 인증 (headless)
export GH_TOKEN="ghp_..."
echo "$GH_TOKEN" | gh auth login --with-token

# 검증
gh api /notifications --jq 'length'
```

### 3.3 Jira (파수꾼 — 티켓 폴링)

```bash
export JIRA_USER_EMAIL="user@example.com"  # Atlassian 계정 이메일
export JIRA_API_TOKEN="..."                # Atlassian API Token
export JIRA_URL="https://your-domain.atlassian.net"

# 검증
curl -s -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_URL/rest/api/3/myself" | jq .displayName
```

> 토큰 발급: https://id.atlassian.com/manage-profile/security/api-tokens

### 3.4 Slack (사절 — 메시지 발송)

```bash
export SLACK_BOT_TOKEN="xoxb-..."

# 검증
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  https://slack.com/api/auth.test | jq .ok
```

> Bot 필요 권한 (OAuth Scopes):
> `chat:write`, `channels:history`, `channels:read`
>
> 발급: https://api.slack.com/apps → OAuth & Permissions → Install to Workspace

### 최소 요구

| 서비스 | 필수 여부 | 영향 범위 |
|--------|---------|---------|
| Claude Code | **필수** | 병사 실행 불가 |
| GitHub | **필수** | 파수꾼 GitHub watcher 불가 |
| Jira | 선택 | 파수꾼 Jira watcher 불가 |
| Slack | 선택 | 사절 불가 (알림/질문이 Slack에 안 감) |

---

## 4. 설치

### 4.1 설치 경로

| 환경 | 경로 | 환경변수 |
|------|------|---------|
| 프로덕션 (EC2) | `/opt/kingdom` | 기본값 (설정 불필요) |
| macOS 상시 운영 | `/opt/kingdom` | `sudo mkdir -p /opt/kingdom && sudo chown $USER /opt/kingdom` |
| macOS 테스트 | `~/kingdom` | `export KINGDOM_BASE_DIR=~/kingdom` |

### 4.2 소스 배포

```bash
# Git clone
git clone git@github.com:your-org/kingdom.git /tmp/kingdom-src
cd /tmp/kingdom-src

# 또는 이미 clone된 프로젝트에서
cd /path/to/lil-eddy

# 실행 파일 + 설정 복사
DEST="${KINGDOM_BASE_DIR:-/opt/kingdom}"
sudo mkdir -p "$DEST"
sudo chown $USER "$DEST"

cp -r bin "$DEST/"
cp -r config "$DEST/"
chmod +x "$DEST"/bin/*.sh
```

### 4.3 디렉토리 초기화

```bash
"$DEST/bin/init-dirs.sh"
```

### 4.3.1 빌트인 장군 설치

소스의 `generals/` 디렉토리에 있는 패키지를 런타임에 설치:

```bash
for pkg in generals/gen-*; do
  "$DEST/bin/install-general.sh" "$pkg"
done
```

각 장군 패키지는 `manifest.yaml` + `prompt.md`로 구성되며, `install-general.sh`가 매니페스트, 프롬프트 템플릿, 엔트리 스크립트를 자동 생성한다.

외부 장군 패키지 설치도 동일:

```bash
# GitHub에서 장군 패키지 다운로드
git clone https://github.com/someone/gen-docs.git
cd gen-docs && ./install.sh
# 또는 직접 호출
$DEST/bin/install-general.sh /path/to/gen-docs
```

생성되는 구조:
```
/opt/kingdom/
├── bin/                  # 실행 파일
├── config/               # YAML 설정 + 프롬프트 템플릿
├── queue/
│   ├── events/{pending,dispatched,completed}/
│   ├── tasks/{pending,in_progress,completed}/
│   └── messages/{pending,sent}/
├── state/
│   ├── king/             # task-seq, msg-seq, schedule-sent.json
│   ├── sentinel/seen/    # 이벤트 중복 방지
│   ├── envoy/            # thread-mappings.json, awaiting-responses.json
│   ├── chamberlain/      # events-offset, stats.json
│   ├── results/          # 병사 실행 결과
│   ├── prompts/          # 프롬프트 파일
│   ├── sessions.json     # 활성 병사 목록
│   └── resources.json    # 시스템 헬스
├── memory/               # 장군별 학습 메모리
│   ├── shared/
│   └── generals/{gen-pr,gen-briefing}/
├── logs/                 # system.log, events.log
│   └── sessions/         # 병사별 로그
└── workspace/            # 장군별 작업 디렉토리
```

### 4.4 CC 플러그인 (선택)

장군이 `claude -p` 실행 시 사용하는 플러그인. 없어도 동작하지만 리뷰 품질이 달라짐.
플러그인은 **전역 설치** (`~/.claude/settings.json`의 `enabledPlugins`)가 필요하다.

각 장군 패키지의 `install.sh`가 CC Plugin 마켓플레이스 등록 + 설치를 자동 수행하므로, 별도 설치가 불필요할 수 있다. 수동으로 설치하려면:

```bash
# 마켓플레이스 등록
claude plugin marketplace add eddy-jeon/qp-plugin

# 플러그인 설치
claude plugin install friday@qp-plugin

# 설치 확인 (객체 형식)
cat ~/.claude/settings.json | jq '.enabledPlugins'
# → { "friday@qp-plugin": true }
```

> 장군 매니페스트의 `cc_plugins`에 선언된 플러그인이 전역 설정에 없으면 `ensure_workspace`가 실패한다. `enabledPlugins`는 `{"name@marketplace": true}` 형식의 객체이다.

### 4.5 환경변수 영구화

#### Linux (EC2)

```bash
# shell rc에 추가 (수동 실행 + tmux 세션에서 사용)
cat >> ~/.bashrc << 'EOF'
export JIRA_API_TOKEN="..."
export JIRA_URL="https://your-domain.atlassian.net"
export SLACK_BOT_TOKEN="xoxb-..."
EOF

# systemd용 .env 파일도 생성 (systemd 서비스에서 사용)
cat > /opt/kingdom/.env << 'EOF'
JIRA_API_TOKEN=...
JIRA_URL=https://your-domain.atlassian.net
SLACK_BOT_TOKEN=xoxb-...

# ⚠️ systemd는 셸 환경(~/.bashrc, mise activate)을 로드하지 않으므로
# mise로 설치한 도구(yq, jq, gh, claude, node 등)를 찾으려면 shims 경로 필수
# 홈 디렉토리 경로를 실제 사용자에 맞게 변경할 것
PATH=/home/ec2-user/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin
EOF
chmod 600 /opt/kingdom/.env
```

> `~/.bashrc`: 수동 `start.sh` 실행 및 tmux 세션에서 참조.
> `.env`: systemd의 `EnvironmentFile`이 로드 (6절 참고). `PATH`에 mise shims 경로를 포함해야 yq, claude 등을 찾을 수 있다.
> GitHub 인증은 `gh auth login`으로 keyring에 저장되므로 환경변수 불필요.

#### macOS

```bash
cat >> ~/.zshrc << 'EOF'
export KINGDOM_BASE_DIR=/opt/kingdom  # 기본값이면 생략 가능
export JIRA_API_TOKEN="..."
export JIRA_URL="https://your-domain.atlassian.net"
export SLACK_BOT_TOKEN="xoxb-..."
EOF
```

### 4.6 환경 검증

```bash
"$DEST/bin/check-prerequisites.sh"
```

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
  [OK] Jira         authenticated (Eddy)
  [OK] Slack        authenticated (kingdom-bot)
═══════════════════════════════════
  Result: 10/10 passed
```

---

## 5. 설정 튜닝

### 5.1 감시 대상 (Sentinel)

```yaml
# config/sentinel.yaml
scope:
  repos:
    - "chequer/qp"        # 감시할 GitHub 레포
    - "chequer/qp-fe"
  reasons:
    - "review_requested"   # PR 리뷰 요청
    - "assign"             # PR/Issue assign
```

### 5.2 Timezone (Linux)

Kingdom의 cron 스케줄(장군의 `schedules.cron`)은 **서버 시간** 기준으로 동작한다. 한국 시간에 맞추려면:

```bash
# 현재 timezone 확인
timedatectl

# 한국 시간으로 변경
sudo timedatectl set-timezone Asia/Seoul
```

> `setup.sh` Step 4에서 자동으로 안내한다.

### 5.3 폴링 간격

```yaml
# config/sentinel.yaml
intervals:
  github_seconds: 60       # GitHub 알림 체크 주기
  jira_seconds: 120        # Jira JQL 체크 주기

# config/king.yaml
intervals:
  event_check_seconds: 10  # 이벤트 처리 주기
  result_check_seconds: 10 # 결과 확인 주기
  schedule_check_seconds: 60
```

### 5.4 동시 실행 제한

```yaml
# config/king.yaml
concurrency:
  max_soldiers: 3          # EC2 M5.xlarge 기준
                           # macOS 로컬이면 1~2로 줄이는 것을 권장
```

### 5.5 리소스 임계값 (Chamberlain)

```yaml
# config/chamberlain.yaml
thresholds:
  cpu_red: 90
  cpu_orange: 80
  cpu_yellow: 70
  memory_red: 90
  memory_orange: 80
  memory_yellow: 70
  disk_warning: 85
```

---

## 6. 실행

### 6.1 수동 실행

```bash
# 전체 시작 (tmux 세션 생성)
/opt/kingdom/bin/start.sh

# 상태 확인
/opt/kingdom/bin/status.sh

# 전체 종료
/opt/kingdom/bin/stop.sh
```

시작 순서: chamberlain → sentinel → envoy → king → gen-pr → gen-briefing
종료 순서: 역순 (장군 → king → envoy → sentinel → chamberlain)

### 6.2 systemd 서비스 (Linux 전용)

EC2 재부팅 시 자동 시작, 크래시 시 자동 재시작.

```bash
# 서비스 파일 생성
# ⚠️ User= 과 PATH의 홈 디렉토리를 실제 사용자에 맞게 변경할 것
sudo tee /etc/systemd/system/kingdom.service << 'EOF'
[Unit]
Description=Kingdom — Autonomous Dev Agent System
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/kingdom
ExecStart=/opt/kingdom/bin/start.sh
ExecStop=/opt/kingdom/bin/stop.sh
Restart=always
RestartSec=10
EnvironmentFile=/opt/kingdom/.env

[Install]
WantedBy=multi-user.target
EOF

# 등록 + 시작
sudo systemctl daemon-reload
sudo systemctl enable kingdom
sudo systemctl start kingdom

# 상태 확인
sudo systemctl status kingdom
sudo journalctl -u kingdom -f
```

### 6.3 launchd (macOS, 선택)

macOS에서 상시 운영할 경우:

```bash
cat > ~/Library/LaunchAgents/com.kingdom.agent.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.kingdom.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/kingdom/bin/start.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>KINGDOM_BASE_DIR</key>
    <string>/opt/kingdom</string>
  </dict>
  <key>StandardOutPath</key>
  <string>/opt/kingdom/logs/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/opt/kingdom/logs/launchd-stderr.log</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.kingdom.agent.plist
```

---

## 7. 운영

### 7.1 로그 확인

```bash
# 전체 로그 (실시간)
tail -f /opt/kingdom/logs/system.log

# 역할별 필터
tail -f /opt/kingdom/logs/system.log | grep '\[sentinel\]'
tail -f /opt/kingdom/logs/system.log | grep '\[king\]'
tail -f /opt/kingdom/logs/system.log | grep '\[gen-pr\]'
tail -f /opt/kingdom/logs/system.log | grep '\[chamberlain\]'

# 내부 이벤트 (JSONL)
tail -f /opt/kingdom/logs/events.log | jq .

# 병사 실행 로그
ls /opt/kingdom/logs/sessions/
cat /opt/kingdom/logs/sessions/soldier-*.log
```

### 7.2 tmux 세션 접근

```bash
tmux ls                    # 세션 목록
tmux attach -t king        # 왕 세션 접속
tmux attach -t sentinel    # 파수꾼 세션 접속
tmux attach -t gen-pr      # 장군 세션 접속
# Ctrl+B, D 로 detach (세션은 계속 실행)
```

### 7.3 헬스 체크

```bash
# 시스템 상태
/opt/kingdom/bin/status.sh

# 리소스 상세
cat /opt/kingdom/state/resources.json | jq .

# heartbeat 확인
ls -la /opt/kingdom/state/*/heartbeat

# 활성 병사
cat /opt/kingdom/state/sessions.json | jq .

# 큐 상태
echo "Events pending: $(ls /opt/kingdom/queue/events/pending/ 2>/dev/null | wc -l)"
echo "Tasks pending:  $(ls /opt/kingdom/queue/tasks/pending/ 2>/dev/null | wc -l)"
echo "Tasks running:  $(ls /opt/kingdom/queue/tasks/in_progress/ 2>/dev/null | wc -l)"
echo "Messages out:   $(ls /opt/kingdom/queue/messages/pending/ 2>/dev/null | wc -l)"
```

### 7.4 수동 이벤트 주입 (테스트)

Sentinel을 거치지 않고 직접 이벤트를 주입해서 파이프라인 검증:

```bash
# GitHub PR 리뷰 이벤트 시뮬레이션
jq -n '{
  id: "evt-manual-test-001",
  type: "github.pr.review_requested",
  source: "github",
  priority: "normal",
  repo: "chequer/qp",
  payload: {pr_number: 42, title: "Test event"}
}' > /opt/kingdom/queue/events/pending/evt-manual-test-001.json

# King이 처리하는 것을 로그로 확인
tail -f /opt/kingdom/logs/system.log | grep -E '\[king\]|\[gen-pr\]'
```

기대 흐름:
```
[king]    Dispatched: evt-manual-test-001 -> gen-pr (task: task-YYYYMMDD-001)
[gen-pr]  Task claimed: task-YYYYMMDD-001
[gen-pr]  Soldier spawned: soldier-...
[gen-pr]  Reported to king: task-YYYYMMDD-001 (success|failed)
[king]    Task completed: task-YYYYMMDD-001
```

---

## 8. 업데이트

코드 변경 시 반영 절차:

```bash
# 1. 종료
/opt/kingdom/bin/stop.sh

# 2. 소스 업데이트
cd /tmp/kingdom-src && git pull

# 3. 실행 파일 + 설정 덮어쓰기
cp -r bin /opt/kingdom/
cp -r config /opt/kingdom/
chmod +x /opt/kingdom/bin/*.sh

# 4. 장군 재설치
for pkg in generals/gen-*; do
  /opt/kingdom/bin/install-general.sh "$pkg" --force
done

# 5. 재시작
/opt/kingdom/bin/start.sh
```

> `queue/`, `state/`, `memory/`, `logs/`는 런타임 데이터이므로 덮어쓰지 않는다.

---

## 9. 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| `[DOWN] sentinel` | tmux 세션 크래시 | start.sh 재실행 (watchdog이 자동 복구) |
| King이 이벤트 무시 | health가 yellow/red | `cat state/resources.json \| jq .health` 확인 |
| 병사가 안 생김 | max_soldiers 초과 | `cat state/sessions.json \| jq length` 확인 |
| 병사 즉시 실패 | claude 인증 만료 | `claude login` 재인증 |
| Sentinel 알림 없음 | GitHub 알림이 없음 | `gh api /notifications --jq 'length'` 확인 |
| yq 파싱 오류 | Python yq 설치됨 | `yq --version`으로 mikefarah 버전 확인 |
| systemd 실패 (217/USER) | User= 계정이 시스템에 없음 | `id <username>`으로 확인, service 파일의 User= 수정 |
| systemd에서 yq/claude 못 찾음 | mise shims PATH 누락 | `.env`에 `PATH=~/.local/share/mise/shims:...` 추가 (4.5절 참고) |
| Slack 메시지 안 감 | Bot이 채널에 미초대 | Slack에서 `/invite @kingdom-bot` |

### 긴급 복구

```bash
# 모든 tmux 세션 강제 종료
tmux kill-server

# 상태 초기화 (큐 데이터 보존)
echo '[]' > /opt/kingdom/state/sessions.json
echo '{"health":"green"}' > /opt/kingdom/state/resources.json

# 재시작
/opt/kingdom/bin/start.sh
```

---

## 10. 보안

| 항목 | 조치 |
|------|------|
| `.env` 파일 | `chmod 600`, git에 커밋 금지 |
| SSH | Key-pair 인증만, 비밀번호 비활성화 |
| 네트워크 | Security Group: 인바운드 SSH(22)만, 아웃바운드 전체 허용 |
| IAM | 최소 권한 원칙, EC2 전용 IAM Role |
| 병사 실행 | `--dangerously-skip-permissions`로 실행 — 신뢰된 프롬프트만 사용 |
| 로그 | API 토큰이 로그에 노출되지 않도록 주의 |

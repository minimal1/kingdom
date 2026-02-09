# EC2 인스턴스 설정

> Kingdom가 살 집을 짓는다.

## 권장 사양

| 항목 | 스펙 | 근거 |
|------|------|------|
| Instance Type | **M5.xlarge** | 4 vCPU, 16GB RAM — 동시 3-5 CC 세션 |
| Storage | 100GB GP3 SSD | 코드베이스 + 로그 + 메모리 |
| OS | Amazon Linux 2023 또는 Ubuntu 22.04 | Claude Code 공식 지원 |
| Network | 기본 VPC | Outbound만 필요 (API 호출) |
| Region | ap-northeast-2 (서울) | 지연시간 최소화 |

## 예상 비용

| 항목 | 월 비용 |
|------|---------|
| EC2 M5.xlarge (On-Demand, 24/7) | ~$175 |
| EBS 100GB GP3 | ~$8 |
| Claude API | Plan 요금 (Max Plan 권장) |
| **합계 (인프라)** | **~$183/월** |

## 필수 소프트웨어

```bash
# 1. 시스템 업데이트
sudo yum update -y  # Amazon Linux
# sudo apt update && sudo apt upgrade -y  # Ubuntu

# 2. Claude Code (native installer)
curl -fsSL https://claude.ai/install.sh | sh

# 3. tmux
sudo yum install -y tmux  # Amazon Linux
# sudo apt install -y tmux  # Ubuntu

# 4. Git + GitHub CLI
sudo yum install -y git
# gh CLI
(type -p wget >/dev/null || sudo yum install -y wget) \
  && wget -qO- https://cli.github.com/packages/rpm/gh-cli.repo \
  | sudo tee /etc/yum.repos.d/github-cli.repo \
  && sudo yum install -y gh

# 5. Node.js 22+ (빌드/테스트용)
curl -fsSL https://fnm.vercel.app/install | bash
fnm install 22

# 6. jq (JSON 처리)
sudo yum install -y jq

# 7. yq (YAML 처리 — mikefarah/yq Go 바이너리)
# king/chamberlain이 `yq eval` 구문을 사용하므로 mikefarah 버전 필수
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# 8. bc (chamberlain의 evaluate_health에서 부동소수점 비교에 사용)
sudo yum install -y bc
```

## 인증 설정

```bash
# Claude Code — headless 인증
export CLAUDE_CODE_API_KEY="sk-ant-..."

# GitHub — gh CLI 표준 환경변수
export GH_TOKEN="ghp_..."
echo "$GH_TOKEN" | gh auth login --with-token

# Jira — curl + Basic Auth (REST API)
# jira-cli는 사용하지 않음. 파수꾼이 curl로 직접 Jira REST API 호출.
# Base64 인코딩: echo -n "eddy@chequer.io:$JIRA_API_TOKEN" | base64
export JIRA_API_TOKEN="..."
export JIRA_URL="https://chequer.atlassian.net"

# Slack — Slack Web API (curl)
# 사절이 curl로 Slack Web API를 호출. Bot User OAuth Token 필요.
# 발급: https://api.slack.com/apps → OAuth & Permissions → Install to Workspace
export SLACK_BOT_TOKEN="xoxb-..."

# 환경변수 영구화
cat >> ~/.bashrc << 'EOF'
export CLAUDE_CODE_API_KEY="..."
export GH_TOKEN="..."
export JIRA_API_TOKEN="..."
export JIRA_URL="https://chequer.atlassian.net"
export SLACK_BOT_TOKEN="xoxb-..."
EOF
```

## 보안 고려사항

| 항목 | 조치 |
|------|------|
| API 키 보관 | AWS Secrets Manager 또는 환경변수 |
| SSH 접근 | Key-pair 인증만, 비밀번호 비활성화 |
| 네트워크 | Security Group: 인바운드 SSH(22)만, 아웃바운드 전체 허용 |
| IAM | 최소 권한 원칙, EC2 전용 IAM Role |

## 초기화 스크립트

```bash
# EC2 인스턴스 최초 설정 후 실행
#!/bin/bash
set -e

BASE_DIR="/opt/kingdom"

# 디렉토리 구조 생성
mkdir -p $BASE_DIR/{bin,config,queue,state,memory,logs,workspace,plugins}
mkdir -p $BASE_DIR/bin/{generals,lib/{sentinel,king,general,soldier,envoy,chamberlain}}
mkdir -p $BASE_DIR/queue/{events,tasks,messages}/{pending,completed}
mkdir -p $BASE_DIR/queue/events/dispatched
mkdir -p $BASE_DIR/queue/tasks/in_progress
mkdir -p $BASE_DIR/queue/messages/sent
mkdir -p $BASE_DIR/state/{results,sentinel,king}
mkdir -p $BASE_DIR/state/sentinel/seen            # 중복 방지 인덱스
mkdir -p $BASE_DIR/state/envoy                     # 사절 상태 (thread-mappings, awaiting)
mkdir -p $BASE_DIR/state/prompts                   # 임시 프롬프트
mkdir -p $BASE_DIR/state/chamberlain               # 내관 상태
mkdir -p $BASE_DIR/config/generals/templates       # 프롬프트 템플릿
mkdir -p $BASE_DIR/memory/{shared,generals/{pr-review,test-code,jira-ticket}}
mkdir -p $BASE_DIR/logs/{sessions,analysis}

# 초기 상태 파일 생성
echo '{}' > $BASE_DIR/state/resources.json
touch $BASE_DIR/state/sessions.json                # JSONL (빈 파일)
echo '{}' > $BASE_DIR/state/envoy/thread-mappings.json
echo '[]' > $BASE_DIR/state/envoy/awaiting-responses.json
echo '{}' > $BASE_DIR/state/envoy/report-sent.json
echo '{}' > $BASE_DIR/state/king/schedule-sent.json
echo "0" > $BASE_DIR/state/chamberlain/events-offset

echo "Kingdom directory structure created at $BASE_DIR"
```

## systemd 서비스 설정

`start.sh`를 OS 레벨로 보호하여, EC2 재부팅 시 자동으로 시스템을 시작한다.

```ini
# /etc/systemd/system/kingdom.service
[Unit]
Description=Kingdom - Autonomous Dev Agent
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/kingdom
ExecStart=/opt/kingdom/bin/start.sh
ExecStop=/opt/kingdom/bin/stop.sh
Restart=always
RestartSec=10
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=/opt/kingdom/.env

[Install]
WantedBy=multi-user.target
```

```bash
# systemd 등록
sudo cp kingdom.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kingdom
sudo systemctl start kingdom

# 상태 확인
sudo systemctl status kingdom
```

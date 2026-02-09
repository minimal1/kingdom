# EC2 인스턴스 설정

> Lil Eddy가 살 집을 짓는다.

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

# 5. Jira CLI
# https://github.com/ankitpokhrel/jira-cli
go install github.com/ankitpokhrel/jira-cli/cmd/jira@latest
# 또는 brew install jira-cli

# 6. Node.js 22+ (빌드/테스트용)
curl -fsSL https://fnm.vercel.app/install | bash
fnm install 22

# 7. jq (JSON 처리)
sudo yum install -y jq

# 8. yq (YAML 처리)
pip install yq
```

## 인증 설정

```bash
# Claude Code — headless 인증
export CLAUDE_CODE_API_KEY="sk-ant-..."

# GitHub — Personal Access Token
echo "$GITHUB_TOKEN" | gh auth login --with-token

# Jira — CLI 로그인
jira init  # 또는 환경변수 설정

# Slack — Claude Code Slack MCP plugin 설정
# → .mcp.json에서 설정

# 환경변수 영구화
cat >> ~/.bashrc << 'EOF'
export CLAUDE_CODE_API_KEY="..."
export GITHUB_TOKEN="..."
export JIRA_API_TOKEN="..."
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

BASE_DIR="/opt/lil-eddy"

# 디렉토리 구조 생성
mkdir -p $BASE_DIR/{bin,config,queue,state,memory,logs,workspace,plugins}
mkdir -p $BASE_DIR/bin/{generals,lib/{sentinel,king,general,soldier,envoy,chamberlain}}
mkdir -p $BASE_DIR/queue/{events,tasks,messages}/{pending,completed}
mkdir -p $BASE_DIR/queue/events/dispatched
mkdir -p $BASE_DIR/queue/tasks/in_progress
mkdir -p $BASE_DIR/queue/messages/sent
mkdir -p $BASE_DIR/state/{results,sentinel,king}
mkdir -p $BASE_DIR/memory/{shared,generals/{pr-review,test-code,jira-ticket}}
mkdir -p $BASE_DIR/logs/{sessions,analysis}
mkdir -p $BASE_DIR/state/chamberlain

echo "Lil Eddy directory structure created at $BASE_DIR"
```

#!/usr/bin/env bash
# Kingdom Setup Wizard
# 대화형으로 Kingdom 전체 설치를 안내한다.
# Usage: bin/setup.sh

set -euo pipefail

# ─── 색상 / 유틸 ───────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

step()  { printf "\n${BOLD}Step %s/7 ─ %s${RESET}\n" "$1" "$2"; }
ok()    { printf "  ${GREEN}[OK]${RESET}   %s\n" "$1"; }
warn()  { printf "  ${YELLOW}[SKIP]${RESET} %s\n" "$1"; }
fail()  { printf "  ${RED}[FAIL]${RESET} %s\n" "$1"; }
info()  { printf "  ${DIM}%s${RESET}\n" "$1"; }

ask() {
  local prompt="$1"
  local default="$2"
  local ans
  printf "  %s [%s]: " "$prompt" "$default" >&2
  read -r ans
  echo "${ans:-$default}"
}

ask_yn() {
  local prompt="$1"
  local default="${2:-Y}"
  local ans
  printf "  %s [%s]: " "$prompt" "$default" >&2
  read -r ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

ask_secret() {
  local prompt="$1"
  local ans
  printf "  %s: " "$prompt" >&2
  read -rs ans
  echo "" >&2
  echo "$ans"
}

update_env() {
  local key="$1" value="$2"
  touch "$ENV_FILE"
  grep -v "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  echo "${key}=${value}" >> "$ENV_FILE"
}

# 소스 레포 루트 (이 스크립트가 있는 bin/ 의 상위)
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 설치 결과 추적
STEP_RESULTS=()
record() { STEP_RESULTS+=("$1"); }

# ─── 배너 ──────────────────────────────────────────────────

printf "\n${BOLD}${CYAN}"
cat << 'BANNER'
  +-----------------------------------------+
  |  Kingdom Setup Wizard                   |
  |  "빈 컴퓨터에 AI 동료를 정착시킵니다"   |
  +-----------------------------------------+
BANNER
printf "${RESET}\n"
info "소스 디렉토리: $SOURCE_DIR"
echo ""

# ─── Step 1: 설치 경로 ────────────────────────────────────

step 1 "설치 경로"

DEST=$(ask "설치 경로를 입력하세요" "/opt/kingdom")

# 기존 설치 감지
if [[ -f "$DEST/bin/king.sh" ]]; then
  info "기존 설치가 감지되었습니다. 설정을 업데이트합니다."
fi

# 디렉토리 생성
if [[ ! -d "$DEST" ]]; then
  if mkdir -p "$DEST" 2>/dev/null; then
    ok "디렉토리 생성: $DEST"
  else
    fail "디렉토리 생성 실패: $DEST (권한 확인)"
    info "sudo mkdir -p $DEST && sudo chown \$(whoami) $DEST"
    printf "\n  권한 설정 후 Enter를 누르세요..."
    read -r
    if [[ ! -d "$DEST" ]]; then
      fail "디렉토리가 여전히 없습니다. 종료합니다."
      exit 1
    fi
  fi
fi

# 소스 파일 복사
cp -r "$SOURCE_DIR/bin" "$DEST/"
cp -r "$SOURCE_DIR/config" "$DEST/"
cp -r "$SOURCE_DIR/schemas" "$DEST/"
chmod +x "$DEST"/bin/*.sh 2>/dev/null || true
chmod +x "$DEST"/bin/generals/*.sh 2>/dev/null || true

# system.yaml의 base_dir 업데이트
if command -v yq &>/dev/null; then
  yq eval -i ".base_dir = \"$DEST\"" "$DEST/config/system.yaml"
fi

ok "소스 파일 복사 완료 → $DEST"
record "설치 경로: $DEST"

export KINGDOM_BASE_DIR="$DEST"

# .env에 KINGDOM_BASE_DIR 기록 (다른 스크립트에서 참조)
ENV_FILE="$DEST/.env"
touch "$ENV_FILE"
grep -v '^KINGDOM_BASE_DIR=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo "KINGDOM_BASE_DIR=$DEST" >> "$ENV_FILE"
ok ".env KINGDOM_BASE_DIR: $DEST"

# mise shims PATH 자동 감지 (systemd용)
MISE_SHIMS="$HOME/.local/share/mise/shims"
if [[ -d "$MISE_SHIMS" ]]; then
  update_env "PATH" "$MISE_SHIMS:/usr/local/bin:/usr/bin:/bin"
  ok ".env PATH: mise shims 포함"
fi

# ─── Step 2: 의존성 확인 ──────────────────────────────────

step 2 "의존성 확인"

MISSING_TOOLS=()

check_tool() {
  local name="$1"
  local install_hint="${2:-}"

  if command -v "$name" &>/dev/null; then
    local ver
    case "$name" in
      tmux)  ver=$(tmux -V 2>/dev/null | head -1) ;;
      gh)    ver=$(gh --version 2>/dev/null | head -1) ;;
      node)  ver=$(node --version 2>/dev/null) ;;
      *)     ver=$("$name" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || ver="" ;;
    esac
    ok "$name ${ver:+($ver)}"
  else
    fail "$name 미설치"
    if [[ -n "$install_hint" ]]; then
      info "$install_hint"
    fi
    MISSING_TOOLS+=("$name")
  fi
}

# OS 감지
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  PKG="brew install"
else
  PKG="sudo apt install -y"
fi

check_tool "jq"     "$PKG jq"
check_tool "yq"     "$PKG yq  (또는: go install github.com/mikefarah/yq/v4@latest)"
check_tool "gh"     "$PKG gh"
check_tool "tmux"   "$PKG tmux"
check_tool "bc"     "$PKG bc"
check_tool "node"   "https://nodejs.org/ 또는 $PKG node"

# claude: 특수 체크
if command -v claude &>/dev/null; then
  ok "claude (installed)"
else
  fail "claude 미설치"
  info "https://docs.anthropic.com/en/docs/claude-code/overview"
  MISSING_TOOLS+=("claude")
fi

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  echo ""
  printf "  ${YELLOW}미설치 도구가 있습니다: %s${RESET}\n" "${MISSING_TOOLS[*]}"
  if ask_yn "설치 후 재확인하시겠습니까?" "Y"; then
    # 재확인 루프 (1회)
    printf "\n  도구 설치 후 Enter를 누르세요..."
    read -r
    STILL_MISSING=()
    for tool in "${MISSING_TOOLS[@]}"; do
      if ! command -v "$tool" &>/dev/null; then
        STILL_MISSING+=("$tool")
      else
        ok "$tool (설치 확인)"
      fi
    done
    if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
      warn "아직 미설치: ${STILL_MISSING[*]} — 나중에 설치하세요"
      record "의존성: 일부 미설치 (${STILL_MISSING[*]})"
    else
      ok "모든 의존성 확인 완료"
      record "의존성: 전체 OK"
    fi
  else
    warn "의존성 확인 건너뜀"
    record "의존성: 일부 미설치 (${MISSING_TOOLS[*]})"
  fi
else
  ok "모든 의존성 확인 완료"
  record "의존성: 전체 OK"
fi

# ─── Step 3: 인증 설정 ────────────────────────────────────

step 3 "인증 설정"

ENV_FILE="$DEST/.env"
# 기존 .env 로드 (있으면)
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  info "기존 .env 파일 로드됨"
fi

# Claude Code
if command -v claude &>/dev/null; then
  if claude -p "echo ok" &>/dev/null 2>&1; then
    ok "Claude Code 인증 OK"
  else
    fail "Claude Code 인증 실패"
    info "실행: claude login"
  fi
else
  warn "Claude Code CLI 없음 — 건너뜀"
fi

# GitHub
if [[ -n "${GH_TOKEN:-}" ]] || gh auth status &>/dev/null 2>&1; then
  gh_user=$(gh api /user --jq '.login' 2>/dev/null) || gh_user="unknown"
  ok "GitHub 인증 OK ($gh_user)"
else
  fail "GitHub 인증 실패"
  info "실행: gh auth login  또는  export GH_TOKEN=..."
fi

# Jira (선택)
echo ""
if ask_yn "Jira 연동을 설정하시겠습니까?" "Y"; then
  JIRA_URL_INPUT=$(ask "Jira URL" "${JIRA_URL:-https://your-domain.atlassian.net}")
  JIRA_EMAIL_INPUT=$(ask "Jira 이메일" "${JIRA_USER_EMAIL:-}")
  JIRA_TOKEN_INPUT=$(ask_secret "Jira API 토큰 (입력이 표시되지 않습니다)")

  if [[ -n "$JIRA_TOKEN_INPUT" ]]; then
    # .env 파일에 저장 (기존 값 교체 또는 추가)
    touch "$ENV_FILE"
    # 기존 JIRA 관련 줄 제거 후 재작성
    if [[ -f "$ENV_FILE" ]]; then
      grep -v '^JIRA_' "$ENV_FILE" > "$ENV_FILE.tmp" || true
      mv "$ENV_FILE.tmp" "$ENV_FILE"
    fi
    {
      echo "JIRA_URL=$JIRA_URL_INPUT"
      echo "JIRA_USER_EMAIL=$JIRA_EMAIL_INPUT"
      echo "JIRA_API_TOKEN=$JIRA_TOKEN_INPUT"
    } >> "$ENV_FILE"
    ok "Jira 설정 저장 → .env"
  else
    warn "Jira 토큰 미입력 — 건너뜀"
  fi
else
  warn "Jira 연동 건너뜀 (나중에 $DEST/.env에 설정 가능)"
fi

# Slack (선택)
echo ""
if ask_yn "Slack 연동을 설정하시겠습니까?" "Y"; then
  SLACK_TOKEN_INPUT=$(ask_secret "Slack Bot 토큰 (xoxb-..., 입력이 표시되지 않습니다)")

  if [[ -n "$SLACK_TOKEN_INPUT" ]]; then
    touch "$ENV_FILE"
    if [[ -f "$ENV_FILE" ]]; then
      grep -v '^SLACK_BOT_TOKEN=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
      mv "$ENV_FILE.tmp" "$ENV_FILE"
    fi
    echo "SLACK_BOT_TOKEN=$SLACK_TOKEN_INPUT" >> "$ENV_FILE"
    ok "Slack 설정 저장 → .env"
  else
    warn "Slack 토큰 미입력 — 건너뜀"
  fi
else
  warn "Slack 연동 건너뜀 (나중에 $DEST/.env에 설정 가능)"
fi

record "인증: 설정 완료"

# ─── Step 4: 기본 설정 ────────────────────────────────────

step 4 "기본 설정"

# Timezone (Linux only)
if [[ "$OS" != "Darwin" ]]; then
  echo ""
  CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
  info "현재 timezone: $CURRENT_TZ"
  info "Kingdom의 cron 스케줄은 서버 시간 기준으로 동작합니다."
  TZ_INPUT=$(ask "Timezone" "Asia/Seoul")
  if [[ "$TZ_INPUT" != "$CURRENT_TZ" ]]; then
    if sudo timedatectl set-timezone "$TZ_INPUT" 2>/dev/null; then
      ok "Timezone 설정: $TZ_INPUT"
    else
      fail "Timezone 설정 실패 (sudo 권한 확인)"
      info "수동 설정: sudo timedatectl set-timezone $TZ_INPUT"
    fi
  else
    ok "Timezone 유지: $CURRENT_TZ"
  fi
fi

# GitHub 감시 레포
echo ""
info "감시할 GitHub 레포를 입력하세요 (쉼표 구분)"
info "예: owner/repo1, owner/repo2"
REPOS_INPUT=$(ask "GitHub 레포" "")

if [[ -n "$REPOS_INPUT" ]]; then
  # 쉼표 분리 → yaml 배열로 변환
  IFS=',' read -ra REPO_ARRAY <<< "$REPOS_INPUT"

  # yq로 repos 배열 초기화 후 하나씩 추가
  yq eval -i '.polling.github.scope.repos = []' "$DEST/config/sentinel.yaml"
  for repo in "${REPO_ARRAY[@]}"; do
    repo=$(echo "$repo" | xargs)  # trim whitespace
    if [[ -n "$repo" ]]; then
      yq eval -i ".polling.github.scope.repos += [\"$repo\"]" "$DEST/config/sentinel.yaml"
    fi
  done
  ok "sentinel.yaml repos 업데이트: ${REPO_ARRAY[*]}"
else
  warn "레포 미입력 — 기존 설정 유지"
fi

# Slack 채널 (.env에 기록 — king/envoy가 공통으로 사용)
CHANNEL=$(ask "Slack 채널 (채널명 또는 User ID로 DM)" "kingdom")
update_env "SLACK_DEFAULT_CHANNEL" "$CHANNEL"
ok ".env SLACK_DEFAULT_CHANNEL: $CHANNEL"

# 동시 병사 수
MAX_SOLDIERS=$(ask "동시 병사 수" "3")
yq eval -i ".concurrency.max_soldiers = $MAX_SOLDIERS" "$DEST/config/king.yaml"
ok "king.yaml max_soldiers: $MAX_SOLDIERS"

record "기본 설정: 완료"

# ─── Step 5: 디렉토리 초기화 ──────────────────────────────

step 5 "디렉토리 초기화"

if bash "$DEST/bin/init-dirs.sh"; then
  ok "런타임 디렉토리 초기화 완료"
else
  fail "init-dirs.sh 실행 실패"
fi

record "디렉토리: 초기화됨"

# ─── Step 6: 장군 설치 ────────────────────────────────────

step 6 "장군 설치"

GENERALS_INSTALLED=0
GENERALS_FAILED=0

for pkg_dir in "$SOURCE_DIR"/generals/gen-*; do
  [[ -d "$pkg_dir" ]] || continue
  gen_name=$(basename "$pkg_dir")

  # install.sh가 있으면 실행 (CC plugin 설치 포함)
  if [[ -f "$pkg_dir/install.sh" ]]; then
    if bash "$pkg_dir/install.sh" --force 2>/dev/null; then
      ok "$gen_name 설치 완료"
      GENERALS_INSTALLED=$((GENERALS_INSTALLED + 1))
    else
      # install.sh 실패 시 install-general.sh 직접 시도
      if bash "$DEST/bin/install-general.sh" "$pkg_dir" --force 2>/dev/null; then
        ok "$gen_name 설치 완료 (install-general.sh fallback)"
        GENERALS_INSTALLED=$((GENERALS_INSTALLED + 1))
      else
        fail "$gen_name 설치 실패"
        GENERALS_FAILED=$((GENERALS_FAILED + 1))
      fi
    fi
  else
    # install.sh 없으면 install-general.sh 직접 호출
    if bash "$DEST/bin/install-general.sh" "$pkg_dir" --force 2>/dev/null; then
      ok "$gen_name 설치 완료"
      GENERALS_INSTALLED=$((GENERALS_INSTALLED + 1))
    else
      fail "$gen_name 설치 실패"
      GENERALS_FAILED=$((GENERALS_FAILED + 1))
    fi
  fi
done

if [[ $GENERALS_FAILED -eq 0 ]]; then
  record "장군: ${GENERALS_INSTALLED}개 설치"
else
  record "장군: ${GENERALS_INSTALLED}개 설치, ${GENERALS_FAILED}개 실패"
fi

# ─── Step 7: 검증 ─────────────────────────────────────────

step 7 "검증"

# .env 파일이 있으면 환경변수로 로드
if [[ -f "$DEST/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DEST/.env"
  set +a
fi

echo ""
if bash "$DEST/bin/check-prerequisites.sh" 2>/dev/null; then
  ok "검증 통과"
else
  warn "일부 항목 미통과 (위 결과 참조)"
fi

# ─── 요약 ─────────────────────────────────────────────────

echo ""
printf "${BOLD}${CYAN}=======================================${RESET}\n"
printf "${BOLD}  Setup 완료 요약${RESET}\n"
printf "${BOLD}${CYAN}=======================================${RESET}\n"
for result in "${STEP_RESULTS[@]}"; do
  printf "  %s\n" "$result"
done
printf "${CYAN}=======================================${RESET}\n"

echo ""
if ask_yn "start.sh로 Kingdom을 시작하시겠습니까?" "n"; then
  exec "$DEST/bin/start.sh"
else
  echo ""
  info "나중에 시작하려면:"
  info "  $DEST/bin/start.sh"
  echo ""
fi

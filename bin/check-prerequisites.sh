#!/usr/bin/env bash
# Kingdom Prerequisites Check
# 모든 CLI 도구와 외부 서비스 인증을 자동 검증한다.

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

check() {
  local label="$1"
  local result="$2"
  local detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "ok" ]]; then
    PASS=$((PASS + 1))
    printf "  [OK]   %-12s %s\n" "$label" "$detail"
  else
    FAIL=$((FAIL + 1))
    printf "  [FAIL] %-12s %s\n" "$label" "$detail"
  fi
}

# --- CLI Tools ---

check_tool() {
  local name="$1"
  local min_version="${2:-}"
  local version_cmd="${3:-$name --version}"

  if ! command -v "$name" &>/dev/null; then
    check "$name" "fail" "not found"
    return
  fi

  local ver
  ver=$(eval "$version_cmd" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || ver="unknown"

  if [[ -n "$min_version" && "$ver" != "unknown" ]]; then
    if ! printf '%s\n%s\n' "$min_version" "$ver" | sort -V | head -1 | grep -qx "$min_version"; then
      check "$name" "fail" "$ver (need >=$min_version)"
      return
    fi
  fi

  check "$name" "ok" "$ver"
}

echo ""
echo "Kingdom Prerequisites Check"
echo "======================================="

check_tool "jq" "1.6"
check_tool "yq" "4.0" "yq --version"
check_tool "gh" "" "gh --version"
check_tool "tmux" "" "tmux -V"
check_tool "bc"
check_tool "node" "22.0" "node --version"

# claude: 특수 체크 (--version 지원 안할 수 있음)
if command -v claude &>/dev/null; then
  check "claude" "ok" "installed"
else
  check "claude" "fail" "not found"
fi

echo "======================================="

# --- External Service Auth ---

# Claude Code (OAuth)
if command -v claude &>/dev/null; then
  if claude -p "echo hello" &>/dev/null; then
    check "Claude Code" "ok" "OAuth authenticated"
  else
    check "Claude Code" "fail" "not authenticated (run: claude login)"
  fi
else
  check "Claude Code" "fail" "CLI not installed"
fi

# GitHub
if [[ -n "${GH_TOKEN:-}" ]] || gh auth status &>/dev/null 2>&1; then
  gh_user=$(gh api /user --jq '.login' 2>/dev/null) || gh_user="unknown"
  check "GitHub" "ok" "authenticated ($gh_user)"
else
  check "GitHub" "fail" "not authenticated (set GH_TOKEN or run: gh auth login)"
fi

# Jira
if [[ -n "${JIRA_API_TOKEN:-}" && -n "${JIRA_URL:-}" ]]; then
  jira_name=$(curl -s -u "eddy@chequer.io:$JIRA_API_TOKEN" \
    "$JIRA_URL/rest/api/3/myself" 2>/dev/null | jq -r '.displayName // "unknown"') || jira_name="unknown"
  if [[ "$jira_name" != "null" && "$jira_name" != "unknown" ]]; then
    check "Jira" "ok" "authenticated ($jira_name)"
  else
    check "Jira" "fail" "authentication failed"
  fi
else
  check "Jira" "fail" "JIRA_API_TOKEN or JIRA_URL not set"
fi

# Slack
if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
  slack_ok=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    https://slack.com/api/auth.test 2>/dev/null | jq -r '.ok // "false"') || slack_ok="false"
  if [[ "$slack_ok" == "true" ]]; then
    slack_user=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      https://slack.com/api/auth.test 2>/dev/null | jq -r '.user // "unknown"')
    check "Slack" "ok" "authenticated ($slack_user)"
  else
    check "Slack" "fail" "authentication failed"
  fi
else
  check "Slack" "fail" "SLACK_BOT_TOKEN not set"
fi

echo "======================================="
echo "  Result: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo ""
  exit 0
else
  echo "  ($FAIL failed)"
  echo ""
  exit 1
fi

#!/usr/bin/env bash
# gen-pr 장군을 Kingdom에 설치
set -euo pipefail

KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 멀티 템플릿 복사 (install-general.sh 호출 전에 추가 템플릿 준비) ---
# install-general.sh가 기본 템플릿(prompt.md → gen-pr.md)을 복사하므로
# 여기서는 추가 템플릿만 처리

_post_install() {
  local template_dir="$KINGDOM_BASE_DIR/config/generals/templates"

  # action 템플릿: refresh_rules
  if [ -f "$PACKAGE_DIR/prompts/refresh-rules.md" ]; then
    cp "$PACKAGE_DIR/prompts/refresh-rules.md" "$template_dir/gen-pr-refresh_rules.md"
    echo "  Template:  config/generals/templates/gen-pr-refresh_rules.md"
  fi
  if [ -f "$PACKAGE_DIR/prompts/refresh-rules-codex.md" ]; then
    cp "$PACKAGE_DIR/prompts/refresh-rules-codex.md" "$template_dir/gen-pr-refresh_rules-codex.md"
    echo "  Template:  config/generals/templates/gen-pr-refresh_rules-codex.md"
  fi

  # 에이전트 복사 (런타임)
  if [ -d "$PACKAGE_DIR/agents" ]; then
    mkdir -p "$KINGDOM_BASE_DIR/config/generals/agents/gen-pr"
    cp -R "$PACKAGE_DIR/agents/." "$KINGDOM_BASE_DIR/config/generals/agents/gen-pr/" 2>/dev/null || true
    echo "  Agents:    config/generals/agents/gen-pr/"
  fi

  # memory 디렉토리 초기화
  mkdir -p "$KINGDOM_BASE_DIR/memory/generals/gen-pr"
}

# --- Kingdom에 장군 설치 ---
"$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"

# --- 후처리 ---
_post_install

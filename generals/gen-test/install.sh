#!/usr/bin/env bash
# gen-test 장군을 Kingdom에 설치
set -euo pipefail

KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CC Plugin 설치: saturday@qp-plugin ---
if command -v claude &>/dev/null; then
  SETTINGS="$HOME/.claude/settings.json"
  MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"

  # qp-plugin 마켓플레이스 등록
  if [ ! -f "$MARKETPLACES" ] || ! jq -e '.["qp-plugin"]' "$MARKETPLACES" &>/dev/null; then
    echo "Adding qp-plugin marketplace..."
    claude plugin marketplace add eddy-jeon/qp-plugin
  fi

  # saturday 플러그인 설치
  if [ ! -f "$SETTINGS" ] || ! jq -e '.enabledPlugins["saturday@qp-plugin"]' "$SETTINGS" &>/dev/null; then
    echo "Installing saturday plugin..."
    claude plugin install saturday@qp-plugin
  else
    echo "Plugin saturday@qp-plugin already installed."
  fi
else
  echo "WARN: claude CLI not found. Install CC plugins manually:"
  echo "  claude plugin marketplace add eddy-jeon/qp-plugin"
  echo "  claude plugin install saturday@qp-plugin"
fi

# --- Kingdom에 장군 설치 ---
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"

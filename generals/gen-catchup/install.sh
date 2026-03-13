#!/usr/bin/env bash
# gen-catchup 장군을 Kingdom에 설치
set -euo pipefail

KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"

if grep -R -n "TODO_" "$PACKAGE_DIR" >/dev/null 2>&1; then
  echo "gen-catchup package still contains TODO placeholders. Fill manifest/prompt values before installing." >&2
  exit 1
fi

# --- Kingdom에 장군 설치 ---
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"

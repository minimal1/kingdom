#!/usr/bin/env bash
# uninstall-general.sh -- 장군 정의 제거 (런타임 데이터 보존)
# Usage: uninstall-general.sh <general-name>
set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
NAME="${1:?Usage: uninstall-general.sh <general-name>}"

[ -f "$BASE_DIR/config/generals/${NAME}.yaml" ] || { echo "ERROR: '$NAME' not installed."; exit 1; }

rm -f "$BASE_DIR/config/generals/${NAME}.yaml"
rm -f "$BASE_DIR/config/generals/templates/${NAME}.md"
rm -f "$BASE_DIR/bin/generals/${NAME}.sh"

echo "Uninstalled: $NAME"
echo "Runtime data preserved (remove manually if desired):"
echo "  state/$NAME/"
echo "  memory/generals/$NAME/"
echo "  workspace/$NAME/"

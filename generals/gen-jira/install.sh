#!/usr/bin/env bash
# 이 장군을 Kingdom에 설치
KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"

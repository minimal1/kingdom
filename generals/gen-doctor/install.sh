#!/usr/bin/env bash
set -euo pipefail
KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"

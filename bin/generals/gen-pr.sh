#!/usr/bin/env bash
# bin/generals/gen-pr.sh — PR Review General entry point
BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
GENERAL_DOMAIN="gen-pr"
source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/general/common.sh"
main_loop

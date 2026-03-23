#!/usr/bin/env bash
# General harness helpers

get_general_manifest_path() {
  printf '%s/config/generals/%s.yaml\n' "$BASE_DIR" "$GENERAL_DOMAIN"
}

get_general_mode() {
  local manifest
  manifest=$(get_general_manifest_path)
  if [ ! -f "$manifest" ]; then
    echo "automation"
    return 0
  fi
  local mode
  mode=$(yq eval '.mode // "automation"' "$manifest" 2>/dev/null || echo "automation")
  [ -n "$mode" ] || mode="automation"
  echo "$mode"
}

harness_enabled() {
  [ "$(get_general_mode)" = "harnessed_dev" ]
}

read_harness_asset() {
  local filename="$1"
  local path="$BASE_DIR/config/generals/${GENERAL_DOMAIN}/${filename}"
  [ -f "$path" ] || return 1
  cat "$path"
}

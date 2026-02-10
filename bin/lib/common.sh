#!/usr/bin/env bash
# Kingdom Shared Library
# 모든 역할이 source하는 공통 함수

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"

# --- Platform Detection ---

PLATFORM="$(uname -s)"

is_macos() { [[ "$PLATFORM" == "Darwin" ]]; }
is_linux() { [[ "$PLATFORM" == "Linux" ]]; }

# --- Logging ---

log() {
  local message="$1"
  local ts
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$ts] $message" >> "$BASE_DIR/logs/system.log"
}

# --- Config ---

get_config() {
  local role="$1"
  local key="$2"
  local default="${3:-}"
  local config_file="$BASE_DIR/config/${role}.yaml"

  if [[ ! -f "$config_file" ]]; then
    echo "$default"
    return
  fi

  local value
  value=$(yq eval ".$key // \"\"" "$config_file" 2>/dev/null)

  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# --- Heartbeat ---

update_heartbeat() {
  local role="$1"
  local hb_file="$BASE_DIR/state/${role}/heartbeat"
  mkdir -p "$(dirname "$hb_file")"
  touch "$hb_file"
}

# --- Event Emission (External) ---

emit_event() {
  local event_json="$1"
  local event_id
  event_id=$(echo "$event_json" | jq -r '.id')
  local dir="$BASE_DIR/queue/events/pending"
  local tmp_file="$dir/.tmp-${event_id}.json"
  local final_file="$dir/${event_id}.json"

  echo "$event_json" > "$tmp_file"
  mv "$tmp_file" "$final_file"
}

# --- Internal Event Emission ---

emit_internal_event() {
  local type="$1"
  local actor="$2"
  local data="$3"
  [[ -z "$data" ]] && data='{}'
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # data를 printf로 안전하게 전달
  printf '%s' "$data" | jq -c \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg actor "$actor" \
    '{ts: $ts, type: $type, actor: $actor, data: .}' \
    >> "$BASE_DIR/logs/events.log"
}

# --- Portable Date ---

portable_date() {
  local format="$1"
  shift
  if [[ $# -eq 0 ]]; then
    date "$format"
  elif is_macos; then
    # macOS: date -j -f 또는 date -v 사용
    date -j "$@" "$format" 2>/dev/null || date "$format"
  else
    # Linux: date -d 사용
    date "$@" "$format" 2>/dev/null || date "$format"
  fi
}

# --- Get Modification Time ---

get_mtime() {
  local filepath="$1"
  if is_macos; then
    stat -f %m "$filepath"
  else
    stat -c %Y "$filepath"
  fi
}

# --- Portable File Lock ---

portable_flock() {
  local lockfile="$1"
  local command="$2"

  if is_macos; then
    # macOS: mkdir 기반 스핀락
    local max_wait=30
    local waited=0
    while ! mkdir "$lockfile.d" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
      if [[ $waited -ge $((max_wait * 10)) ]]; then
        rm -rf "$lockfile.d"
        mkdir "$lockfile.d" 2>/dev/null || true
        break
      fi
    done
    eval "$command"
    local rc=$?
    rm -rf "$lockfile.d"
    return $rc
  else
    # Linux: flock 사용
    (
      flock -w 30 200 || return 1
      eval "$command"
    ) 200>"$lockfile"
  fi
}

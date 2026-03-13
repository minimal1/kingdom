#!/usr/bin/env bash
# Kingdom Shared Library
# 모든 역할이 source하는 공통 함수

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"

# --- Load .env ---

if [[ -f "$BASE_DIR/.env" ]]; then
  set -a
  source "$BASE_DIR/.env"
  set +a
fi

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

start_heartbeat_daemon() {
  local role="$1"
  local interval="${2:-30}"
  (
    while true; do
      update_heartbeat "$role"
      sleep "$interval"
    done
  ) &
  _HEARTBEAT_PID=$!
}

stop_heartbeat_daemon() {
  if [[ -n "${_HEARTBEAT_PID:-}" ]]; then
    kill "$_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_HEARTBEAT_PID" 2>/dev/null || true
    _HEARTBEAT_PID=""
  fi
}

# --- Event Emission (External) ---

emit_event() {
  local event_json="$1"
  local event_id
  event_id=$(echo "$event_json" | jq -r '.id')
  local dir="$BASE_DIR/queue/events/pending"
  atomic_write_json_file "$dir" "${event_id}.json" "$event_json"
}

atomic_write_json_file() {
  local dir="$1"
  local filename="$2"
  local content="$3"
  mkdir -p "$dir" || return 1

  local tmp_file="$dir/.tmp-${filename}"
  local final_file="$dir/${filename}"

  printf '%s\n' "$content" > "$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }

  mv "$tmp_file" "$final_file" || {
    rm -f "$tmp_file"
    return 1
  }
}

write_state_json() {
  local file_path="$1"
  local content="$2"
  local dir
  dir=$(dirname "$file_path")
  atomic_write_json_file "$dir" "$(basename "$file_path")" "$content"
}

move_file_to_dir() {
  local file_path="$1"
  local target_dir="$2"
  mkdir -p "$target_dir" || return 1
  mv "$file_path" "$target_dir/"
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

# --- Sleep or Wake (fswatch 기반 즉시 깨움) ---

sleep_or_wake() {
  local timeout="$1"
  shift
  local watch_dirs=("$@")

  # fswatch 미설치 시 기존 sleep으로 fallback
  if ! command -v fswatch &>/dev/null; then
    sleep "$timeout"
    return
  fi

  # 유효한 디렉토리만 필터링
  local valid_dirs=()
  for dir in "${watch_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      valid_dirs+=("$dir")
    fi
  done

  # 유효한 디렉토리가 없으면 기존 sleep
  if [[ ${#valid_dirs[@]} -eq 0 ]]; then
    sleep "$timeout"
    return
  fi

  local fifo="/tmp/kingdom-wake-$$.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" 2>/dev/null || { sleep "$timeout"; return; }

  # Timeout guard: fswatch가 FIFO를 열기 전에 죽으면 read가 무한 블록하므로,
  # 타임아웃 후 FIFO에 write하여 read의 open()을 언블록한다.
  (sleep "$timeout" && echo "" > "$fifo" 2>/dev/null) &
  local timer_pid=$!

  fswatch --one-event --latency 0.5 "${valid_dirs[@]}" > "$fifo" 2>/dev/null &
  local watcher_pid=$!

  read < "$fifo" 2>/dev/null || true

  kill "$timer_pid" 2>/dev/null || true
  kill "$watcher_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  rm -f "$fifo"
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

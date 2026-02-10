#!/usr/bin/env bash
# Kingdom Directory Initializer
# 런타임 디렉토리 구조와 초기 상태 파일을 생성한다. (멱등)

set -euo pipefail

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"

# --- Directory Structure ---

mkdir -p "$BASE_DIR"/bin/lib/{sentinel,king,general,soldier,envoy,chamberlain}
mkdir -p "$BASE_DIR"/bin/generals
mkdir -p "$BASE_DIR"/config/generals/templates

mkdir -p "$BASE_DIR"/queue/events/{pending,dispatched,completed}
mkdir -p "$BASE_DIR"/queue/tasks/{pending,in_progress,completed}
mkdir -p "$BASE_DIR"/queue/messages/{pending,sent}

mkdir -p "$BASE_DIR"/state/{king,sentinel/seen,envoy,chamberlain,results,prompts}
mkdir -p "$BASE_DIR"/state/{gen-pr,gen-jira,gen-test}

mkdir -p "$BASE_DIR"/memory/shared
mkdir -p "$BASE_DIR"/memory/generals/{gen-pr,gen-jira,gen-test}

mkdir -p "$BASE_DIR"/logs/{sessions,analysis}

mkdir -p "$BASE_DIR"/workspace/{gen-pr,gen-jira,gen-test}

# --- Initial State Files (only if missing) ---

# sessions.json: JSONL format (empty file)
[[ -f "$BASE_DIR/state/sessions.json" ]] || touch "$BASE_DIR/state/sessions.json"

# resources.json
if [[ ! -f "$BASE_DIR/state/resources.json" ]]; then
  local_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ts "$local_ts" '{"health":"green","updated_at":$ts}' > "$BASE_DIR/state/resources.json"
fi

# King sequence counters
[[ -f "$BASE_DIR/state/king/task-seq" ]] || echo "0" > "$BASE_DIR/state/king/task-seq"
[[ -f "$BASE_DIR/state/king/msg-seq" ]] || echo "0" > "$BASE_DIR/state/king/msg-seq"

# King schedule tracking
[[ -f "$BASE_DIR/state/king/schedule-sent.json" ]] || echo '{}' > "$BASE_DIR/state/king/schedule-sent.json"

# Envoy state
[[ -f "$BASE_DIR/state/envoy/thread-mappings.json" ]] || echo '{}' > "$BASE_DIR/state/envoy/thread-mappings.json"
[[ -f "$BASE_DIR/state/envoy/awaiting-responses.json" ]] || echo '[]' > "$BASE_DIR/state/envoy/awaiting-responses.json"

# Chamberlain state
[[ -f "$BASE_DIR/state/chamberlain/events-offset" ]] || echo "0" > "$BASE_DIR/state/chamberlain/events-offset"

echo "Kingdom directories initialized at $BASE_DIR"

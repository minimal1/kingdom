#!/usr/bin/env bash
# Thread Manager - task_id <-> thread_ts mapping and awaiting management

MAPPINGS_FILE="$BASE_DIR/state/envoy/thread-mappings.json"
AWAITING_FILE="$BASE_DIR/state/envoy/awaiting-responses.json"

save_thread_mapping() {
  local task_id="$1" thread_ts="$2" channel="$3"
  portable_flock "$MAPPINGS_FILE.lock" \
    "jq --arg tid '$task_id' --arg ts '$thread_ts' --arg ch '$channel' \
      '.[\$tid] = {thread_ts: \$ts, channel: \$ch}' '$MAPPINGS_FILE' > '$MAPPINGS_FILE.tmp' \
    && mv '$MAPPINGS_FILE.tmp' '$MAPPINGS_FILE'"
}

get_thread_mapping() {
  local task_id="$1"
  jq -r --arg tid "$task_id" '.[$tid] // empty' "$MAPPINGS_FILE"
}

remove_thread_mapping() {
  local task_id="$1"
  portable_flock "$MAPPINGS_FILE.lock" \
    "jq --arg tid '$task_id' 'del(.[\$tid])' '$MAPPINGS_FILE' > '$MAPPINGS_FILE.tmp' \
    && mv '$MAPPINGS_FILE.tmp' '$MAPPINGS_FILE'"
}

add_awaiting_response() {
  local task_id="$1" thread_ts="$2" channel="$3"
  local asked_at
  asked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  portable_flock "$AWAITING_FILE.lock" \
    "jq --arg tid '$task_id' --arg ts '$thread_ts' --arg ch '$channel' --arg aa '$asked_at' \
      '. + [{task_id: \$tid, thread_ts: \$ts, channel: \$ch, asked_at: \$aa}]' \
      '$AWAITING_FILE' > '$AWAITING_FILE.tmp' \
    && mv '$AWAITING_FILE.tmp' '$AWAITING_FILE'"
}

remove_awaiting_response() {
  local task_id="$1"
  portable_flock "$AWAITING_FILE.lock" \
    "jq --arg tid '$task_id' '[.[] | select(.task_id != \$tid)]' \
      '$AWAITING_FILE' > '$AWAITING_FILE.tmp' \
    && mv '$AWAITING_FILE.tmp' '$AWAITING_FILE'"
}

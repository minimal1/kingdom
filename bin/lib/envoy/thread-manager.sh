#!/usr/bin/env bash
# Thread Manager - task_id <-> thread_ts mapping, awaiting responses, conversation threads

MAPPINGS_FILE="$BASE_DIR/state/envoy/thread-mappings.json"
AWAITING_FILE="$BASE_DIR/state/envoy/awaiting-responses.json"
CONV_FILE="$BASE_DIR/state/envoy/conversation-threads.json"

# --- Thread Mappings (task_id <-> thread_ts) ---

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

# --- Awaiting Responses (일회성: needs_human 질문 → 사람 응답) ---

add_awaiting_response() {
  local task_id="$1" thread_ts="$2" channel="$3" reply_context_json="${4:-"{}"}"
  local asked_at
  asked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  portable_flock "$AWAITING_FILE.lock" \
    "jq --arg tid '$task_id' --arg ts '$thread_ts' --arg ch '$channel' --arg aa '$asked_at' \
      --argjson rc '$reply_context_json' \
      '. + [{task_id: \$tid, thread_ts: \$ts, channel: \$ch, asked_at: \$aa, reply_context: \$rc}]' \
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

# --- Conversation Threads (멀티턴: 대화 스레드 추적) ---

save_conversation_thread() {
  local thread_ts="$1" task_id="$2" channel="$3" reply_context_json="${4:-"{}"}" ttl="${5:-3600}"
  local expires_at
  local now_epoch
  now_epoch=$(date +%s)
  local expires_epoch=$((now_epoch + ttl))
  if [[ "$(uname)" == "Darwin" ]]; then
    expires_at=$(date -u -r "$expires_epoch" +%Y-%m-%dT%H:%M:%SZ)
  else
    expires_at=$(date -u -d "@$expires_epoch" +%Y-%m-%dT%H:%M:%SZ)
  fi

  portable_flock "$CONV_FILE.lock" \
    "jq --arg ts '$thread_ts' --arg tid '$task_id' --arg ch '$channel' \
      --arg lrt '$thread_ts' --arg exp '$expires_at' --argjson rc '$reply_context_json' \
      '.[\$ts] = {task_id: \$tid, channel: \$ch, last_reply_ts: \$lrt, expires_at: \$exp, reply_context: \$rc}' \
      '$CONV_FILE' > '$CONV_FILE.tmp' \
    && mv '$CONV_FILE.tmp' '$CONV_FILE'"
}

get_conversation_thread() {
  local thread_ts="$1"
  jq -r --arg ts "$thread_ts" '.[$ts] // empty' "$CONV_FILE"
}

update_conversation_thread() {
  local thread_ts="$1" new_reply_ts="$2"
  portable_flock "$CONV_FILE.lock" \
    "jq --arg ts '$thread_ts' --arg nrt '$new_reply_ts' \
      'if .[\$ts] then .[\$ts].last_reply_ts = \$nrt else . end' \
      '$CONV_FILE' > '$CONV_FILE.tmp' \
    && mv '$CONV_FILE.tmp' '$CONV_FILE'"
}

remove_conversation_thread() {
  local thread_ts="$1"
  portable_flock "$CONV_FILE.lock" \
    "jq --arg ts '$thread_ts' 'del(.[\$ts])' '$CONV_FILE' > '$CONV_FILE.tmp' \
    && mv '$CONV_FILE.tmp' '$CONV_FILE'"
}

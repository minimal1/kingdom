#!/usr/bin/env bash
# Envoy outbound queue processing

MAX_RETRY_COUNT=$(get_config "envoy" "retry.max_count" "3")

process_outbound_queue() {
  local pending_dir="$BASE_DIR/queue/messages/pending"
  local sent_dir="$BASE_DIR/queue/messages/sent"
  local failed_dir="$BASE_DIR/queue/messages/failed"
  mkdir -p "$failed_dir"

  for msg_file in "$pending_dir"/*.json; do
    [[ -f "$msg_file" ]] || continue

    local msg msg_type
    msg=$(cat "$msg_file")
    msg_type=$(echo "$msg" | jq -r '.type')

    local send_ok=true
    case "$msg_type" in
      thread_start)        process_thread_start "$msg" || send_ok=false ;;
      thread_update)       process_thread_update "$msg" || send_ok=false ;;
      thread_reply)        process_thread_reply_msg "$msg" || send_ok=false ;;
      human_input_request) process_human_input_request "$msg" || send_ok=false ;;
      notification)        process_notification "$msg" || send_ok=false ;;
      report)              process_report "$msg" || send_ok=false ;;
      *)                   log "[EVENT] [envoy] Unknown message type: $msg_type" ;;
    esac

    if $send_ok; then
      if ! mv "$msg_file" "$sent_dir/"; then
        log "[ERROR] [envoy] Sent message archive failed, removing pending copy: $(basename "$msg_file")"
        rm -f "$msg_file"
      fi
    else
      local retry_count
      retry_count=$(echo "$msg" | jq -r '.retry_count // 0')
      retry_count=$((retry_count + 1))

      if (( retry_count >= MAX_RETRY_COUNT )); then
        log "[ERROR] [envoy] Message permanently failed after $retry_count retries: $(basename "$msg_file")"
        mv "$msg_file" "$failed_dir/"
      else
        echo "$msg" | jq --argjson rc "$retry_count" '.retry_count = $rc' > "${msg_file}.tmp"
        mv "${msg_file}.tmp" "$msg_file"
        log "[WARN] [envoy] Message send failed (retry $retry_count/$MAX_RETRY_COUNT): $(basename "$msg_file")"
      fi
    fi
  done
}

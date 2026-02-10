#!/usr/bin/env bash
# Chamberlain Auto-Recovery — alert creation + threshold checks

# --- Alert Creation ---

create_alert_message() {
  local content="$1"
  local urgency="${2:-normal}"
  local msg_id="msg-chamberlain-$(date +%s)-$$"

  jq -n \
    --arg id "$msg_id" \
    --arg content "$content" \
    --arg urgency "$urgency" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      type: "notification",
      task_id: null,
      content: $content,
      urgency: $urgency,
      created_at: $ts
    }' > "$BASE_DIR/queue/messages/pending/${msg_id}.json"

  log "[ALERT] [chamberlain] $content"
}

# --- Threshold Checks ---

check_thresholds_and_act() {
  local health="$1"

  # health red → urgent alert
  if [ "$health" = "red" ]; then
    create_alert_message "[긴급] 시스템 health RED — CPU: ${CPU_PERCENT}%, MEM: ${MEMORY_PERCENT}%" "high"
  fi

  # Disk warning
  local disk_warn
  disk_warn=$(get_config "chamberlain" "thresholds.disk_warning" 85)
  if (( $(echo "$DISK_PERCENT > $disk_warn" | bc -l 2>/dev/null || echo 0) )); then
    create_alert_message "Disk 사용률 ${DISK_PERCENT}% — 임계값 ${disk_warn}% 초과"
  fi
}

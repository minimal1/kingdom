#!/usr/bin/env bash
# Chamberlain Metrics Collector — system resource monitoring

# Global metric variables (set by collect_metrics)
CPU_PERCENT="0"
MEMORY_PERCENT="0"
DISK_PERCENT="0"
LOAD_AVG="0,0,0"

# --- Metrics Collection ---

collect_metrics() {
  if is_macos; then
    CPU_PERCENT=$(ps -A -o %cpu 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s}' || echo "0")

    local page_size
    page_size=$(vm_stat 2>/dev/null | head -1 | grep -o '[0-9]*$' || echo "4096")
    local pages_free pages_active pages_wired pages_speculative pages_total pages_used
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}' || echo "0")
    pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}' || echo "0")
    pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$4); print $4}' || echo "0")
    pages_speculative=$(vm_stat 2>/dev/null | awk '/Pages speculative/ {gsub(/\./,"",$3); print $3}' || echo "0")
    pages_total=$((pages_free + pages_active + pages_wired + pages_speculative))
    pages_used=$((pages_active + pages_wired))
    if (( pages_total > 0 )); then
      MEMORY_PERCENT=$(echo "scale=1; $pages_used * 100 / $pages_total" | bc 2>/dev/null || echo "0")
    else
      MEMORY_PERCENT="0"
    fi
  else
    CPU_PERCENT=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' || echo "0")
    MEMORY_PERCENT=$(free 2>/dev/null | grep Mem | awk '{printf "%.1f", $3/$2 * 100}' || echo "0")
  fi

  DISK_PERCENT=$(df "$BASE_DIR" 2>/dev/null | tail -1 | awk '{gsub(/%/,""); print $5}' || echo "0")

  # uptime: macOS "load averages:", Linux "load average:"
  LOAD_AVG=$(uptime 2>/dev/null | awk -F'load average[s]?:' '{print $2}' | sed 's/^ *//' | tr -d ' ' || echo "0,0,0")

  # 빈 값 방어: 파싱 실패 시 tonumber 에러 → resources.json 파손 방지
  [[ "$CPU_PERCENT" =~ ^[0-9]*\.?[0-9]+$ ]] || CPU_PERCENT="0"
  [[ "$MEMORY_PERCENT" =~ ^[0-9]*\.?[0-9]+$ ]] || MEMORY_PERCENT="0"
  [[ "$DISK_PERCENT" =~ ^[0-9]*\.?[0-9]+$ ]] || DISK_PERCENT="0"
  if [[ -z "$LOAD_AVG" ]]; then LOAD_AVG="0,0,0"; fi
}

# --- Health Assessment ---

get_current_health() {
  jq -r '.health // "green"' "$BASE_DIR/state/resources.json" 2>/dev/null || echo "green"
}

evaluate_health() {
  local cpu_red cpu_orange cpu_yellow mem_red mem_orange mem_yellow
  cpu_red=$(get_config "chamberlain" "thresholds.cpu_red" 90)
  cpu_orange=$(get_config "chamberlain" "thresholds.cpu_orange" 80)
  cpu_yellow=$(get_config "chamberlain" "thresholds.cpu_yellow" 60)
  mem_red=$(get_config "chamberlain" "thresholds.memory_red" 90)
  mem_orange=$(get_config "chamberlain" "thresholds.memory_orange" 80)
  mem_yellow=$(get_config "chamberlain" "thresholds.memory_yellow" 60)

  if (( $(echo "$CPU_PERCENT > $cpu_red" | bc -l 2>/dev/null || echo 0) )) || \
     (( $(echo "$MEMORY_PERCENT > $mem_red" | bc -l 2>/dev/null || echo 0) )); then
    echo "red"
  elif (( $(echo "$CPU_PERCENT > $cpu_orange" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$MEMORY_PERCENT > $mem_orange" | bc -l 2>/dev/null || echo 0) )); then
    echo "orange"
  elif (( $(echo "$CPU_PERCENT > $cpu_yellow" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$MEMORY_PERCENT > $mem_yellow" | bc -l 2>/dev/null || echo 0) )); then
    echo "yellow"
  else
    echo "green"
  fi
}

# --- Resources JSON ---

update_resources_json() {
  local health="$1"

  local soldiers_active
  soldiers_active=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
  local soldiers_max
  soldiers_max=$(get_config "king" "concurrency.max_soldiers" 3)

  local session_list
  session_list=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | jq -R . | jq -s . || echo '[]')

  # Detect token status change (before writing new state)
  local prev_token_status
  prev_token_status=$(jq -r '.tokens.status // "ok"' "$BASE_DIR/state/resources.json" 2>/dev/null || echo "ok")

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cpu "$CPU_PERCENT" \
    --arg mem "$MEMORY_PERCENT" \
    --arg disk "$DISK_PERCENT" \
    --arg load "$LOAD_AVG" \
    --arg health "$health" \
    --argjson soldiers_active "$soldiers_active" \
    --argjson soldiers_max "$soldiers_max" \
    --argjson sessions "$session_list" \
    --argjson tokens "$(jq -n \
      --arg cost "$ESTIMATED_DAILY_COST" \
      --arg status "$TOKEN_STATUS" \
      --argjson input "$DAILY_INPUT_TOKENS" \
      --argjson output "$DAILY_OUTPUT_TOKENS" \
      '{
        daily_cost_usd: $cost,
        status: $status,
        daily_input_tokens: $input,
        daily_output_tokens: $output
      }')" \
    '{
      timestamp: $ts,
      system: {
        cpu_percent: ($cpu | tonumber),
        memory_percent: ($mem | tonumber),
        disk_percent: ($disk | tonumber),
        load_average: ($load | split(",") | map(tonumber))
      },
      sessions: {
        soldiers_active: $soldiers_active,
        soldiers_max: $soldiers_max,
        list: $sessions
      },
      tokens: $tokens,
      health: $health
    }' > "$BASE_DIR/state/resources.json.tmp"

  # jq 실패 시 빈 파일이 정상 파일을 덮어쓰지 않도록 검증
  if jq empty "$BASE_DIR/state/resources.json.tmp" 2>/dev/null; then
    mv "$BASE_DIR/state/resources.json.tmp" "$BASE_DIR/state/resources.json"

    # Emit internal event and Slack notification if token status changed
    if [[ "$prev_token_status" != "$TOKEN_STATUS" ]] && [[ "$TOKEN_STATUS" != "unknown" ]]; then
      handle_token_status_change "$prev_token_status" "$TOKEN_STATUS"
    fi
  else
    rm -f "$BASE_DIR/state/resources.json.tmp"
  fi
}

# --- Token Status Change Handler ---

handle_token_status_change() {
  local from="$1"
  local to="$2"

  log "[INFO] [chamberlain] Token status changed: $from -> $to (cost: \$$ESTIMATED_DAILY_COST)"

  # Emit internal event
  local event_data
  event_data=$(jq -n \
    --arg from "$from" \
    --arg to "$to" \
    --arg cost "$ESTIMATED_DAILY_COST" \
    '{from: $from, to: $to, daily_cost_usd: $cost}')

  emit_internal_event "system.token_status_changed" "chamberlain" "$event_data"

  # Prepare Slack notification message
  local message icon
  case "$to" in
    warning)
      icon="⚠️"
      message="*Token Budget Alert*
Daily spend: \$$ESTIMATED_DAILY_COST / \$$(get_config "chamberlain" "token_limits.daily_budget_usd" 300) ($(get_config "chamberlain" "token_limits.warning_pct" 70)% threshold)
Action: Throttling low-priority tasks"
      ;;
    critical)
      icon="🚨"
      message="*Token Budget Critical*
Daily spend: \$$ESTIMATED_DAILY_COST / \$$(get_config "chamberlain" "token_limits.daily_budget_usd" 300) ($(get_config "chamberlain" "token_limits.critical_pct" 90)% threshold)
PAUSED: normal/low priority tasks
ACTIVE: high priority only"
      ;;
    ok)
      icon="✅"
      message="*Token Budget Recovered*
Resuming normal operations
Daily spend: \$$ESTIMATED_DAILY_COST / \$$(get_config "chamberlain" "token_limits.daily_budget_usd" 300)"
      ;;
    *)
      return 0
      ;;
  esac

  # Queue Slack notification
  queue_slack_message "$icon $message"
}

# --- Queue Slack Message ---

queue_slack_message() {
  local text="$1"
  local msg_id
  msg_id="msg-token-$(date +%s)-$$"

  jq -n \
    --arg id "$msg_id" \
    --arg type "token_alert" \
    --arg text "$text" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      type: $type,
      text: $text,
      timestamp: $ts
    }' > "$BASE_DIR/queue/messages/pending/${msg_id}.json"

  log "[DEBUG] [chamberlain] Queued Slack message: $msg_id"
}

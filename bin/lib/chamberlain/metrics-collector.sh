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
      health: $health
    }' > "$BASE_DIR/state/resources.json.tmp"

  mv "$BASE_DIR/state/resources.json.tmp" "$BASE_DIR/state/resources.json"
}

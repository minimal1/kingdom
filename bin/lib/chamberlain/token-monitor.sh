#!/usr/bin/env bash
# Chamberlain Token Monitor — API usage cost tracking and budget control

# Global token metric variables (exported by collect_token_metrics)
TOKEN_STATUS="ok"           # ok, warning, critical, unknown
DAILY_INPUT_TOKENS=0
DAILY_OUTPUT_TOKENS=0
ESTIMATED_DAILY_COST="0"

# Path to Claude Code stats cache
STATS_CACHE_FILE="$HOME/.claude/stats-cache.json"

# --- Token Metrics Collection ---

collect_token_metrics() {
  # Check if token monitoring is enabled
  local enabled
  enabled=$(get_config "chamberlain" "token_limits.enabled" "true")
  if [[ "$enabled" != "true" ]]; then
    TOKEN_STATUS="ok"
    DAILY_INPUT_TOKENS=0
    DAILY_OUTPUT_TOKENS=0
    ESTIMATED_DAILY_COST="0"
    return 0
  fi

  # Check if stats-cache.json exists
  if [[ ! -f "$STATS_CACHE_FILE" ]]; then
    log "[DEBUG] [token-monitor] stats-cache.json not found, status=unknown"
    TOKEN_STATUS="unknown"
    return 0
  fi

  # Parse daily token usage for today
  local today
  today=$(date +%Y-%m-%d)

  local daily_total_tokens
  daily_total_tokens=$(jq -r --arg date "$today" '
    .dailyModelTokens[]?
    | select(.date == $date)
    | .tokensByModel
    | to_entries[]
    | .value
  ' "$STATS_CACHE_FILE" 2>/dev/null | awk '{s+=$1} END {print s+0}')

  # Graceful degradation: if parsing fails, return unknown
  if [[ -z "$daily_total_tokens" ]] || ! [[ "$daily_total_tokens" =~ ^[0-9]+$ ]]; then
    log "[DEBUG] [token-monitor] Failed to parse tokens, status=unknown"
    TOKEN_STATUS="unknown"
    return 0
  fi

  # Estimate input/output ratio (70% input, 30% output)
  # Note: stats-cache.json doesn't separate input/output per day, so we estimate
  DAILY_INPUT_TOKENS=$(echo "$daily_total_tokens * 0.7" | bc 2>/dev/null | awk '{printf "%.0f", $0}')
  DAILY_OUTPUT_TOKENS=$(echo "$daily_total_tokens * 0.3" | bc 2>/dev/null | awk '{printf "%.0f", $0}')

  # Ensure valid numbers
  [[ "$DAILY_INPUT_TOKENS" =~ ^[0-9]+$ ]] || DAILY_INPUT_TOKENS=0
  [[ "$DAILY_OUTPUT_TOKENS" =~ ^[0-9]+$ ]] || DAILY_OUTPUT_TOKENS=0

  # Calculate estimated cost
  estimate_daily_cost

  # Evaluate token status based on budget
  evaluate_token_status
}

# --- Cost Estimation ---

estimate_daily_cost() {
  # Get pricing from config (per million tokens)
  local input_price output_price
  input_price=$(get_config "chamberlain" "pricing.input_per_mtok" "15.0")
  output_price=$(get_config "chamberlain" "pricing.output_per_mtok" "75.0")

  # Calculate cost: (input * price + output * price) / 1,000,000
  ESTIMATED_DAILY_COST=$(echo "scale=2; ($DAILY_INPUT_TOKENS * $input_price + $DAILY_OUTPUT_TOKENS * $output_price) / 1000000" | bc 2>/dev/null)

  # Ensure valid number
  if ! [[ "$ESTIMATED_DAILY_COST" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    ESTIMATED_DAILY_COST="0"
  fi
}

# --- Token Status Evaluation ---

evaluate_token_status() {
  # Get budget and thresholds from config
  local daily_budget warning_pct critical_pct
  daily_budget=$(get_config "chamberlain" "token_limits.daily_budget_usd" "300")
  warning_pct=$(get_config "chamberlain" "token_limits.warning_pct" "70")
  critical_pct=$(get_config "chamberlain" "token_limits.critical_pct" "90")

  # Calculate thresholds
  local warning_threshold critical_threshold
  warning_threshold=$(echo "scale=2; $daily_budget * $warning_pct / 100" | bc 2>/dev/null)
  critical_threshold=$(echo "scale=2; $daily_budget * $critical_pct / 100" | bc 2>/dev/null)

  # Determine status
  if (( $(echo "$ESTIMATED_DAILY_COST >= $critical_threshold" | bc -l 2>/dev/null || echo 0) )); then
    TOKEN_STATUS="critical"
  elif (( $(echo "$ESTIMATED_DAILY_COST >= $warning_threshold" | bc -l 2>/dev/null || echo 0) )); then
    TOKEN_STATUS="warning"
  else
    TOKEN_STATUS="ok"
  fi

  log "[DEBUG] [token-monitor] daily_cost=$ESTIMATED_DAILY_COST budget=$daily_budget status=$TOKEN_STATUS"
}

# --- Date Change Detection ---

# Check if date has changed (for daily budget reset)
# Returns 0 if date changed, 1 otherwise
detect_date_change() {
  local last_date_file="$BASE_DIR/state/last_token_date.txt"
  local today
  today=$(date +%Y-%m-%d)

  if [[ ! -f "$last_date_file" ]]; then
    echo "$today" > "$last_date_file"
    return 1  # First run, no change
  fi

  local last_date
  last_date=$(cat "$last_date_file" 2>/dev/null || echo "")

  if [[ "$today" != "$last_date" ]]; then
    echo "$today" > "$last_date_file"
    return 0  # Date changed
  fi

  return 1  # No change
}

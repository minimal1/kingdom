#!/usr/bin/env bash
# General Prompt Builder — assembles prompts from template + dynamic sections
# Soul (common + general-specific) is delivered via CLAUDE.md (context compression safe)

# Maximum prompt size in bytes (default 200KB)
MAX_PROMPT_BYTES="${MAX_PROMPT_BYTES:-204800}"

build_prompt() {
  local task_json="$1"

  local task_id
  task_id=$(echo "$task_json" | jq -r '.id')
  local task_type
  task_type=$(echo "$task_json" | jq -r '.type')
  local payload
  payload=$(echo "$task_json" | jq -c '.payload')
  local repo
  repo=$(echo "$task_json" | jq -r '.repo // ""')

  # --- Task Prompt (template) ---
  local template="$BASE_DIR/config/generals/templates/${GENERAL_DOMAIN}.md"
  if [ ! -f "$template" ]; then
    log "[WARN] [$GENERAL_DOMAIN] Template not found: $template, using default"
    template="$BASE_DIR/config/generals/templates/default.md"
  fi

  if [ ! -f "$template" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] No template available"
    return 1
  fi

  # Build substituted content
  local content
  content=$(sed -e "s|{{TASK_ID}}|$task_id|g" \
                -e "s|{{TASK_TYPE}}|$task_type|g" \
                -e "s|{{REPO}}|$repo|g" \
                "$template")

  # Payload field substitution: {{payload.KEY}} → value
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local key val
    key=$(echo "$line" | jq -r '.key')
    val=$(echo "$line" | jq -r '.value // ""')
    content=$(echo "$content" | sed "s|{{payload\\.${key}}}|${val}|g")
  done <<< "$(echo "$payload" | jq -c 'to_entries[]' 2>/dev/null || true)"

  echo "$content"

  # Dynamic sections
  # Skip payload dump if template used {{payload.*}} placeholders (already consumed inline)
  if grep -q '{{payload\.' "$template" 2>/dev/null; then
    : # Template consumed payload via placeholders
  else
    echo ""
    echo "## Task Payload"
    echo '```json'
    echo "$payload" | jq .
    echo '```'
  fi

}

# --- Prompt Size Guard ---

check_prompt_size() {
  local prompt_file="$1"
  local max_bytes="${2:-$MAX_PROMPT_BYTES}"

  if [ ! -f "$prompt_file" ]; then
    return 0
  fi

  local size
  if is_macos; then
    size=$(stat -f %z "$prompt_file" 2>/dev/null || echo 0)
  else
    size=$(stat -c %s "$prompt_file" 2>/dev/null || echo 0)
  fi

  if (( size > max_bytes )); then
    local size_kb=$((size / 1024))
    local max_kb=$((max_bytes / 1024))
    log "[WARN] [$GENERAL_DOMAIN] Prompt size ${size_kb}KB exceeds limit ${max_kb}KB, truncating memory section"

    # Truncate by removing Domain Memory section content beyond limit
    local head_bytes=$((max_bytes - 1024))  # Leave 1KB buffer
    head -c "$head_bytes" "$prompt_file" > "${prompt_file}.truncated"
    echo "" >> "${prompt_file}.truncated"
    echo "<!-- [TRUNCATED: prompt exceeded ${max_kb}KB limit] -->" >> "${prompt_file}.truncated"
    mv "${prompt_file}.truncated" "$prompt_file"
  fi
}

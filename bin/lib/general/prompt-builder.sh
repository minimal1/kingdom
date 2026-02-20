#!/usr/bin/env bash
# General Prompt Builder — assembles prompts from soul + user + template + dynamic sections

# Maximum prompt size in bytes (default 200KB)
MAX_PROMPT_BYTES="${MAX_PROMPT_BYTES:-204800}"

build_prompt() {
  local task_json="$1"
  local memory="$2"
  local repo_context="$3"

  local task_id
  task_id=$(echo "$task_json" | jq -r '.id')
  local task_type
  task_type=$(echo "$task_json" | jq -r '.type')
  local payload
  payload=$(echo "$task_json" | jq -c '.payload')
  local repo
  repo=$(echo "$task_json" | jq -r '.repo // ""')

  # --- Layer 1: Soul (common + general-specific) ---
  _emit_soul_layer

  # --- Layer 2: User Context ---
  _emit_user_layer

  # --- Layer 3: Task Prompt (template) ---
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

  if [ -n "$memory" ]; then
    echo ""
    echo "## Domain Memory"
    echo "$memory"
  fi

  if [ -n "$repo_context" ]; then
    echo ""
    echo "## Repository Context"
    echo "$repo_context"
  fi
}

# --- Soul Layer: common principles + general-specific personality ---

_emit_soul_layer() {
  local common_soul="$BASE_DIR/config/soul.md"
  local general_soul="$BASE_DIR/config/generals/${GENERAL_DOMAIN}/soul.md"

  # Also check source package location for general soul
  local pkg_soul="$BASE_DIR/generals/${GENERAL_DOMAIN}/soul.md"

  local has_soul=false

  if [ -f "$common_soul" ]; then
    cat "$common_soul"
    echo ""
    has_soul=true
  fi

  if [ -f "$general_soul" ]; then
    cat "$general_soul"
    echo ""
    has_soul=true
  elif [ -f "$pkg_soul" ]; then
    cat "$pkg_soul"
    echo ""
    has_soul=true
  fi

  if $has_soul; then
    echo "---"
    echo ""
  fi
}

# --- User Context Layer: team/company context ---

_emit_user_layer() {
  local user_context="$BASE_DIR/config/user.md"

  if [ -f "$user_context" ]; then
    cat "$user_context"
    echo ""
    echo "---"
    echo ""
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

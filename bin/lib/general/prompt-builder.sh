#!/usr/bin/env bash
# General Prompt Builder — assembles prompts from templates + dynamic sections

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

  # Select template
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

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

  # Template with placeholder substitution
  sed -e "s|{{TASK_ID}}|$task_id|g" \
      -e "s|{{TASK_TYPE}}|$task_type|g" \
      -e "s|{{REPO}}|$repo|g" \
      "$template"

  # Dynamic sections
  echo ""
  echo "## Task Payload"
  echo '```json'
  echo "$payload" | jq .
  echo '```'

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

  echo ""
  echo "## Output Requirements"
  echo "Write the result as a JSON file using the Write tool:"
  echo '```'
  echo "$BASE_DIR/state/results/${task_id}-raw.json"
  echo '```'
  echo "Schema:"
  echo '```json'
  echo "{\"task_id\": \"$task_id\", \"status\": \"success|failed|needs_human\","
  echo ' "summary": "...", "error": "...", "question": "...",'
  echo ' "details": {...}, "memory_updates": [...]}'
  echo '```'
}

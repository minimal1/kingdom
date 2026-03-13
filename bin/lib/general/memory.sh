#!/usr/bin/env bash
# General memory helpers

load_domain_memory() {
  local domain="$1"
  local memory_dir="$BASE_DIR/memory/generals/$domain"

  if [ -d "$memory_dir" ]; then
    cat "$memory_dir"/*.md 2>/dev/null | head -c 50000
  else
    echo ""
  fi
}

load_repo_memory() {
  local domain="$1"
  local repo="$2"

  [ -z "$repo" ] && echo "" && return 0

  local repo_slug
  repo_slug=$(echo "$repo" | tr '/' '-')
  local repo_file="$BASE_DIR/memory/generals/${domain}/repo-${repo_slug}.md"

  if [ -f "$repo_file" ]; then
    cat "$repo_file"
  else
    echo ""
  fi
}

update_memory() {
  local result="$1"
  local updates
  updates=$(echo "$result" | jq -r '.memory_updates[]' 2>/dev/null || true)

  [ -z "$updates" ] && return 0

  local memory_file="$BASE_DIR/memory/generals/${GENERAL_DOMAIN}/learned-patterns.md"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  portable_flock "$memory_file.lock" "
    echo '' >> '$memory_file'
    echo '### $timestamp' >> '$memory_file'
    echo '$updates' | while IFS= read -r line; do
      [ -n \"\$line\" ] && echo \"- \$line\" >> '$memory_file'
    done
  "

  local count
  count=$(echo "$updates" | grep -c '[^ ]' 2>/dev/null || echo 0)
  log "[SYSTEM] [$GENERAL_DOMAIN] Memory updated: $count new patterns"
}

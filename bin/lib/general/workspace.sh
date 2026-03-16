#!/usr/bin/env bash
# General workspace helpers

ensure_workspace() {
  local general="$1"
  local repo="$2"
  local work_dir="$BASE_DIR/workspace/$general"

  mkdir -p "$work_dir" || {
    log "[ERROR] [$general] Failed to create workspace: $work_dir"
    return 1
  }

  local manifest="$BASE_DIR/config/generals/${general}.yaml"
  if [ ! -f "$manifest" ]; then
    log "[ERROR] [$general] Manifest not found: $manifest"
    return 1
  fi

  local plugin_count
  plugin_count=$(yq eval '.cc_plugins | length' "$manifest" 2>/dev/null || echo "0")
  if (( plugin_count > 0 )); then
    local global_settings="$HOME/.claude/settings.json"
    if [ ! -f "$global_settings" ]; then
      log "[ERROR] [$general] ~/.claude/settings.json not found"
      return 1
    fi

    local i=0
    while (( i < plugin_count )); do
      local required_name
      required_name=$(yq eval ".cc_plugins[$i]" "$manifest")
      local found
      found=$(jq -r --arg n "$required_name" '.enabledPlugins // {} | keys[] | select(startswith($n + "@") or . == $n)' "$global_settings" | head -1)
      if [ -z "$found" ]; then
        log "[ERROR] [$general] Required plugin not enabled globally: $required_name"
        return 1
      fi
      i=$((i + 1))
    done
  fi

  if [ -n "$repo" ]; then
    local repo_dir="$work_dir/$(basename "$repo")"
    if [ ! -d "$repo_dir" ]; then
      log "[SYSTEM] [$general] Cloning repo: $repo"
      if ! git clone "git@github.com:${repo}.git" "$repo_dir" >/dev/null 2>&1; then
        log "[ERROR] [$general] Failed to clone repo: $repo"
        return 1
      fi
    else
      if ! git -C "$repo_dir" fetch origin >/dev/null 2>&1; then
        log "[WARN] [$general] Failed to fetch repo: $repo (continuing with stale)"
      fi
    fi
  fi

  if [ -n "$repo" ]; then
    echo "$work_dir/$(basename "$repo")"
  else
    echo "$work_dir"
  fi
}

sync_general_agents() {
  local general="$1"
  local work_dir="$2"
  local agents_src="$BASE_DIR/config/generals/agents/${general}"
  local skills_src="$BASE_DIR/config/generals/skills/${general}"

  sync_runtime_assistant_dirs "$agents_src" "$work_dir" "agents"
  sync_runtime_assistant_dirs "$skills_src" "$work_dir" "skills"
}

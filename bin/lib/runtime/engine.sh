#!/usr/bin/env bash
# Runtime engine helpers (Claude Code / Codex)

get_runtime_engine() {
  local engine
  engine=$(get_config "system" "runtime.engine" "claude")
  case "$engine" in
    claude|codex) printf '%s\n' "$engine" ;;
    *) printf 'claude\n' ;;
  esac
}

get_runtime_command() {
  local engine="${1:-$(get_runtime_engine)}"
  case "$engine" in
    claude) get_config "system" "runtime.claude.command" "claude" ;;
    codex)  get_config "system" "runtime.codex.command" "codex" ;;
  esac
}

runtime_instruction_filenames() {
  printf '%s\n' "CLAUDE.md" "AGENTS.md"
}

copy_instruction_file_pair() {
  local source_file="$1"
  local target_dir="$2"
  [ -f "$source_file" ] || return 0
  mkdir -p "$target_dir" || return 1

  while IFS= read -r filename; do
    cp "$source_file" "$target_dir/$filename"
  done < <(runtime_instruction_filenames)
}

sync_runtime_assistant_dirs() {
  local src_dir="$1"
  local work_dir="$2"
  local kind="$3"
  [ -d "$src_dir" ] || return 0

  mkdir -p "$work_dir/.claude/$kind" "$work_dir/.codex/$kind"
  if [ "$kind" = "skills" ]; then
    cp -R "$src_dir/." "$work_dir/.claude/$kind/" 2>/dev/null || true
    cp -R "$src_dir/." "$work_dir/.codex/$kind/" 2>/dev/null || true
  else
    cp "$src_dir"/*.md "$work_dir/.claude/$kind/" 2>/dev/null || true
    cp "$src_dir"/*.md "$work_dir/.codex/$kind/" 2>/dev/null || true
  fi
}

runtime_prepare_command() {
  local engine="$1"
  local prompt_file="$2"
  local work_dir="$3"
  local stdout_file="$4"
  local stderr_file="$5"
  local session_id_file="$6"
  local resume_token="${7:-}"

  case "$engine" in
    claude)
      local claude_cmd
      claude_cmd=$(get_runtime_command "$engine")
      local args="--dangerously-skip-permissions --output-format json"
      if [ -n "$resume_token" ]; then
        args="$args --resume '$resume_token'"
      fi
      cat <<EOF
cd '$work_dir' && eval $claude_cmd -p $args \
  < '$prompt_file' \
  > '$stdout_file' 2>'$stderr_file'; \
jq -r '.session_id // empty' '$stdout_file' > '$session_id_file' 2>/dev/null
EOF
      ;;
    codex)
      local codex_cmd model sandbox full_auto
      codex_cmd=$(get_runtime_command "$engine")
      model=$(get_config "system" "runtime.codex.model" "")
      sandbox=$(get_config "system" "runtime.codex.sandbox" "workspace-write")
      full_auto=$(get_config "system" "runtime.codex.full_auto" "true")
      local args="exec --json --skip-git-repo-check"
      [ -n "$model" ] && args="$args --model '$model'"
      [ -n "$sandbox" ] && args="$args --sandbox '$sandbox'"
      [ "$full_auto" = "true" ] && args="$args --full-auto"
      if [ -n "$resume_token" ]; then
        args="exec resume --json --skip-git-repo-check"
        [ -n "$model" ] && args="$args --model '$model'"
        [ "$full_auto" = "true" ] && args="$args --full-auto"
        args="$args '$resume_token' -"
      else
        args="$args -"
      fi
      cat <<EOF
cd '$work_dir' && $codex_cmd $args \
  < '$prompt_file' \
  > '$stdout_file' 2>'$stderr_file'; \
jq -r '.session_id // .data.session_id // empty' '$stdout_file' | head -1 > '$session_id_file' 2>/dev/null || true
EOF
      ;;
  esac
}

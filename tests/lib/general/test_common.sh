#!/usr/bin/env bats
# general/common.sh unit tests

setup() {
  load '../../test_helper'
  setup_kingdom_env

  # Override HOME for global settings.json isolation
  ORIGINAL_HOME="$HOME"
  export HOME="$(mktemp -d)"

  # Copy configs
  install_test_general "gen-pr"
  install_test_general "gen-briefing"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/common.sh"

  GENERAL_DOMAIN="gen-pr"

  # Create mock spawn-soldier.sh for testing
  cat > "$BASE_DIR/mock-spawn-soldier.sh" << 'MOCKEOF'
#!/usr/bin/env bash
TASK_ID="$1"
SOLDIER_ID="soldier-$(date +%s)-$$"
echo "$SOLDIER_ID" > "${KINGDOM_BASE_DIR}/state/results/${TASK_ID}-soldier-id"
MOCKEOF
  chmod +x "$BASE_DIR/mock-spawn-soldier.sh"
  export SPAWN_SOLDIER_SCRIPT="$BASE_DIR/mock-spawn-soldier.sh"

  source "${BATS_TEST_DIRNAME}/../../../bin/lib/general/common.sh"

  # Initialize sessions.json as JSON array
  echo '[]' > "$BASE_DIR/state/sessions.json"
}

teardown() {
  teardown_kingdom_env
  if [[ -n "$HOME" && "$HOME" == /tmp/* ]]; then
    rm -rf "$HOME"
  fi
  export HOME="$ORIGINAL_HOME"
}

# --- pick_next_task ---

@test "general: pick_next_task returns matching task" {
  cat > "$BASE_DIR/queue/tasks/pending/task-001.json" << 'EOF'
{"id":"task-001","target_general":"gen-pr","priority":"normal","status":"pending"}
EOF

  local result
  result=$(pick_next_task "gen-pr")
  [[ "$result" == *"task-001.json" ]]
}

@test "general: pick_next_task ignores other generals" {
  cat > "$BASE_DIR/queue/tasks/pending/task-001.json" << 'EOF'
{"id":"task-001","target_general":"gen-briefing","priority":"normal","status":"pending"}
EOF

  local result
  result=$(pick_next_task "gen-pr")
  [ -z "$result" ]
}

@test "general: pick_next_task selects high priority first" {
  cat > "$BASE_DIR/queue/tasks/pending/task-low.json" << 'EOF'
{"id":"task-low","target_general":"gen-pr","priority":"low","status":"pending"}
EOF
  cat > "$BASE_DIR/queue/tasks/pending/task-high.json" << 'EOF'
{"id":"task-high","target_general":"gen-pr","priority":"high","status":"pending"}
EOF

  local result
  result=$(pick_next_task "gen-pr")
  [[ "$result" == *"task-high.json" ]]
}

@test "general: pick_next_task returns empty for no tasks" {
  local result
  result=$(pick_next_task "gen-pr")
  [ -z "$result" ]
}

# --- ensure_workspace ---

@test "general: ensure_workspace creates directory" {
  # Setup global settings with plugin enabled
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"friday@qp-plugin":true}}' > "$HOME/.claude/settings.json"

  local result
  result=$(ensure_workspace "gen-pr" "")
  assert [ -d "$BASE_DIR/workspace/gen-pr" ]
}

@test "general: ensure_workspace validates plugin enabled globally" {
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"friday@qp-plugin":true,"sunday@qp-plugin":true}}' > "$HOME/.claude/settings.json"

  run ensure_workspace "gen-pr" ""
  assert_success
}

@test "general: ensure_workspace fails when plugin not enabled" {
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"other-plugin@some-marketplace":true}}' > "$HOME/.claude/settings.json"

  run ensure_workspace "gen-pr" ""
  assert_failure
}

@test "general: ensure_workspace skips validation without cc_plugins" {
  # Use a manifest without cc_plugins
  cat > "$BASE_DIR/config/generals/gen-noplugin.yaml" << 'EOF'
name: gen-noplugin
description: "No plugin general"
subscribes: []
schedules: []
EOF

  run ensure_workspace "gen-noplugin" ""
  assert_success
}

@test "general: ensure_workspace fails when settings.json missing" {
  # Ensure no settings.json exists
  rm -f "$HOME/.claude/settings.json"

  run ensure_workspace "gen-pr" ""
  assert_failure
}

@test "general: ensure_workspace clones repo" {
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"friday@qp-plugin":true}}' > "$HOME/.claude/settings.json"

  local result
  result=$(ensure_workspace "gen-pr" "chequer/frontend")

  # Mock git should have created the directory
  assert [ -d "$BASE_DIR/workspace/gen-pr/frontend" ]
}

# --- load_domain_memory / load_repo_memory ---

@test "general: load_domain_memory returns md content" {
  echo "pattern 1: avoid barrel exports" > "$BASE_DIR/memory/generals/gen-pr/patterns.md"

  local result
  result=$(load_domain_memory "gen-pr")
  [[ "$result" == *"barrel exports"* ]]
}

@test "general: load_domain_memory returns empty for missing dir" {
  local result
  result=$(load_domain_memory "gen-nonexistent")
  [ -z "$result" ]
}

@test "general: load_repo_memory returns repo-specific content" {
  echo "TypeScript strict mode" > "$BASE_DIR/memory/generals/gen-pr/repo-chequer-frontend.md"

  local result
  result=$(load_repo_memory "gen-pr" "chequer/frontend")
  [[ "$result" == *"TypeScript strict mode"* ]]
}

@test "general: load_repo_memory returns empty for unknown repo" {
  local result
  result=$(load_repo_memory "gen-pr" "unknown/repo")
  [ -z "$result" ]
}

@test "general: load_repo_memory returns empty for empty repo" {
  local result
  result=$(load_repo_memory "gen-pr" "")
  [ -z "$result" ]
}

# --- report_to_king ---

@test "general: report_to_king creates result file" {
  report_to_king "task-001" "success" "PR approved" ""

  assert [ -f "$BASE_DIR/state/results/task-001.json" ]
  run jq -r '.status' "$BASE_DIR/state/results/task-001.json"
  assert_output "success"
  run jq -r '.summary' "$BASE_DIR/state/results/task-001.json"
  assert_output "PR approved"
}

@test "general: report_to_king with raw result preserves data" {
  local raw='{"task_id":"task-002","status":"failed","error":"build failed","summary":"lint error"}'
  report_to_king "task-002" "failed" "" "$raw"

  assert [ -f "$BASE_DIR/state/results/task-002.json" ]
  run jq -r '.error' "$BASE_DIR/state/results/task-002.json"
  assert_output "build failed"
}

@test "general: report_to_king skipped preserves reason" {
  local raw='{"task_id":"task-skip","status":"skipped","reason":"PR is outside frontend scope"}'
  report_to_king "task-skip" "skipped" "" "$raw"

  assert [ -f "$BASE_DIR/state/results/task-skip.json" ]
  run jq -r '.status' "$BASE_DIR/state/results/task-skip.json"
  assert_output "skipped"
  run jq -r '.reason' "$BASE_DIR/state/results/task-skip.json"
  assert_output "PR is outside frontend scope"
}

@test "general: report_to_king no tmp file remains" {
  report_to_king "task-003" "success" "done" ""

  local tmp_count
  tmp_count=$(ls "$BASE_DIR/state/results/"*.tmp 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]
}

# --- escalate_to_king ---

@test "general: escalate_to_king creates checkpoint" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-004.json" << 'EOF'
{"id":"task-004","target_general":"gen-pr","repo":"chequer/frontend","payload":{"pr":123}}
EOF

  local raw='{"task_id":"task-004","status":"needs_human","question":"Approve?"}'
  escalate_to_king "task-004" "$raw"

  assert [ -f "$BASE_DIR/state/results/task-004-checkpoint.json" ]
  run jq -r '.target_general' "$BASE_DIR/state/results/task-004-checkpoint.json"
  assert_output "gen-pr"
}

@test "general: escalate_to_king creates result with checkpoint_path" {
  cat > "$BASE_DIR/queue/tasks/in_progress/task-005.json" << 'EOF'
{"id":"task-005","target_general":"gen-pr","repo":"chequer/frontend","payload":{}}
EOF

  local raw='{"task_id":"task-005","status":"needs_human","question":"Which branch?"}'
  escalate_to_king "task-005" "$raw"

  assert [ -f "$BASE_DIR/state/results/task-005.json" ]
  run jq -r '.status' "$BASE_DIR/state/results/task-005.json"
  assert_output "needs_human"
  run jq -r '.checkpoint_path' "$BASE_DIR/state/results/task-005.json"
  assert_output --partial "task-005-checkpoint.json"
}

# --- update_memory ---

@test "general: update_memory appends to learned-patterns" {
  local raw='{"memory_updates":["avoid barrel exports","use strict mode"]}'
  update_memory "$raw"

  assert [ -f "$BASE_DIR/memory/generals/gen-pr/learned-patterns.md" ]
  run cat "$BASE_DIR/memory/generals/gen-pr/learned-patterns.md"
  assert_output --partial "barrel exports"
  assert_output --partial "strict mode"
}

@test "general: update_memory skips when no updates" {
  local raw='{"status":"success"}'
  update_memory "$raw"

  assert [ ! -f "$BASE_DIR/memory/generals/gen-pr/learned-patterns.md" ]
}

# --- spawn_soldier ---

@test "general: spawn_soldier fails without prompt file" {
  run spawn_soldier "task-006" "/nonexistent/prompt.md" "$BASE_DIR/workspace/gen-pr"
  assert_failure
}

@test "general: spawn_soldier fails without work dir" {
  local prompt_file
  prompt_file=$(mktemp)
  echo "test prompt" > "$prompt_file"

  run spawn_soldier "task-007" "$prompt_file" "/nonexistent/workdir"
  assert_failure
  rm -f "$prompt_file"
}

@test "general: spawn_soldier creates soldier-id file" {
  mkdir -p "$BASE_DIR/workspace/gen-pr"
  local prompt_file="$BASE_DIR/state/prompts/task-008.md"
  echo "test prompt" > "$prompt_file"

  spawn_soldier "task-008" "$prompt_file" "$BASE_DIR/workspace/gen-pr"

  assert [ -f "$BASE_DIR/state/results/task-008-soldier-id" ]
  local soldier_id
  soldier_id=$(cat "$BASE_DIR/state/results/task-008-soldier-id")
  [[ "$soldier_id" == soldier-* ]]
}

# --- wait_for_soldier ---

@test "general: wait_for_soldier detects result file" {
  local raw_file="$BASE_DIR/state/results/task-009-raw.json"
  echo '{"task_id":"task-009","status":"success"}' > "$raw_file"

  wait_for_soldier "task-009" "$raw_file" 5
  # Should not create a timeout failure file
  run jq -r '.status' "$raw_file"
  assert_output "success"
}

@test "general: wait_for_soldier timeout creates failed result" {
  local raw_file="$BASE_DIR/state/results/task-010-raw.json"
  echo "soldier-test" > "$BASE_DIR/state/results/task-010-soldier-id"

  wait_for_soldier "task-010" "$raw_file" 1

  assert [ -f "$raw_file" ]
  run jq -r '.status' "$raw_file"
  assert_output "failed"
  run jq -r '.error' "$raw_file"
  assert_output --partial "Timeout"
}

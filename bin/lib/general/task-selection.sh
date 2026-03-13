#!/usr/bin/env bash
# General task selection helpers

pick_next_task() {
  local general="$1"
  local pending_dir="$BASE_DIR/queue/tasks/pending"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local best_file=""
  local best_order=99

  for f in "$pending_dir"/*.json; do
    [ -f "$f" ] || continue

    local target
    target=$(jq -r '.target_general' "$f" 2>/dev/null)
    [ "$target" = "$general" ] || continue

    local retry_after
    retry_after=$(jq -r '.retry_after // ""' "$f" 2>/dev/null)
    if [ -n "$retry_after" ] && [[ "$retry_after" > "$now" ]]; then
      continue
    fi

    local priority
    priority=$(jq -r '.priority' "$f" 2>/dev/null)
    local order=2
    case "$priority" in
      high) order=1 ;;
      normal) order=2 ;;
      low) order=3 ;;
    esac

    if (( order < best_order )); then
      best_order=$order
      best_file="$f"
    fi
  done

  echo "$best_file"
}

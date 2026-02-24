#!/usr/bin/env bash
# King petition functions — 상소 심의 (비동기 DM 메시지 분류)
# spawn_petition: tmux로 비동기 LLM 분류 실행
# process_petition_results: 완료된 분류 결과 수거 → 4단계 분기

PETITION_RESULTS_DIR="$BASE_DIR/state/king/petition-results"
PETITIONING_DIR="$BASE_DIR/queue/events/petitioning"

# --- spawn_petition: tmux 세션으로 상소 심의 비동기 실행 ---

spawn_petition() {
  local event_id="$1"
  local message_text="$2"
  local session_name="petition-${event_id}"

  if ! tmux new-session -d -s "$session_name" \
    "export KINGDOM_BASE_DIR='$BASE_DIR' && \
     bash '$BASE_DIR/bin/petition-runner.sh' '$event_id' '$message_text'; \
     tmux wait-for -S ${session_name}-done" 2>/dev/null; then
    log "[ERROR] [king] Failed to spawn petition session: $session_name"
    return 1
  fi

  log "[SYSTEM] [king] Petition spawned: $session_name"
}

# --- process_petition_results: 완료된 상소 심의 결과 수거 ---

process_petition_results() {
  for result_file in "$PETITION_RESULTS_DIR"/*.json; do
    [ -f "$result_file" ] || continue

    local event_id
    event_id=$(basename "$result_file" .json)
    local event_file="$PETITIONING_DIR/${event_id}.json"

    # 이벤트 파일이 없으면 orphan result -> 정리
    if [ ! -f "$event_file" ]; then
      rm -f "$result_file"
      continue
    fi

    local event
    event=$(cat "$event_file")
    local event_type
    event_type=$(echo "$event" | jq -r '.type')
    local result
    result=$(cat "$result_file")

    # 4단계 분기
    local general
    general=$(echo "$result" | jq -r '.general // empty' 2>/dev/null || true)

    if [ -n "$general" ]; then
      # 1단계: 장군 매칭 성공 -> repo 병합 후 dispatch
      local petition_repo
      petition_repo=$(echo "$result" | jq -r '.repo // empty' 2>/dev/null || true)
      if [ -n "$petition_repo" ]; then
        event=$(echo "$event" | jq --arg r "$petition_repo" '.repo = $r')
      fi
      dispatch_new_task "$event" "$general" "$event_file"
    else
      local direct_response
      direct_response=$(echo "$result" | jq -r '.direct_response // empty' 2>/dev/null || true)

      if [ -n "$direct_response" ]; then
        # 2단계: direct_response -> 사절에게 즉시 답변
        handle_direct_response "$event" "$event_file" "$direct_response"
      else
        # 3단계: 정적 매핑 폴백
        local static_general
        static_general=$(find_general "$event_type" 2>/dev/null || true)
        if [ -n "$static_general" ]; then
          dispatch_new_task "$event" "$static_general" "$event_file"
        else
          # 4단계: 모두 실패 -> 처리 불가
          handle_unroutable_dm "$event" "$event_file"
        fi
      fi
    fi

    # 결과 파일 정리
    rm -f "$result_file"
  done
}

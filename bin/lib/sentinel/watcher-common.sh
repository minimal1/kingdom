#!/usr/bin/env bash
# Sentinel Watcher Common Functions
# 파수꾼 전용 유틸리티: emit 래퍼, 중복 방지, 상태 관리

# sentinel_emit_event: emit_event + seen 인덱스 마킹
sentinel_emit_event() {
  local event_json="$1"
  local event_id
  event_id=$(echo "$event_json" | jq -r '.id')

  emit_event "$event_json"

  # seen 인덱스: 빈 파일로 중복 방지 마커
  touch "$BASE_DIR/state/sentinel/seen/${event_id}"

  # 내부 이벤트 발행
  local source event_type
  source=$(echo "$event_json" | jq -r '.source')
  event_type=$(echo "$event_json" | jq -r '.type')
  emit_internal_event "event.detected" "sentinel" \
    "$(jq -n -c --arg eid "$event_id" --arg src "$source" --arg et "$event_type" \
      '{event_id: $eid, source: $src, event_type: $et}')"

  log "[EVENT] [sentinel] Emitted: $event_id ($event_type)"
}

# is_duplicate: 이미 감지된 이벤트인지 확인
is_duplicate() {
  local event_id="$1"
  [[ -f "$BASE_DIR/queue/events/pending/${event_id}.json" ]] ||
  [[ -f "$BASE_DIR/queue/events/dispatched/${event_id}.json" ]] ||
  [[ -f "$BASE_DIR/state/sentinel/seen/${event_id}" ]]
}

# load_state / save_state: watcher별 상태 JSON 관리
load_state() {
  local watcher="$1"
  cat "$BASE_DIR/state/sentinel/${watcher}-state.json" 2>/dev/null || echo '{}'
}

save_state() {
  local watcher="$1"
  local state="$2"
  echo "$state" > "$BASE_DIR/state/sentinel/${watcher}-state.json"
}

# get_interval: watcher의 polling 간격 (초)
get_interval() {
  local watcher="$1"
  get_config "sentinel" "polling.${watcher}.interval_seconds"
}

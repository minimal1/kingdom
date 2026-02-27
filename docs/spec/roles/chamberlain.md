# 내관 (Chamberlain)

> 궁궐 내부를 관리하며, 시스템 상태를 감시하고, 내부 이벤트를 기반으로 이상을 감지한다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `chamberlain` |
| tmux 세션 | `chamberlain` |
| 실행 형태 | Bash 스크립트 (모니터링 loop) |
| 수명 | 상주 (Always-on) |
| 리소스 | 매우 경량 |
| 갱신 주기 | 30초 (config 조정 가능) |

## 책임

- 시스템 리소스(CPU, Memory, Disk) 주기적 모니터링
- 역할별 heartbeat 감시 (파수꾼, 왕, 장군, 사절)
- 내부 이벤트(`logs/events.log`) 소비 → 메트릭 집계 + 이상 감지
- 활성 병사 세션 관리 (`sessions.json` 정리, 고아 세션 kill)
- `state/resources.json` 갱신 (왕이 리소스 기반 작업 수용 판단에 사용)
- 이상 감지 시 사절에게 알림 요청
- 경량 자동 복구 (필수 세션 재시작, 로그 로테이션, 만료 파일 정리)

## 하지 않는 것

- 작업 판단이나 제어 (왕의 책임)
- 외부 시스템 모니터링 (파수꾼의 책임)
- 직접 Slack 발송 (사절의 책임)
- 내부 이벤트의 비즈니스 로직 해석 (이벤트 패턴만 감시)

---

## 핵심 루프

```bash
#!/bin/bash
# bin/chamberlain.sh

source "$BASE_DIR/bin/lib/common.sh"
source "$BASE_DIR/bin/lib/chamberlain/metrics-collector.sh"
source "$BASE_DIR/bin/lib/chamberlain/session-checker.sh"
source "$BASE_DIR/bin/lib/chamberlain/event-consumer.sh"
source "$BASE_DIR/bin/lib/chamberlain/auto-recovery.sh"
source "$BASE_DIR/bin/lib/chamberlain/log-rotation.sh"
source "$BASE_DIR/bin/lib/chamberlain/token-monitor.sh"

INTERVAL=$(get_config "chamberlain" "monitoring.interval_seconds" 30)

emit_internal_event "system.startup" "chamberlain" '{"component": "chamberlain"}'

RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [chamberlain] Shutting down..."; exit 0' SIGTERM SIGINT

start_heartbeat_daemon "chamberlain"

while $RUNNING; do
  # ── 1. 시스템 리소스 수집 ──
  collect_metrics

  # ── 2. 토큰 비용 수집 ──
  collect_token_metrics

  # ── 3. 날짜 변경 감지 + 일일 예산 리셋 ──
  detect_date_change  # 날짜 변경 시 budget reset 이벤트 발행

  # ── 4. Health 판단 + resources.json 갱신 ──
  local prev_health=$(get_current_health)
  local curr_health=$(evaluate_health)
  update_resources_json "$curr_health"

  if [ "$prev_health" != "$curr_health" ]; then
    emit_internal_event "system.health_changed" "chamberlain" \
      "$(jq -n --arg from "$prev_health" --arg to "$curr_health" '{from: $from, to: $to}')"
  fi

  # ── 5. Heartbeat 감시 ──
  check_heartbeats

  # ── 6. 세션 상태 확인 + sessions.json 정리 ──
  check_and_clean_sessions

  # ── 7. 내부 이벤트 소비 ──
  consume_internal_events

  # ── 8. 임계값 확인 → 알림/복구 ──
  check_thresholds_and_act "$curr_health"

  # ── 9. 정기 작업 (로그 로테이션, 만료 파일 정리) ──
  run_periodic_tasks

  sleep "$INTERVAL"
done
```

---

## 핵심 함수 상세

### collect_metrics

```bash
# bin/lib/chamberlain/metrics-collector.sh

collect_metrics() {
  # CPU 사용률
  CPU_PERCENT=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' || echo "0")

  # Memory 사용률
  MEMORY_PERCENT=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}' 2>/dev/null || echo "0")

  # Disk 사용률 (BASE_DIR 파티션)
  DISK_PERCENT=$(df "$BASE_DIR" | tail -1 | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")

  # Load Average
  LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | tr -d ' ')
}
```

### get_current_health

```bash
# 현재 resources.json에서 마지막 판단된 health 레벨 읽기
get_current_health() {
  jq -r '.health // "green"' "$BASE_DIR/state/resources.json" 2>/dev/null || echo "green"
}
```

### evaluate_health

```bash
evaluate_health() {
  local cpu_red=$(get_config "chamberlain" "thresholds.cpu_red" 90)
  local cpu_orange=$(get_config "chamberlain" "thresholds.cpu_orange" 80)
  local cpu_yellow=$(get_config "chamberlain" "thresholds.cpu_yellow" 60)
  local mem_red=$(get_config "chamberlain" "thresholds.memory_red" 90)
  local mem_orange=$(get_config "chamberlain" "thresholds.memory_orange" 80)
  local mem_yellow=$(get_config "chamberlain" "thresholds.memory_yellow" 60)

  if (( $(echo "$CPU_PERCENT > $cpu_red" | bc -l) )) || \
     (( $(echo "$MEMORY_PERCENT > $mem_red" | bc -l) )); then
    echo "red"
  elif (( $(echo "$CPU_PERCENT > $cpu_orange" | bc -l) )) || \
       (( $(echo "$MEMORY_PERCENT > $mem_orange" | bc -l) )); then
    echo "orange"
  elif (( $(echo "$CPU_PERCENT > $cpu_yellow" | bc -l) )) || \
       (( $(echo "$MEMORY_PERCENT > $mem_yellow" | bc -l) )); then
    echo "yellow"
  else
    echo "green"
  fi
}
```

### update_resources_json

```bash
update_resources_json() {
  local health="$1"

  # 활성 병사 수 (sessions.json 기준)
  local soldiers_active=$(jq 'length' "$BASE_DIR/state/sessions.json" 2>/dev/null || echo 0)
  local soldiers_max=$(get_config "king" "concurrency.max_soldiers" 3)

  # 활성 tmux 세션 목록 (디버깅 + 향후 대시보드용 — 현재 왕은 사용하지 않음)
  local session_list=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | jq -R . | jq -s .)

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cpu "$CPU_PERCENT" \
    --arg mem "$MEMORY_PERCENT" \
    --arg disk "$DISK_PERCENT" \
    --arg load "$LOAD_AVG" \
    --arg health "$health" \
    --argjson soldiers_active "$soldiers_active" \
    --argjson soldiers_max "$soldiers_max" \
    --argjson sessions "$session_list" \
    '{
      timestamp: $ts,
      system: {
        cpu_percent: ($cpu | tonumber),
        memory_percent: ($mem | tonumber),
        disk_percent: ($disk | tonumber),
        load_average: ($load | split(",") | map(tonumber))
      },
      sessions: {
        soldiers_active: $soldiers_active,
        soldiers_max: $soldiers_max,
        list: $sessions
      },
      health: $health
    }' > "$BASE_DIR/state/resources.json.tmp"

  mv "$BASE_DIR/state/resources.json.tmp" "$BASE_DIR/state/resources.json"
}
```

> Write-then-Rename: 왕이 resources.json을 읽는 도중 불완전한 파일을 보지 않도록.

### check_heartbeats

```bash
check_heartbeats() {
  local threshold=$(get_config "chamberlain" "heartbeat.threshold_seconds" 120)
  local now=$(date +%s)

  # 감시 대상: 파수꾼, 왕, 사절 + 활성 장군들
  local targets=("sentinel" "king" "envoy")

  # 활성 장군 추가 (config/generals/*.yaml에서 name 필드 추출)
  for manifest in "$BASE_DIR/config/generals/"*.yaml; do
    [ -f "$manifest" ] || continue
    local name=""
    if command -v yq &> /dev/null; then
      name=$(yq eval '.name' "$manifest" 2>/dev/null)
    else
      # yq 미설치 fallback: "name: gen-pr" 패턴을 grep으로 추출
      name=$(grep -m1 '^name:' "$manifest" | sed 's/^name:[[:space:]]*//' | tr -d '"'"'")
    fi
    [ -n "$name" ] && targets+=("$name")
  done

  for target in "${targets[@]}"; do
    local hb_file="$BASE_DIR/state/${target}/heartbeat"

    # heartbeat 파일이 없으면 아직 시작 안 한 것 — 스킵
    [ -f "$hb_file" ] || continue

    local mtime=$(stat -c %Y "$hb_file" 2>/dev/null || stat -f %m "$hb_file" 2>/dev/null)

    # mtime 획득 실패 시 스킵 (플랫폼 비호환 등)
    if [ -z "$mtime" ]; then
      log "[WARN] [chamberlain] Cannot read mtime for $target heartbeat, skipping"
      continue
    fi

    local elapsed=$((now - mtime))

    if (( elapsed > threshold )); then
      log "[WARN] [chamberlain] Heartbeat missed: $target (${elapsed}s > ${threshold}s)"

      emit_internal_event "system.heartbeat_missed" "chamberlain" \
        "$(jq -n --arg target "$target" \
                 --arg last "$(date -u -d @$mtime +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
                 --argjson threshold "$threshold" \
                 '{target: $target, last_seen: $last, threshold_seconds: $threshold}')"

      handle_dead_role "$target"
    fi
  done
}
```

### handle_dead_role

```bash
handle_dead_role() {
  local target="$1"
  local restart_sentinel=$(get_config "chamberlain" "auto_recovery.restart_sentinel" true)

  case "$target" in
    sentinel)
      if [ "$restart_sentinel" = "true" ]; then
        log "[RECOVERY] [chamberlain] Restarting sentinel"
        tmux new-session -d -s sentinel "$BASE_DIR/bin/sentinel.sh"
        emit_internal_event "recovery.session_restarted" "chamberlain" \
          "$(jq -n --arg target "sentinel" '{target: $target}')"
      else
        create_alert_message "sentinel 세션 죽음 감지 — 수동 복구 필요"
      fi
      ;;
    king)
      # 왕은 자동 재시작하지 않음 — 상태 손실 위험
      create_alert_message "[긴급] king 세션 죽음 감지 — 수동 복구 필요"
      ;;
    gen-*)
      # 장군 죽음 → 해당 장군의 병사들도 강제 종료
      kill_soldiers_of_dead_general "$target"
      create_alert_message "$target 세션 죽음 감지 — 소속 병사 정리됨"
      ;;
    *)
      # 사절 등: 알림만
      create_alert_message "$target 세션 죽음 감지 — 확인 필요"
      ;;
  esac
}
```

### kill_soldiers_of_dead_general

장군 crash 시, 해당 장군에게 배정된 in_progress task의 병사 세션을 강제 종료한다.

```bash
kill_soldiers_of_dead_general() {
  local general="$1"
  local killed=0

  for task_file in "$BASE_DIR/queue/tasks/in_progress/"*.json; do
    [ -f "$task_file" ] || continue

    local target_general=$(jq -r '.target_general' "$task_file")
    [ "$target_general" = "$general" ] || continue

    local task_id=$(jq -r '.id' "$task_file")
    local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"

    if [ -f "$soldier_id_file" ]; then
      local soldier_id=$(cat "$soldier_id_file")
      if tmux has-session -t "$soldier_id" 2>/dev/null; then
        tmux kill-session -t "$soldier_id"
        killed=$((killed + 1))
        log "[RECOVERY] [chamberlain] Killed orphan soldier: $soldier_id (general: $general, task: $task_id)"
        emit_internal_event "soldier.killed" "chamberlain" \
          "$(jq -n --arg sid "$soldier_id" --arg reason "general_dead" \
                   '{soldier_id: $sid, reason: $reason}')"
      fi
    fi
  done

  if (( killed > 0 )); then
    log "[RECOVERY] [chamberlain] Killed $killed orphan soldiers of $general"
  fi
}
```

### check_and_clean_sessions

```bash
# bin/lib/chamberlain/session-checker.sh

check_and_clean_sessions() {
  local sessions_file="$BASE_DIR/state/sessions.json"
  [ -f "$sessions_file" ] || return 0

  local lock_file="$BASE_DIR/state/sessions.lock"
  local temp_file="${sessions_file}.tmp"
  local removed=0

  # ── 파일 잠금 획득 ──
  # 장군의 spawn_soldier도 같은 lock_file을 사용 (A1: 경쟁 조건 방지)
  exec 200>"$lock_file"
  flock -x 200

  # 한 줄씩 읽어서 tmux 세션 존재 여부 확인
  while IFS= read -r line; do
    local soldier_id=$(echo "$line" | jq -r '.id')
    local task_id=$(echo "$line" | jq -r '.task_id')

    if tmux has-session -t "$soldier_id" 2>/dev/null; then
      # 살아있는 세션 → 유지
      echo "$line" >> "$temp_file"
    else
      # 죽은 세션 → 제거
      removed=$((removed + 1))
      log "[CLEANUP] [chamberlain] Removed dead session: $soldier_id (task: $task_id)"

      emit_internal_event "system.session_orphaned" "chamberlain" \
        "$(jq -n --arg sid "$soldier_id" --arg tid "$task_id" \
                 '{soldier_id: $sid, task_id: $tid}')"
    fi
  done < "$sessions_file"

  # 원자적 교체
  if [ -f "$temp_file" ]; then
    mv "$temp_file" "$sessions_file"
  else
    # 모든 세션이 제거된 경우
    > "$sessions_file"
  fi

  # ── 잠금 해제 ──
  flock -u 200
  exec 200>&-

  if (( removed > 0 )); then
    emit_internal_event "recovery.sessions_cleaned" "chamberlain" \
      "$(jq -n --argjson count "$removed" '{removed_count: $count}')"
  fi
}
```

---

## 내부 이벤트 소비

내관은 `logs/events.log`를 주기적으로 읽어 메트릭 집계와 이상 감지를 수행한다.

> **소비 보장**: At-least-once. 내관 crash 시 offset 미갱신 상태로 재시작되어 동일 이벤트를 재처리할 수 있다. `aggregate_metrics`의 카운터가 약간 부풀 수 있으나 근사치로 충분하다. 중복 알림은 정보성이므로 허용.

### consume_internal_events

```bash
# bin/lib/chamberlain/event-consumer.sh

# 마지막으로 읽은 위치를 추적
EVENTS_OFFSET_FILE="$BASE_DIR/state/chamberlain/events-offset"

consume_internal_events() {
  local events_file="$BASE_DIR/logs/events.log"
  [ -f "$events_file" ] || return 0

  # 마지막 읽은 라인 번호
  local last_offset=$(cat "$EVENTS_OFFSET_FILE" 2>/dev/null || echo 0)
  local total_lines=$(wc -l < "$events_file")

  # 새 이벤트가 없으면 스킵
  (( total_lines <= last_offset )) && return 0

  # 새 이벤트만 추출 (유효한 JSON만 필터)
  local new_events=$(tail -n +$((last_offset + 1)) "$events_file" | jq -c '.' 2>/dev/null)

  if [ -z "$new_events" ]; then
    # JSON 파싱 실패 → 오프셋만 진행 (손상 이벤트 스킵)
    log "[WARN] [chamberlain] events.log parse error at offset $last_offset, skipping"
    echo "$total_lines" > "$EVENTS_OFFSET_FILE"
    return 0
  fi

  # 메트릭 집계
  aggregate_metrics "$new_events"

  # 이상 감지
  detect_anomalies "$new_events"

  # 오프셋 갱신 (처리 완료 후 — at-least-once 보장)
  echo "$total_lines" > "$EVENTS_OFFSET_FILE"
}
```

### aggregate_metrics

```bash
aggregate_metrics() {
  local events="$1"
  local stats_file="$BASE_DIR/logs/analysis/stats.json"

  # 이번 배치의 이벤트 카운트
  local task_completed=$(echo "$events" | grep -c '"type":"task.completed"' || echo 0)
  local task_failed=$(echo "$events" | grep -c '"type":"task.failed"' || echo 0)
  local soldier_spawned=$(echo "$events" | grep -c '"type":"soldier.spawned"' || echo 0)
  local soldier_timeout=$(echo "$events" | grep -c '"type":"soldier.timeout"' || echo 0)

  # 기존 누적값에 합산 (at-least-once이므로 crash 복구 시 중복 카운트 가능, 근사치)
  local prev=$(cat "$stats_file" 2>/dev/null || echo '{}')

  echo "$prev" | jq \
    --argjson tc "$task_completed" \
    --argjson tf "$task_failed" \
    --argjson ss "$soldier_spawned" \
    --argjson st "$soldier_timeout" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      updated_at: $ts,
      totals: {
        task_completed: ((.totals.task_completed // 0) + $tc),
        task_failed: ((.totals.task_failed // 0) + $tf),
        soldier_spawned: ((.totals.soldier_spawned // 0) + $ss),
        soldier_timeout: ((.totals.soldier_timeout // 0) + $st)
      }
    }' > "${stats_file}.tmp"

  mv "${stats_file}.tmp" "$stats_file"
}
```

### detect_anomalies

```bash
detect_anomalies() {
  local events="$1"

  # ── 패턴 1: 특정 장군의 연속 실패 (3회 이상) ──
  local failure_threshold=$(get_config "chamberlain" "anomaly.consecutive_failures" 3)
  local failed_actors=$(echo "$events" | grep '"type":"task.failed"' | jq -r '.actor' | sort | uniq -c | sort -rn)

  echo "$failed_actors" | while read count actor; do
    if (( count >= failure_threshold )); then
      create_alert_message "[이상 감지] $actor 가 ${count}회 연속 실패"
    fi
  done

  # ── 패턴 2: 병사 타임아웃 급증 (1시간 내 5회 이상) ──
  local timeout_threshold=$(get_config "chamberlain" "anomaly.timeout_spike" 5)
  local one_hour_ago=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  local recent_timeouts=$(echo "$events" | grep '"type":"soldier.timeout"' | \
    jq -r --arg since "$one_hour_ago" 'select(.ts > $since)' | wc -l || echo 0)

  if (( recent_timeouts >= timeout_threshold )); then
    create_alert_message "[이상 감지] 최근 1시간 병사 타임아웃 ${recent_timeouts}회 — 시스템 과부하 의심"
  fi

  # ── 패턴 3: 이벤트 체류 (30분 이상 미처리) ──
  # event.detected 후 event.dispatched가 없는 경우
  local stale_threshold=$(get_config "chamberlain" "anomaly.event_stale_minutes" 30)
  local detected_ids=$(echo "$events" | grep '"type":"event.detected"' | jq -r '.data.event_id')
  local dispatched_ids=$(echo "$events" | grep '"type":"event.dispatched"' | jq -r '.data.event_id')

  for eid in $detected_ids; do
    if ! echo "$dispatched_ids" | grep -q "$eid"; then
      log "[WARN] [chamberlain] Event stale: $eid (detected but not dispatched)"
    fi
  done
}
```

---

## 알림 생성

내관은 직접 Slack을 보내지 않고, `queue/messages/pending/`에 알림 메시지를 생성한다.

```bash
create_alert_message() {
  local content="$1"
  local urgency="${2:-normal}"
  local msg_id="msg-chamberlain-$(date +%s)-$$"

  jq -n \
    --arg id "$msg_id" \
    --arg content "$content" \
    --arg urgency "$urgency" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      type: "notification",
      task_id: null,
      content: $content,
      urgency: $urgency,
      created_at: $ts
    }' > "$BASE_DIR/queue/messages/pending/${msg_id}.json"

  log "[ALERT] [chamberlain] $content"
}
```

### 알림 트리거

| 조건 | urgency | 설명 |
|------|---------|------|
| health `orange` → `red` 전환 | high | 시스템 위험 |
| 필수 세션(king) 죽음 | high | 작업 흐름 중단 |
| 필수 세션(sentinel) 죽음 (자동 재시작 실패 시) | high | 이벤트 감지 중단 |
| 장군 세션 죽음 | normal | 소속 병사 정리 후 알림 |
| 사절 세션 죽음 | normal | 부분 기능 중단 |
| Disk 사용률 > 85% | normal | 디스크 공간 부족 |
| 특정 장군 연속 실패 (3회+) | normal | 도메인 문제 의심 |
| 병사 타임아웃 급증 (1시간 5회+) | normal | 시스템 과부하 의심 |

---

## 자동 복구

```bash
# bin/lib/chamberlain/auto-recovery.sh

check_thresholds_and_act() {
  local health="$1"

  # ── health red: 긴급 알림 ──
  if [ "$health" = "red" ]; then
    create_alert_message "[긴급] 시스템 health RED — CPU: ${CPU_PERCENT}%, MEM: ${MEMORY_PERCENT}%" "high"
  fi

  # ── Disk 경고 ──
  local disk_warn=$(get_config "chamberlain" "thresholds.disk_warning" 85)
  if (( $(echo "$DISK_PERCENT > $disk_warn" | bc -l) )); then
    create_alert_message "Disk 사용률 ${DISK_PERCENT}% — 임계값 ${disk_warn}% 초과"
  fi
}
```

### 자동 복구 행동표

| 상황 | 행동 | 이벤트 |
|------|------|--------|
| sentinel 세션 죽음 | 자동 재시작 (`bin/sentinel.sh`) | `recovery.session_restarted` |
| king 세션 죽음 | 알림만 (상태 손실 위험) | — |
| 장군(gen-*) 세션 죽음 | 소속 병사 kill + 알림 (`kill_soldiers_of_dead_general`) | `soldier.killed` |
| 사절 세션 죽음 | 알림만 | — |
| 고아 병사 세션 (tmux 없는데 sessions.json에 존재) | sessions.json에서 제거 (flock) | `recovery.sessions_cleaned` |
| 로그 파일 100MB 초과 | .old로 로테이션 | `recovery.log_rotated` |
| 만료 파일 (로그, 결과, 큐, 프롬프트, seen) | 보존 기간 경과 후 삭제 | `recovery.files_cleaned` |

---

## 정기 작업

```bash
# bin/lib/chamberlain/log-rotation.sh

run_periodic_tasks() {
  local now_hour=$(date +%H)
  local now_min=$(date +%M)

  # ── 로그 로테이션 (매 루프 체크, 크기 기반) ──
  rotate_logs_if_needed

  # ── 만료 파일 정리 (매일 03:00) ──
  if [ "$now_hour" = "03" ] && [ "$now_min" = "00" ] && should_run_daily "cleanup"; then
    cleanup_expired_files
  fi

  # ── events.log 일별 분할 (매일 00:00) ──
  if [ "$now_hour" = "00" ] && [ "$now_min" = "00" ] && should_run_daily "events-rotation"; then
    rotate_events_log
  fi
}

# 정기 작업 일별 중복 실행 방지
# interval=30초이므로 같은 분에 2회 매칭될 수 있음 → marker 파일로 방지
should_run_daily() {
  local task_name="$1"
  local marker="$BASE_DIR/state/chamberlain/daily-${task_name}"
  local today=$(date +%Y-%m-%d)

  local last_run=$(cat "$marker" 2>/dev/null || echo "")
  if [ "$last_run" = "$today" ]; then
    return 1  # 오늘 이미 실행됨
  fi

  echo "$today" > "$marker"
  return 0
}

rotate_logs_if_needed() {
  local max_mb=$(get_config "chamberlain" "retention.log_max_mb" 100)
  local max_bytes=$((max_mb * 1024 * 1024))

  for logfile in "$BASE_DIR/logs/"*.log; do
    [ -f "$logfile" ] || continue
    [[ "$logfile" == *events-*.log ]] && continue  # 일별 분할 파일은 스킵

    local size=$(stat -c %s "$logfile" 2>/dev/null || stat -f %z "$logfile" 2>/dev/null || echo 0)

    if (( size > max_bytes )); then
      local basename=$(basename "$logfile")
      # .old로 로테이션 (이전 .old는 cleanup_expired_files가 삭제)
      # mv 후 touch 사이에 다른 역할이 >> 하면 bash가 자동 생성 → 로그 손실 없음
      mv "$logfile" "${logfile}.old"
      touch "$logfile"

      emit_internal_event "recovery.log_rotated" "chamberlain" \
        "$(jq -n --arg file "$basename" --argjson size_mb "$((size / 1024 / 1024))" \
                 '{file: $file, size_mb: $size_mb}')"

      log "[ROTATION] [chamberlain] Rotated: $basename (${size}MB → .old)"
    fi
  done
}

cleanup_expired_files() {
  local log_days=$(get_config "chamberlain" "retention.logs_days" 7)
  local result_days=$(get_config "chamberlain" "retention.results_days" 7)
  local queue_days=$(get_config "chamberlain" "retention.queue_days" 7)
  local prompt_days=$(get_config "chamberlain" "retention.prompts_days" 3)
  local session_log_days=$(get_config "chamberlain" "retention.session_logs_days" 7)
  local seen_days=$(get_config "chamberlain" "retention.seen_days" 30)

  local total=0

  # ── 로그 ──
  # .old 로테이션 파일
  total=$((total + $(find "$BASE_DIR/logs/" -maxdepth 1 -name "*.old" -mtime +"$log_days" -delete -print 2>/dev/null | wc -l)))
  # 내부 이벤트 일별 분할 파일 (events-YYYYMMDD.log)
  total=$((total + $(find "$BASE_DIR/logs/" -maxdepth 1 -name "events-*.log" -mtime +"$log_days" -delete -print 2>/dev/null | wc -l)))
  # 병사 세션 로그
  total=$((total + $(find "$BASE_DIR/logs/sessions/" -name "*.log" -mtime +"$session_log_days" -delete -print 2>/dev/null | wc -l)))

  # ── 상태 파일 ──
  # 결과 파일 (.json) + soldier-id 파일
  total=$((total + $(find "$BASE_DIR/state/results/" -type f -mtime +"$result_days" -delete -print 2>/dev/null | wc -l)))
  # 임시 프롬프트
  total=$((total + $(find "$BASE_DIR/state/prompts/" -type f -mtime +"$prompt_days" -delete -print 2>/dev/null | wc -l)))

  # ── 큐 완료 파일 ──
  for subdir in "events/completed" "tasks/completed" "messages/sent"; do
    total=$((total + $(find "$BASE_DIR/queue/$subdir/" -type f -mtime +"$queue_days" -delete -print 2>/dev/null | wc -l)))
  done

  # ── 파수꾼 중복 방지 인덱스 ──
  total=$((total + $(find "$BASE_DIR/state/sentinel/seen/" -type f -mtime +"$seen_days" -delete -print 2>/dev/null | wc -l)))

  if (( total > 0 )); then
    emit_internal_event "recovery.files_cleaned" "chamberlain" \
      "$(jq -n --argjson count "$total" '{deleted_count: $count}')"
    log "[CLEANUP] [chamberlain] Deleted $total expired files"
  fi
}

rotate_events_log() {
  local events_file="$BASE_DIR/logs/events.log"
  [ -f "$events_file" ] || return 0

  local yesterday=$(date -d 'yesterday' +%Y%m%d 2>/dev/null || date -v-1d +%Y%m%d)

  # logs/ 디렉토리에 일별 파일로 분할 (cleanup_expired_files가 보존 기간 후 삭제)
  # mv → touch 사이에 다른 역할이 emit_internal_event 시 >> 가 자동 생성하므로 이벤트 손실 없음
  mv "$events_file" "$BASE_DIR/logs/events-${yesterday}.log"
  touch "$events_file"

  # 오프셋 리셋 (새 파일이므로 0부터)
  # 타이밍: mv 후 offset 리셋 전에 다른 역할이 새 파일에 emit 가능
  # → 리셋 시점에 이미 1-2줄이 있을 수 있으나, 다음 consume에서 정상 처리됨
  echo "0" > "$BASE_DIR/state/chamberlain/events-offset"

  log "[ROTATION] [chamberlain] Events log rotated: events-${yesterday}.log"
}
```

---

## 토큰 비용 모니터링

Claude Code의 `~/.claude/stats-cache.json`에서 일일 토큰 사용량을 읽어 비용을 추산하고, 예산 대비 상태를 평가한다.

```bash
# bin/lib/chamberlain/token-monitor.sh

TOKEN_STATUS="ok"           # ok, warning, critical, unknown
DAILY_INPUT_TOKENS=0
DAILY_OUTPUT_TOKENS=0
ESTIMATED_DAILY_COST="0"

collect_token_metrics() {
  # 비활성화 시 즉시 반환
  local enabled=$(get_config "chamberlain" "token_limits.enabled" "true")
  [[ "$enabled" != "true" ]] && return 0

  # stats-cache.json에서 오늘 날짜 토큰 합산
  local today=$(date +%Y-%m-%d)
  local daily_total_tokens=$(jq -r --arg date "$today" '
    .dailyModelTokens[]? | select(.date == $date) | .tokensByModel
    | to_entries[] | .value
  ' "$HOME/.claude/stats-cache.json" 2>/dev/null | awk '{s+=$1} END {print s+0}')

  # 입출력 비율 추정 (70% input, 30% output)
  DAILY_INPUT_TOKENS=$(echo "$daily_total_tokens * 0.7" | bc | awk '{printf "%.0f", $0}')
  DAILY_OUTPUT_TOKENS=$(echo "$daily_total_tokens * 0.3" | bc | awk '{printf "%.0f", $0}')

  # 비용 추산
  estimate_daily_cost

  # 상태 평가
  evaluate_token_status
}
```

### estimate_daily_cost

```bash
estimate_daily_cost() {
  local input_price=$(get_config "chamberlain" "pricing.input_per_mtok" "15.0")
  local output_price=$(get_config "chamberlain" "pricing.output_per_mtok" "75.0")

  ESTIMATED_DAILY_COST=$(echo "scale=2; ($DAILY_INPUT_TOKENS * $input_price + $DAILY_OUTPUT_TOKENS * $output_price) / 1000000" | bc)
}
```

### evaluate_token_status

```bash
evaluate_token_status() {
  local daily_budget=$(get_config "chamberlain" "token_limits.daily_budget_usd" "300")
  local warning_pct=$(get_config "chamberlain" "token_limits.warning_pct" "70")
  local critical_pct=$(get_config "chamberlain" "token_limits.critical_pct" "90")

  local warning_threshold=$(echo "scale=2; $daily_budget * $warning_pct / 100" | bc)
  local critical_threshold=$(echo "scale=2; $daily_budget * $critical_pct / 100" | bc)

  if (( $(echo "$ESTIMATED_DAILY_COST >= $critical_threshold" | bc -l) )); then
    TOKEN_STATUS="critical"
  elif (( $(echo "$ESTIMATED_DAILY_COST >= $warning_threshold" | bc -l) )); then
    TOKEN_STATUS="warning"
  else
    TOKEN_STATUS="ok"
  fi
}
```

### detect_date_change

일일 예산 리셋 감지. 날짜가 바뀌면 `system.token_budget_reset` 이벤트를 발행한다.

```bash
detect_date_change() {
  local last_date_file="$BASE_DIR/state/last_token_date.txt"
  local today=$(date +%Y-%m-%d)

  local last_date=$(cat "$last_date_file" 2>/dev/null || echo "")
  if [[ "$today" != "$last_date" ]] && [[ -n "$last_date" ]]; then
    echo "$today" > "$last_date_file"
    return 0  # Date changed
  fi

  echo "$today" > "$last_date_file"
  return 1  # No change or first run
}
```

### 토큰 상태 레벨

| 상태 | 조건 | 왕의 행동 |
|------|------|----------|
| `ok` | 비용 < 예산 × 70% | 정상 — health 기반 판단만 |
| `warning` | 비용 ≥ 예산 × 70% | high 우선순위 또는 green일 때만 수용 |
| `critical` | 비용 ≥ 예산 × 90% | high 우선순위만 수용 |
| `unknown` | stats-cache.json 없음/파싱 실패 | ok로 취급 (안전 기본값) |

> 왕의 `can_accept_task(health, priority, token_status)` 함수가 토큰 상태를 3번째 인자로 받는다. 상세: [roles/king.md](king.md)

### resources.json 토큰 필드

`update_resources_json`에서 토큰 관련 필드가 추가된다:

```json
{
  "tokens": {
    "status": "ok",
    "daily_cost_usd": "12.50",
    "daily_input_tokens": 500000,
    "daily_output_tokens": 214285
  }
}
```

---

## Health 판단 기준

| Health | 조건 | 의미 | 왕의 행동 |
|--------|------|------|----------|
| `green` | CPU < 60% AND Memory < 60% | 정상 | 모든 우선순위 작업 수용 |
| `yellow` | CPU 60-80% OR Memory 60-80% | 주의 | high 우선순위만 수용 |
| `orange` | CPU > 80% OR Memory > 80% | 경고 | 신규 작업 중단 |
| `red` | CPU > 90% OR Memory > 90% | 위험 | 긴급 정리, 알림 |

> 왕의 `can_accept_task` 함수가 `state/resources.json`의 health 값을 읽어 판단. 왕은 `timestamp`를 검증하여 120초 이상 미갱신 시 내관 crash로 판단하고 `orange`를 반환한다. 상세: [roles/king.md](king.md)

---

## 모니터링 대상

### 시스템 리소스

| 지표 | 수집 방법 | 단위 | 갱신 주기 |
|------|----------|------|----------|
| CPU 사용률 | `top -bn1` | % | 30초 |
| Memory 사용률 | `free` | % | 30초 |
| Disk 사용률 | `df` | % | 30초 |
| Load Average | `uptime` | 1/5/15min | 30초 |

### Heartbeat 감시

| 대상 | heartbeat 파일 | 갱신 주체 | 정상 간격 | 임계값 |
|------|---------------|----------|----------|--------|
| 파수꾼 | `state/sentinel/heartbeat` | sentinel.sh | 매 폴링 주기 | 120초 |
| 왕 | `state/king/heartbeat` | king.sh | 매 루프 주기 | 120초 |
| 장군 | `state/{general}/heartbeat` | gen-*.sh | 매 루프 주기 | 120초 |
| 사절 | `state/envoy/heartbeat` | envoy.sh | 매 루프 주기 | 120초 |

> heartbeat 파일의 mtime이 임계값을 초과하면 해당 역할이 죽은 것으로 판단.

### 세션 상태

| 대상 | 확인 방법 | 주기 |
|------|----------|------|
| 필수 세션 (sentinel, king, envoy) | `tmux has-session` | 30초 |
| 장군 세션 | `tmux has-session` | 30초 |
| 병사 세션 (sessions.json) | `tmux has-session` + 정리 | 30초 |

---

## 상태 파일 스키마

### state/resources.json

```json
{
  "timestamp": "2026-02-07T10:00:00Z",
  "system": {
    "cpu_percent": 45.2,
    "memory_percent": 62.1,
    "disk_percent": 34.5,
    "load_average": [1.2, 0.8, 0.6]
  },
  "sessions": {
    "soldiers_active": 2,
    "soldiers_max": 3,
    "list": ["sentinel", "king", "gen-pr", "soldier-001", "soldier-002"]
  },
  "health": "green"
}
```

### state/chamberlain/events-offset

```
1523
```

내관이 `logs/events.log`에서 마지막으로 읽은 라인 번호. 새 이벤트만 읽기 위한 커서.

### logs/analysis/stats.json

```json
{
  "updated_at": "2026-02-07T10:00:00Z",
  "totals": {
    "task_completed": 45,
    "task_failed": 3,
    "soldier_spawned": 48,
    "soldier_timeout": 2
  }
}
```

---

## 장애 대응

| 상황 | 감지 방법 | 행동 |
|------|----------|------|
| 내관 자신 crash | `start.sh`의 watchdog loop | tmux 세션 재생성 (아래 상세) |
| events.log 손상 | JSON 파싱 실패 | 오프셋 진행 (손상 구간 스킵), 에러 로그. `consume_internal_events` 코드 참조 |
| resources.json 쓰기 실패 | mv 실패 | 에러 로그, 다음 주기에 재시도 |
| sessions.json 동시 접근 | 장군과 동시 append/read | `flock -x`로 상호 배제. 장군(append)과 내관(정리) 모두 `state/sessions.lock` 사용 |
| yq 미설치 | manifest 파싱 실패 | grep fallback으로 `name:` 필드 추출 (yq 불필요) |
| 디스크 풀 | 로그/결과 쓰기 실패 | 긴급 알림 (이미 생성된 메시지로), 로그 로테이션 즉시 실행 |

### 내관 자체 복구: start.sh watchdog

내관은 다른 역할을 감시하지만 자기 자신은 감시할 수 없다. `bin/start.sh`에 60초 주기 watchdog loop를 포함하여, 내관 세션이 죽으면 재생성한다.

```bash
# bin/start.sh 내 watchdog (발췌)

# 필수 세션 목록 — 내관 포함
ESSENTIAL_SESSIONS=("sentinel" "king" "envoy" "chamberlain")

watchdog_loop() {
  while true; do
    for session in "${ESSENTIAL_SESSIONS[@]}"; do
      if ! tmux has-session -t "$session" 2>/dev/null; then
        log "[WATCHDOG] Restarting dead session: $session"
        tmux new-session -d -s "$session" "$BASE_DIR/bin/${session}.sh"
      fi
    done
    sleep 60
  done
}
```

> start.sh의 watchdog은 tmux 세션 존재 여부만 확인하는 최소 로직이다. 내관의 heartbeat 기반 정밀 감시와 달리, 프로세스 생존 확인만 수행한다. start.sh 자체는 OS 레벨(systemd 또는 nohup)로 보호한다.

---

## 설정

```yaml
# config/chamberlain.yaml
monitoring:
  interval_seconds: 30

heartbeat:
  threshold_seconds: 120       # heartbeat mtime 초과 시 죽음 판단

thresholds:
  cpu_yellow: 60
  cpu_orange: 80
  cpu_red: 90
  memory_yellow: 60
  memory_orange: 80
  memory_red: 90
  disk_warning: 85

anomaly:
  consecutive_failures: 3       # 장군 연속 실패 감지 임계값
  timeout_spike: 5              # 1시간 내 타임아웃 급증 임계값
  event_stale_minutes: 30       # 이벤트 미처리 체류 시간

auto_recovery:
  restart_sentinel: true        # 파수꾼 자동 재시작
  restart_others: false         # 다른 역할은 알림만

retention:
  log_max_mb: 100               # 로그 파일 크기 상한 (초과 시 .old 로테이션)
  logs_days: 7                  # .old 파일, events-*.log 보존 기간
  results_days: 7               # state/results/ 파일 보존 기간
  queue_days: 7                 # queue/*/completed/, messages/sent/ 보존 기간
  prompts_days: 3               # state/prompts/ 임시 프롬프트 보존 기간
  session_logs_days: 7          # logs/sessions/ 병사 로그 보존 기간
  seen_days: 30                 # state/sentinel/seen/ 중복 방지 인덱스 보존 기간

events_rotation:
  hour: 0                       # events.log 일별 분할 시각 (00:00)

token_limits:
  enabled: true
  daily_budget_usd: 300         # 일일 비용 예산 (USD)
  warning_pct: 70               # Warning 임계값 (예산의 70%)
  critical_pct: 90              # Critical 임계값 (예산의 90%)
  monitoring_interval_seconds: 60

pricing:
  input_per_mtok: 15.0          # 입력 토큰 가격 ($/1M tokens)
  output_per_mtok: 75.0         # 출력 토큰 가격 ($/1M tokens)
  cache_read_per_mtok: 1.5      # 캐시 읽기 가격 ($/1M tokens)
```

---

## 스크립트 위치

```
bin/chamberlain.sh                          # 메인 모니터링 loop
bin/lib/chamberlain/
├── metrics-collector.sh                    # collect_metrics, evaluate_health,
│                                           # update_resources_json
├── session-checker.sh                      # check_heartbeats, handle_dead_role,
│                                           # kill_soldiers_of_dead_general,
│                                           # check_and_clean_sessions
├── event-consumer.sh                       # consume_internal_events,
│                                           # aggregate_metrics, detect_anomalies
├── auto-recovery.sh                        # check_thresholds_and_act,
│                                           # create_alert_message
├── token-monitor.sh                        # collect_token_metrics, estimate_daily_cost,
│                                           # evaluate_token_status, detect_date_change
└── log-rotation.sh                         # run_periodic_tasks, should_run_daily,
                                            # rotate_logs_if_needed, cleanup_expired_files,
                                            # rotate_events_log
```

---

## 관련 문서

- [systems/internal-events.md](../systems/internal-events.md) — 내부 이벤트 카탈로그 (이벤트 타입 정의)
- [systems/filesystem.md](../systems/filesystem.md) — 파일 시스템 구조 (logs/, state/)
- [roles/king.md](king.md) — 왕 (resources.json 소비자, health 기반 작업 수용 판단)
- [roles/soldier.md](soldier.md) — 병사 (sessions.json 생명주기)
- [roles/envoy.md](envoy.md) — 사절 (알림 메시지 소비자)

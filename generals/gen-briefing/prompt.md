# Kingdom Briefing Task

Kingdom 시스템 상태를 수집하여 브리핑 메시지를 작성하라.

## 1단계: 상태 수집

Bash 도구로 아래 정보를 수집한다. 각 명령이 실패해도 계속 진행한다.

### 역할별 heartbeat (정상 = mtime이 현재 시간 기준 120초 이내)

```bash
for role in king sentinel envoy chamberlain; do
  hb="$KINGDOM_BASE_DIR/state/${role}/heartbeat"
  if [ -f "$hb" ]; then
    mtime=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    echo "${role}: age=${age}s $([ $age -le 120 ] && echo OK || echo DOWN)"
  else
    echo "${role}: NO_HEARTBEAT"
  fi
done
```

### 장군별 heartbeat

```bash
for hb in $KINGDOM_BASE_DIR/state/gen-*/heartbeat; do
  [ -f "$hb" ] || continue
  gen=$(basename "$(dirname "$hb")")
  mtime=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mtime ))
  echo "${gen}: age=${age}s $([ $age -le 120 ] && echo OK || echo DOWN)"
done
```

### 큐 현황

```bash
echo "pending_events: $(ls $KINGDOM_BASE_DIR/queue/events/pending/*.json 2>/dev/null | wc -l | tr -d ' ')"
echo "pending_tasks: $(ls $KINGDOM_BASE_DIR/queue/tasks/pending/*.json 2>/dev/null | wc -l | tr -d ' ')"
echo "in_progress_tasks: $(ls $KINGDOM_BASE_DIR/queue/tasks/in_progress/*.json 2>/dev/null | wc -l | tr -d ' ')"
```

### 활성 병사 수

```bash
cat $KINGDOM_BASE_DIR/state/sessions.json 2>/dev/null | jq 'length' || echo 0
```

### 리소스 상태 (resources.json)

내관이 수집한 시스템 리소스와 토큰 사용량을 파싱한다.

```bash
RES="$KINGDOM_BASE_DIR/state/resources.json"
if [ -f "$RES" ]; then
  echo "=== System ==="
  jq -r '"cpu: \(.system.cpu_percent)% | mem: \(.system.memory_percent)% | disk: \(.system.disk_percent)%"' "$RES"
  jq -r '"load: \(.system.load_average | map(tostring) | join(", "))"' "$RES"
  echo "=== Tokens ==="
  jq -r '"status: \(.tokens.status) | daily_cost: $\(.tokens.daily_cost_usd)"' "$RES"
  jq -r '"input: \(.tokens.daily_input_tokens) | output: \(.tokens.daily_output_tokens)"' "$RES"
  echo "=== Health ==="
  jq -r '.health' "$RES"
else
  echo "(resources.json not found)"
fi
```

### 최근 완료 작업 (최대 3건)

```bash
for f in $(ls -t $KINGDOM_BASE_DIR/queue/tasks/completed/*.json 2>/dev/null | head -3); do
  jq -r '[.id, .type, .target_general] | join(" | ")' "$f"
done
```

### 최근 시스템 로그 (20줄)

```bash
tail -20 $KINGDOM_BASE_DIR/logs/system.log 2>/dev/null || echo "(no log)"
```

## 2단계: 브리핑 작성

수집한 정보로 브리핑 텍스트를 작성한다. 아래 섹션으로 구분한다:

```
(시간 인사), Boss. Kingdom 브리핑입니다.

▸ System Status
  king · sentinel · envoy: ✅
  chamberlain: ⚠️ no heartbeat — 확인이 필요합니다, Boss.

▸ Resources
  CPU 12.3% · Memory 67.1% · Disk 42% · Health 🟢
  Token: $12.50 spent today (status: ok)

▸ Queue
  대기 이벤트 0 · 대기 작업 1 · 진행 중 0 · 병사 0/3

▸ Recent Activity
  task-20260212-001 | briefing | gen-briefing
  task-20260212-002 | github.pr.review_requested | gen-pr

▸ Heads Up
  (이상 없으면 "All clear, Boss." 로 표시)

— F.R.I.D.A.Y. · Kingdom Autonomous Dev Agent
```

**Resources 표시 규칙**:
- Health: green=🟢, yellow=🟡, orange=🟠, red=🔴
- Token status가 warning이면 ⚠️, critical이면 🚨 아이콘 추가
- resources.json이 없으면 "데이터 수집 대기 중" 표시

**Heads Up 기준**: heartbeat DOWN, health가 green이 아닌 경우, 토큰 status가 ok가 아닌 경우, 에러 로그가 있는 경우 등을 간결하게 기재한다. 없으면 "All clear, Boss."

## 3단계: 결과 보고

**summary에 브리핑 텍스트를 넣어** 결과를 보고한다.
왕이 summary를 사절에게 전달하여 Slack 스레드 답글로 전송한다.

```bash
BRIEFING="(2단계에서 작성한 브리핑 텍스트)"

jq -n --arg tid "$KINGDOM_TASK_ID" --arg summary "$BRIEFING" '{
  task_id: $tid,
  status: "success",
  summary: $summary,
  memory_updates: []
}' > "$KINGDOM_RESULT_PATH"
```

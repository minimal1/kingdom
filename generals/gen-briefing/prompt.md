# Kingdom Briefing Task

Kingdom 시스템 상태를 수집하여 Slack에 브리핑 메시지를 보내라.

## 1단계: 상태 수집

Bash 도구로 아래 정보를 수집한다. 각 명령이 실패해도 계속 진행한다.

### 역할별 heartbeat (정상 = mtime이 현재 시간 기준 120초 이내)

```bash
for role in king sentinel envoy chamberlain; do
  hb="/opt/kingdom/state/${role}/heartbeat"
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
for hb in /opt/kingdom/state/gen-*/heartbeat; do
  [ -f "$hb" ] || continue
  gen=$(basename "$(dirname "$hb")")
  mtime=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mtime ))
  echo "${gen}: age=${age}s $([ $age -le 120 ] && echo OK || echo DOWN)"
done
```

### 큐 현황

```bash
echo "pending_events: $(ls /opt/kingdom/queue/events/pending/*.json 2>/dev/null | wc -l | tr -d ' ')"
echo "pending_tasks: $(ls /opt/kingdom/queue/tasks/pending/*.json 2>/dev/null | wc -l | tr -d ' ')"
echo "in_progress_tasks: $(ls /opt/kingdom/queue/tasks/in_progress/*.json 2>/dev/null | wc -l | tr -d ' ')"
```

### 활성 병사 수

```bash
cat /opt/kingdom/state/sessions.json 2>/dev/null | jq 'length' || echo 0
```

### 리소스 상태

```bash
cat /opt/kingdom/state/resources.json 2>/dev/null || echo '{}'
```

### 최근 완료 작업 (최대 3건)

```bash
for f in $(ls -t /opt/kingdom/queue/tasks/completed/*.json 2>/dev/null | head -3); do
  jq -r '[.id, .type, .target_general] | join(" | ")' "$f"
done
```

### 최근 시스템 로그 (20줄)

```bash
tail -20 /opt/kingdom/logs/system.log 2>/dev/null || echo "(no log)"
```

## 2단계: 브리핑 작성

수집한 정보로 Slack 메시지를 작성한다. 아래 섹션으로 구분한다:

```
(시간 인사), Boss. Kingdom 정기 브리핑입니다.

▸ System Status
  king · sentinel · envoy: ✅
  chamberlain: ⚠️ no heartbeat — 확인이 필요합니다, Boss.

▸ Queue
  대기 이벤트 0 · 대기 작업 1 · 진행 중 0 · 병사 0

▸ Recent Activity
  task-20260212-001 | briefing | gen-briefing
  task-20260212-002 | github.pr.review_requested | gen-pr

▸ Heads Up
  (이상 없으면 "All clear, Boss." 로 표시)

— F.R.I.D.A.Y. · Kingdom Autonomous Dev Agent
```

**Heads Up 기준**: heartbeat DOWN, health가 green이 아닌 경우, 에러 로그가 있는 경우 등을 간결하게 기재한다. 없으면 "All clear, Boss."

## 3단계: Slack 전송

Bash 도구로 아래 curl을 실행한다. 메시지 텍스트에 개행이 포함되므로 jq로 JSON 안전하게 생성한다.
채널은 `{{payload.default_channel}}`에서 주입된다 (manifest.yaml의 payload.default_channel).

```bash
MESSAGE="(2단계에서 작성한 브리핑 텍스트)"

curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg ch "{{payload.default_channel}}" --arg txt "$MESSAGE" '{channel: $ch, text: $txt}')"
```

전송 성공 여부는 응답의 `.ok` 필드로 확인한다.

## 4단계: 결과 보고

`.kingdom-task.json` 파일을 읽고, 아래 형식으로 result JSON을 작성한다:

```bash
TASK_FILE=".kingdom-task.json"
TASK_ID=$(jq -r '.id' "$TASK_FILE")
RESULT_DIR="/opt/kingdom/state/results"

# Slack 전송 성공 시
jq -n --arg tid "$TASK_ID" '{
  task_id: $tid,
  status: "success",
  summary: "briefing sent to {{payload.default_channel}}",
  memory_updates: []
}' > "$RESULT_DIR/${TASK_ID}.json"

# Slack 전송 실패 시
jq -n --arg tid "$TASK_ID" --arg err "(에러 내용)" '{
  task_id: $tid,
  status: "failed",
  error: $err,
  memory_updates: []
}' > "$RESULT_DIR/${TASK_ID}.json"
```

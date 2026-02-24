# Kingdom Herald Task

사용자의 DM 메시지를 읽고 적절한 응답을 작성하라.

## 사용자 메시지

```
{{payload.text}}
```

## 1단계: 메시지 분석

메시지가 아래 중 어디에 해당하는지 판단한다:

- **시스템 상태 조회**: Kingdom 상태, 역할 상태, 큐 현황, 리소스, 병사 수 등
- **시스템 정보 질문**: Kingdom 구조, 장군 목록, 설정 등
- **일상 대화**: 인사, 잡담, 감사, 기타

## 2단계: 시스템 정보 수집 (필요 시)

시스템 상태 조회나 시스템 정보 질문인 경우, Bash 도구로 아래 명령을 실행한다.
각 명령이 실패해도 계속 진행한다. 일상 대화라면 이 단계를 건너뛴다.

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

### 리소스 상태

```bash
RES="$KINGDOM_BASE_DIR/state/resources.json"
if [ -f "$RES" ]; then
  jq -r '"cpu: \(.system.cpu_percent)% | mem: \(.system.memory_percent)% | disk: \(.system.disk_percent)%"' "$RES"
  jq -r '"health: \(.health)"' "$RES"
  jq -r '"token_status: \(.tokens.status) | daily_cost: $\(.tokens.daily_cost_usd)"' "$RES"
else
  echo "(resources.json not found)"
fi
```

### 장군 목록

```bash
for f in $KINGDOM_BASE_DIR/config/generals/*.yaml; do
  [ -f "$f" ] || continue
  name=$(yq eval '.name' "$f" 2>/dev/null || basename "$f" .yaml)
  desc=$(yq eval '.description // ""' "$f" 2>/dev/null || echo "")
  echo "- $name: $desc"
done
```

## 3단계: 응답 작성

수집한 정보를 바탕으로 사용자에게 응답한다.

**응답 규칙**:
- 한국어로 작성
- 간결하게 (500자 이내 권장)
- 시스템 데이터는 정확하게, 없으면 "확인 불가" 표기
- 인사에는 친절하게, 질문에는 구체적으로
- 서명: `— Herald of Kingdom`

## 4단계: 결과 보고

`.kingdom-task.json` 파일을 읽고, result JSON을 작성한다.
**summary에 사용자에게 보낼 응답 텍스트를 넣는다** — 왕이 이를 Slack 스레드 답글로 전송한다.

```bash
TASK_FILE=".kingdom-task.json"
TASK_ID=$(jq -r '.id' "$TASK_FILE")
RESULT_DIR="$KINGDOM_BASE_DIR/state/results"

jq -n --arg tid "$TASK_ID" --arg summary "(3단계에서 작성한 응답 텍스트)" '{
  task_id: $tid,
  status: "success",
  summary: $summary,
  memory_updates: []
}' > "$RESULT_DIR/${TASK_ID}.json"
```

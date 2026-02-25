# 파수꾼 (Sentinel)

> 궁궐 외부를 경계하며, 외부 세계의 변화를 왕에게 전달한다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `sentinel` |
| tmux 세션 | `sentinel` |
| 실행 형태 | Bash 스크립트 (polling loop) |
| 수명 | 상주 (Always-on) |
| 리소스 | 경량 (대부분 sleep 상태) |

## 책임

- 외부 개발 도구(GitHub, Jira)의 변화를 주기적으로 감지
- 감지된 이벤트를 표준 형식(JSON)으로 변환하여 이벤트 큐에 적재
- 중복 이벤트 필터링 (동일 이벤트 재감지 방지)

## 하지 않는 것

- 이벤트의 우선순위 판단 (왕의 책임)
- 작업 실행 또는 배정 (왕의 책임)
- 이벤트 내용 해석 (원본 데이터를 그대로 전달)
- **Slack 모니터링 (사절의 책임)** — Slack은 사람과의 소통 채널이므로 사절이 양방향 전담

## 감지 대상 & Polling 주기

| 소스 | 감지 도구 | 주기 | 감지 대상 |
|------|----------|------|----------|
| GitHub | `gh api` (GitHub CLI) | 60초 | Notifications (review_requested, mention, assign 등) |
| Jira | `curl` + REST API | 300초 | 할당된 티켓, 상태 변경, 코멘트 |

---

## Watcher 추상화 레이어

새 외부 서비스를 추가할 때 일관된 패턴을 유지하기 위해, 모든 watcher는 동일한 4단계 인터페이스를 구현한다.

### 인터페이스: `fetch → parse → emit → post_emit`

```
┌───────────┐     ┌───────────┐     ┌───────────┐     ┌──────────────┐
│  fetch()  │────→│  parse()  │────→│  emit()   │────→│ post_emit()  │
│           │     │           │     │           │     │  (optional)  │
│ 외부 API  │     │ raw → 표준 │     │ 이벤트 큐 │     │ 후처리       │
│ 호출      │     │ 이벤트 변환│     │ 에 적재   │     │ (읽음 처리 등)│
└───────────┘     └───────────┘     └───────────┘     └──────────────┘
   ↑ 내부 구현은 자유           공통 함수 (watcher-common.sh)
   (gh, curl, etc.)
```

각 단계의 책임:

| 단계 | 책임 | 입력 | 출력 |
|------|------|------|------|
| `fetch` | 외부 API 호출, raw 데이터 수집 | state 파일 (마지막 체크 시점) | raw JSON |
| `parse` | raw 데이터를 표준 이벤트 스키마로 변환 | raw JSON | 표준 이벤트 배열 (JSON) |
| `emit` | 이벤트를 큐에 적재 + state 갱신 | 표준 이벤트 배열 | queue/events/pending/ 에 파일 생성 |
| `post_emit` | (선택) emit 후 후처리 (예: 알림 읽음 처리) | state 파일 | 외부 API 호출 (side effect) |

### 공통 함수 (`watcher-common.sh`)

모든 watcher가 공유하는 유틸리티. `common.sh`의 공통 함수를 기반으로, 파수꾼 전용 기능을 추가한다.

> `log()`, `get_config()`, `update_heartbeat()`, `start_heartbeat_daemon()`, `stop_heartbeat_daemon()`, 기본 `emit_event()`는 `bin/lib/common.sh`에 정의.

```bash
# common.sh에서 제공하는 함수 (모든 역할 공통):
#   log()              — 구조화 로그
#   get_config()       — YAML 설정 읽기 (get_config "sentinel" "polling.github.interval_seconds")
#   update_heartbeat() — heartbeat 파일 갱신 (update_heartbeat "sentinel")
#   emit_event()       — 이벤트 큐 적재 (Write-then-Rename)

# ── 파수꾼 전용: emit_event 래퍼 (seen/ 인덱스 추가) ──

# sentinel_emit_event: 기본 emit_event + 중복 방지 인덱스 마킹
# 파수꾼만 seen/ 인덱스를 관리한다 (사절의 slack 이벤트는 자연적 유일성 보장).
sentinel_emit_event() {
  local event_json="$1"
  local event_id=$(echo "$event_json" | jq -r '.id')

  # 공통 emit_event 호출 (큐에 적재)
  emit_event "$event_json"

  # 중복 방지 인덱스 마킹 (빈 파일, 0 bytes) — 파수꾼 전용
  touch "state/sentinel/seen/${event_id}"
}

# ── 중복 방지 ────────────────────────────────────

# is_duplicate: 이미 감지된 이벤트인지 확인
# completed/ 대신 경량 seen 인덱스 사용 (상세: docs/systems/data-lifecycle.md)
is_duplicate() {
  local event_id="$1"
  [ -f "queue/events/pending/${event_id}.json" ] ||
  [ -f "queue/events/dispatched/${event_id}.json" ] ||
  [ -f "state/sentinel/seen/${event_id}" ]
}

# ── 파수꾼 전용: 상태 관리 ────────────────────────

load_state() { local watcher="$1"; cat "state/sentinel/${watcher}-state.json" 2>/dev/null || echo '{}'; }
save_state() { local watcher="$1"; local state="$2"; echo "$state" > "state/sentinel/${watcher}-state.json"; }

# ── 파수꾼 전용: polling interval 헬퍼 ────────────

get_interval() {
  local watcher="$1"
  get_config "sentinel" "polling.${watcher}.interval_seconds"
}
```

---

## Watcher 상세 설계

### GitHub Watcher

| 항목 | 값 |
|------|-----|
| 파일 | `bin/lib/sentinel/github-watcher.sh` |
| 도구 | `gh api` (GitHub CLI) |
| 인증 | `GH_TOKEN` 환경변수 |
| 폴링 전략 | Notifications API + ETag (304 응답 시 rate limit 소비 안함) |
| Rate Limit | 5,000 req/hour (ETag 활용으로 실제 소비 극소) |

#### fetch: Notifications API + ETag

```bash
github_fetch() {
  local state=$(load_state "github")
  local etag=$(echo "$state" | jq -r '.etag // empty')

  local headers=()
  if [ -n "$etag" ]; then
    headers+=(-H "If-None-Match: $etag")
  fi

  # gh api는 GH_TOKEN 환경변수로 자동 인증
  local response
  response=$(gh api /notifications "${headers[@]}" \
    --include 2>&1)

  # 304 Not Modified → 변화 없음
  if echo "$response" | head -1 | grep -q "304"; then
    echo "[]"  # 빈 배열 반환
    return 0
  fi

  # 새 ETag 저장
  local new_etag=$(echo "$response" | grep -i '^etag:' | awk '{print $2}' | tr -d '\r')
  if [[ -n "$new_etag" ]]; then
    state=$(echo "$state" | jq --arg e "$new_etag" '.etag = $e')
  fi

  # body 추출 (헤더 이후)
  local body
  body=$(echo "$response" | sed '1,/^\r*$/d')

  # notification thread IDs 저장 (post_emit에서 읽음 처리용)
  save_state "github" "$(echo "$state" | jq --argjson ids "$(echo "$body" | jq -c '[.[].id] // []')" '.pending_read_ids = $ids')"

  echo "$body"
}
```

#### parse: Notification → 표준 이벤트 변환 (스코프 필터 포함)

```bash
github_parse() {
  local raw="$1"

  # 빈 배열 단축 경로
  if [[ "$raw" == "[]" || -z "$raw" ]]; then
    echo "[]"
    return 0
  fi

  local allowed_repos=$(get_config "sentinel" "polling.github.scope.repos")
  local allowed_reasons=$(get_config "sentinel" "polling.github.scope.filter_reasons")

  # yq 출력을 JSON 배열로 변환
  [[ "$allowed_repos" == "null" || -z "$allowed_repos" ]] && allowed_repos="[]"
  [[ "$allowed_reasons" == "null" || -z "$allowed_reasons" ]] && allowed_reasons="[]"
  allowed_repos=$(echo "$allowed_repos" | yq eval -o=json '.' 2>/dev/null) || allowed_repos="[]"
  allowed_reasons=$(echo "$allowed_reasons" | yq eval -o=json '.' 2>/dev/null) || allowed_reasons="[]"

  # 스코프 필터: 관할 레포 + 관심 reason만 통과
  # subject.type 기반으로 PullRequest/Issue를 구분하여 이벤트 타입 결정
  echo "$raw" | jq -c --argjson repos "$allowed_repos" --argjson reasons "$allowed_reasons" '[
    .[] |
    select(
      ($repos | length == 0) or (.repository.full_name as $r | $repos | index($r))
    ) |
    select(
      ($reasons | length == 0) or (.reason as $r | $reasons | index($r))
    ) |
    {
    id: ("evt-github-" + .id + "-" + .updated_at),
    type: (
      if .subject.type == "PullRequest" then
        if .reason == "review_requested" then "github.pr.review_requested"
        elif .reason == "assign" then "github.pr.assigned"
        elif .reason == "mention" then "github.pr.mentioned"
        elif .reason == "comment" then "github.pr.comment"
        elif .reason == "state_change" then "github.pr.state_change"
        else ("github.pr." + .reason)
        end
      elif .subject.type == "Issue" then
        if .reason == "assign" then "github.issue.assigned"
        elif .reason == "mention" then "github.issue.mentioned"
        elif .reason == "comment" then "github.issue.comment"
        elif .reason == "state_change" then "github.issue.state_change"
        else ("github.issue." + .reason)
        end
      else ("github.notification." + .reason)
      end
    ),
    source: "github",
    repo: .repository.full_name,
    payload: {
      reason: .reason,
      subject_title: .subject.title,
      subject_url: .subject.url,
      subject_type: .subject.type,
      updated_at: .updated_at,
      pr_number: (.subject.url | capture("/(?<num>[0-9]+)$") | .num // null)
    },
    priority: (
      if .reason == "review_requested" then "normal"
      elif .reason == "assign" then "normal"
      elif .reason == "mention" then "normal"
      elif .reason == "comment" then "low"
      elif .reason == "state_change" then "low"
      else "low"
      end
    ),
    created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    status: "pending"
  }]'
}
```

#### post_emit: Notification 읽음 처리

emit 후 감지한 notification을 읽음 처리하여 다음 폴링에서 중복 반환을 방지한다. `post_emit`은 선택적 단계로, watcher에 `{name}_post_emit` 함수가 존재할 때만 호출된다.

```bash
github_post_emit() {
  local state=$(load_state "github")
  local ids=$(echo "$state" | jq -c '.pending_read_ids // []')
  [[ "$ids" == "[]" ]] && return 0

  echo "$ids" | jq -r '.[]' | while read -r thread_id; do
    gh api -X PATCH "/notifications/threads/${thread_id}" 2>/dev/null || true
  done

  # 처리 완료 후 pending_read_ids 제거
  save_state "github" "$(echo "$state" | jq 'del(.pending_read_ids)')"
}
```

> **참고:** `subject.url`은 API URL (`https://api.github.com/repos/...`)이다. 왕이나 장군이 실제 작업 시 `gh api`로 상세 정보를 조회하면 웹 URL(`html_url`)을 얻을 수 있으므로, 센티널 단계에서는 API URL을 그대로 전달한다.

#### Notifications API를 선택한 이유

| 대안 | 문제점 |
|------|--------|
| `gh pr list` | 모든 PR을 매번 조회 → 비효율, 변경 감지 어려움 |
| `gh api /repos/{owner}/{repo}/events` | 지연시간 30초~6시간, 실시간성 부족 |
| `gh api /notifications` | **사용자에게 관련된 변화만 반환**, ETag로 변화 없으면 즉시 304, rate limit 절약 |

Notifications API가 반환하는 reason 목록:

| reason | 의미 | 우리가 관심있는가? |
|--------|------|-------------------|
| `review_requested` | PR 리뷰 요청 | **Yes** — gen-pr |
| `assign` | 이슈/PR 할당 | **Yes** |
| `mention` | @멘션 | **Yes** |
| `comment` | 코멘트 | **Yes** — gen-pr |
| `state_change` | PR/이슈 상태 변경 | Yes |
| `ci_activity` | CI 완료 | 선택적 |
| `approval_requested` | 배포 승인 요청 | 후순위 |

---

### Jira Watcher

| 항목 | 값 |
|------|-----|
| 파일 | `bin/lib/sentinel/jira-watcher.sh` |
| 도구 | `curl` + Jira REST API |
| 인증 | `JIRA_API_TOKEN` + `eddy@chequer.io` (Basic Auth) |
| 폴링 전략 | JQL 쿼리로 최근 변경분만 조회 |
| Rate Limit | ~10 req/sec 안전 (5분 주기면 문제 없음) |

#### jira-cli 대신 curl을 선택한 이유

| 비교 항목 | jira-cli | curl + REST API |
|-----------|----------|-----------------|
| 응답 속도 | ~700ms | ~350ms (2배 빠름) |
| Changelog 접근 | 불가 | `?expand=changelog`로 변경 이력 확인 |
| JQL 지원 | ORDER BY 별도 분리 필요 | 완전한 JQL 지원 |
| 필드 선택 | 전체 or nothing | 필요한 필드만 요청 가능 |

#### fetch: JQL 기반 변경분 조회

```bash
jira_fetch() {
  local state=$(load_state "jira")
  local last_check=$(echo "$state" | jq -r '.last_check // empty')
  local jira_url="${JIRA_URL:-https://chequer.atlassian.net}"
  local auth=$(echo -n "eddy@chequer.io:${JIRA_API_TOKEN}" | base64)

  # last_check가 없으면 (첫 실행) 최근 10분
  # Jira JQL은 "YYYY-MM-DD HH:mm" 또는 "-5m" 상대 포맷 지원
  local time_filter
  if [ -z "$last_check" ]; then
    time_filter="-10m"
  else
    time_filter="$last_check"
  fi

  local jql_base=$(get_config "sentinel" "polling.jira.scope.jql_base")
  local jql="${jql_base} AND updated >= \"$time_filter\" ORDER BY updated DESC"

  local response
  response=$(curl -s -X POST \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg jql "$jql" '{
      jql: $jql,
      maxResults: 20,
      fields: ["key", "summary", "status", "assignee", "updated", "comment", "priority"]
    }')" \
    "$jira_url/rest/api/3/search/jql")

  # last_check를 Jira JQL 호환 포맷으로 저장 ("YYYY/MM/DD HH:mm")
  local now=$(date -u +"%Y/%m/%d %H:%M")
  save_state "jira" "$(load_state "jira" | jq --arg t "$now" '.last_check = $t')"

  echo "$response"
}
```

#### parse: Jira 이슈 → 표준 이벤트 변환

```bash
jira_parse() {
  local raw="$1"
  local state=$(load_state "jira")
  local known_states=$(echo "$state" | jq '.known_issues // {}')

  # 이벤트 변환
  local events
  events=$(echo "$raw" | jq -c --argjson known "$known_states" '[
    .issues[] | {
      key: .key,
      summary: .fields.summary,
      status: .fields.status.name,
      updated: .fields.updated,
      prev_status: ($known[.key].status // null)
    } | {
      id: ("evt-jira-" + .key + "-" + (.updated | gsub("[^0-9]"; ""))),
      type: (
        if .prev_status == null then "jira.ticket.assigned"
        elif .prev_status != .status then "jira.ticket.updated"
        else "jira.ticket.updated"
        end
      ),
      source: "jira",
      repo: null,
      payload: {
        ticket_key: .key,
        summary: .summary,
        status: .status,
        previous_status: .prev_status,
        url: ("https://chequer.atlassian.net/browse/" + .key)
      },
      priority: "normal",
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }
  ]')

  # known_issues 갱신: 현재 이슈들의 상태를 기록하여 다음 폴링 시 변경 감지에 사용
  local updated_known
  updated_known=$(echo "$raw" | jq '{
    known_issues: ([.issues[] | {(.key): {status: .fields.status.name}}] | add // {})
  }')
  save_state "jira" "$(load_state "jira" | jq --argjson u "$updated_known" '.known_issues = ($u.known_issues + .known_issues)')"

  echo "$events"
}
```

#### 감지하는 변화 유형

| JQL 패턴 | 감지 대상 | 이벤트 타입 |
|-----------|----------|------------|
| `assignee CHANGED TO currentUser() AFTER -5m` | 새로 할당된 티켓 | `jira.ticket.assigned` |
| `status CHANGED AFTER -5m` | 상태 변경 | `jira.ticket.updated` |
| `updated >= -5m` | 모든 변경 (코멘트 포함) | `jira.ticket.updated` |

#### API 엔드포인트 참고

```
POST /rest/api/3/search/jql          — JQL 검색 (신규 엔드포인트)
GET  /rest/api/3/issue/{key}?expand=changelog  — 변경 이력 상세
```

> 주의: 기존 `GET /rest/api/3/search`는 deprecated. `POST /rest/api/3/search/jql` 사용 필수.

---

## 센티널 메인 루프

```bash
#!/bin/bash
# bin/sentinel.sh — 파수꾼 메인 루프

BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
source "$BASE_DIR/bin/lib/common.sh"                    # 공통 함수 (emit_event, get_config, start_heartbeat_daemon, log)
source "$BASE_DIR/bin/lib/sentinel/watcher-common.sh"   # 파수꾼 전용 (sentinel_emit_event, is_duplicate, load_state 등)

# ── Graceful Shutdown ────────────────────────────
RUNNING=true
trap 'RUNNING=false; stop_heartbeat_daemon; log "[SYSTEM] [sentinel] Shutting down..."; exit 0' SIGTERM SIGINT

# ── Watcher 동적 로딩: sentinel.yaml의 polling 키에서 스캔 ──
WATCHERS=()
for key in $(yq eval '.polling | keys | .[]' "$BASE_DIR/config/sentinel.yaml" 2>/dev/null); do
  if [ -f "$BASE_DIR/bin/lib/sentinel/${key}-watcher.sh" ]; then
    WATCHERS+=("$key")
  else
    log "[WARN] [sentinel] Unknown watcher in config: $key (no ${key}-watcher.sh)"
  fi
done

for watcher in "${WATCHERS[@]}"; do
  source "$BASE_DIR/bin/lib/sentinel/${watcher}-watcher.sh"
done

declare -A LAST_POLL

log "[SYSTEM] [sentinel] Started. Watchers: ${WATCHERS[*]}"

start_heartbeat_daemon "sentinel"

while $RUNNING; do

  for watcher in "${WATCHERS[@]}"; do
    interval=$(get_interval "$watcher")
    elapsed=$(( $(date +%s) - ${LAST_POLL[$watcher]:-0} ))

    if [[ "$elapsed" -ge "$interval" ]]; then
      log "[EVENT] [sentinel] Polling: $watcher"

      # 1. fetch
      raw=$("${watcher}_fetch" 2>/dev/null)
      if [[ $? -ne 0 ]]; then
        log "[EVENT] [sentinel] ERROR: ${watcher}_fetch failed"
        LAST_POLL[$watcher]=$(date +%s)
        continue
      fi

      # 2. parse
      events=$("${watcher}_parse" "$raw" 2>/dev/null)

      # 3. emit (중복 제거 포함)
      echo "$events" | jq -c '.[]' 2>/dev/null | while read -r event; do
        event_id=$(echo "$event" | jq -r '.id')
        if ! is_duplicate "$event_id"; then
          sentinel_emit_event "$event"
        fi
      done

      # 4. post_emit (optional: notification 읽음 처리 등)
      if type "${watcher}_post_emit" &>/dev/null; then
        "${watcher}_post_emit" 2>/dev/null || true
      fi

      LAST_POLL[$watcher]=$(date +%s)
    fi
  done

  sleep 5  # 메인 루프 틱 (개별 watcher 주기와 별개)
done
```

---

## 이벤트 타입 정의

### GitHub 이벤트

| Type | Trigger | Default Priority |
|------|---------|-----------------|
| `github.pr.review_requested` | PR 리뷰 요청 (subject.type=PullRequest) | normal |
| `github.pr.assigned` | PR 할당 | normal |
| `github.pr.mentioned` | PR에서 @멘션 | normal |
| `github.pr.comment` | PR 코멘트 추가 | low |
| `github.pr.state_change` | PR 상태 변경 (merged, closed 등) | low |
| `github.issue.assigned` | Issue 할당 (subject.type=Issue) | normal |
| `github.issue.mentioned` | Issue에서 @멘션 | normal |
| `github.issue.comment` | Issue 코멘트 추가 | low |
| `github.issue.state_change` | Issue 상태 변경 | low |
| `github.notification.*` | 기타 notification reason | low |

### Jira 이벤트

| Type | Trigger | Default Priority |
|------|---------|-----------------|
| `jira.ticket.assigned` | 티켓 새로 할당 | normal |
| `jira.ticket.updated` | 상태/내용 변경 (코멘트 포함) | normal |

---

## 이벤트 스키마 (공통)

> 전체 이벤트 타입 카탈로그: [systems/event-types.md](../systems/event-types.md)

```json
{
  "id": "evt-github-12345678-2026-02-07T10:00:00Z",
  "type": "github.pr.review_requested",
  "source": "github",
  "repo": "querypie/frontend",
  "payload": {
    "reason": "review_requested",
    "subject_title": "feat: add user profile page",
    "subject_url": "https://api.github.com/repos/querypie/frontend/pulls/1234",
    "subject_type": "PullRequest",
    "updated_at": "2026-02-07T10:00:00Z",
    "pr_number": "1234"
  },
  "priority": "high",
  "created_at": "2026-02-07T10:00:05Z",
  "status": "pending"
}
```

---

## 중복 방지 메커니즘

### 이벤트 ID 기반

이벤트 ID 생성 규칙으로 자연스럽게 중복을 방지한다:

| 소스 | ID 패턴 | 예시 |
|------|---------|------|
| GitHub | `evt-github-{notification_id}-{updated_at}` | `evt-github-12345678-2026-02-07T10:00:00Z` |
| Jira | `evt-jira-{ticket_key}-{updated_timestamp}` | `evt-jira-QP-123-20260207100000` |

### 활성 큐 + seen 인덱스

`is_duplicate()`는 활성 큐와 경량 인덱스를 확인:
- `queue/events/pending/` — 아직 처리 안된 이벤트
- `queue/events/dispatched/` — 왕이 처리 중인 이벤트
- `state/sentinel/seen/{event-id}` — 과거 처리 완료 이벤트 (빈 파일, 30일 보관)

`completed/` 디렉토리는 확인하지 않는다. completed 파일은 7일 후 삭제되므로, 이후 재감지를 방지하기 위해 별도의 `seen/` 인덱스를 사용.

> 상세: [systems/data-lifecycle.md](../systems/data-lifecycle.md)

### Watcher 상태 파일

```
state/sentinel/
├── heartbeat           # 매 루프마다 갱신 (unix timestamp). 내관이 mtime 확인.
├── github-state.json   # { "etag": "W/\"abc123\"" }
├── jira-state.json     # { "last_check": "2026/02/07 10:00", "known_issues": {...} }
└── seen/               # 중복 방지 인덱스 (빈 파일, 30일 보관)
    ├── evt-github-12345678-2026-02-07T10:00:00Z
    ├── evt-jira-QP-123-20260207100000
    └── ...
```

---

## 확장 가이드: 새 Watcher 추가하기

새 외부 서비스(예: GitLab, Linear, Notion)를 추가하려면:

### 1. Watcher 스크립트 생성

```bash
# bin/lib/sentinel/gitlab-watcher.sh

gitlab_fetch() {
  # GitLab API 호출 (curl 또는 glab CLI)
  local state=$(load_state "gitlab")
  # ... API 호출 로직 ...
  echo "$response"
}

gitlab_parse() {
  local raw="$1"
  # raw → 표준 이벤트 배열 변환
  echo "$raw" | jq -c '[.[] | {
    id: ..., type: ..., source: "gitlab", ...
  }]'
}
```

### 2. 설정 추가

```yaml
# config/sentinel.yaml에 추가
polling:
  gitlab:
    interval_seconds: 120
    host: "gitlab.company.com"
    projects:
      - group/project-a
```

### 3. 환경변수

```bash
export GITLAB_TOKEN="glpat-..."
```

### 4. 상태 파일 자동 생성

`state/sentinel/gitlab-state.json`은 첫 실행 시 `load_state()`가 빈 객체(`{}`)를 반환하므로 별도 초기화 불필요.

### 체크리스트

- [ ] `{name}_fetch()` 함수 구현
- [ ] `{name}_parse()` 함수 구현 (표준 이벤트 스키마 준수)
- [ ] `config/sentinel.yaml`에 polling 설정 추가
- [ ] 환경변수 설정 (API 토큰 등)
- [ ] `config/sentinel.yaml`의 `polling` 키에 watcher 설정 추가 (동적 로딩됨)

---

## 스크립트 위치

```
bin/
├── sentinel.sh                          # 메인 polling loop
└── lib/sentinel/
    ├── watcher-common.sh                # 파수꾼 전용 함수 (sentinel_emit_event, is_duplicate, load_state 등)
    ├── github-watcher.sh                # GitHub watcher (gh api + ETag)
    └── jira-watcher.sh                  # Jira watcher (curl + REST API)
```

## 2단계 필터링 체계

센티널과 왕은 서로 다른 층위의 필터를 담당한다.

| | 센티널 (스코프 필터) | 왕 (판단 필터) |
|---|---|---|
| 기준 | "우리 관할인가?" | "지금 처리할 것인가?" |
| 걸러지면 | 이벤트 자체가 생성되지 않음 | 이벤트는 있지만 대기/무시 |
| 변경 시기 | 레포/프로젝트 추가 시 | 라우팅 규칙 변경 시 |
| 변경 방법 | `config/sentinel.yaml` | `config/king.yaml` |
| 예시 | `querypie/frontend` ✓, `eddy/dotfiles` ✗ | review_requested → gen-pr |

### 스코프 필터 적용 위치

| 소스 | 필터 위치 | 이유 |
|------|----------|------|
| GitHub | **parse 단계** (클라이언트 필터) | Notifications API는 서버에서 레포 필터링 불가 |
| Jira | **fetch 단계** (JQL = 서버 필터) | JQL의 `project IN (...)` 조건으로 API가 필터링 |

---

## 설정

```yaml
# config/sentinel.yaml
polling:
  github:
    interval_seconds: 60
    scope:
      repos:                        # 이 레포의 알림만 이벤트로 변환
        - chequer-io/querypie-frontend
        - chequer-io/querypie-backend
        # 비어있으면 모든 레포 허용
      filter_reasons:               # 이 reason만 이벤트로 변환
        - review_requested
        - assign
        - mention
        - comment
        - state_change
  # jira:                           # 현재 비활성 — 향후 Jira 연동 시 주석 해제
  #   interval_seconds: 300
  #   scope:
  #     jql_base: "assignee = currentUser() AND project IN (QP, QPD)"
```

> **동적 watcher 로딩**: `polling` 키의 자식 키가 watcher 이름이 된다. 위 설정에서 `jira`가 주석 처리되어 있으므로, 파수꾼은 `github`만 로딩한다. Jira 연동 시 주석 해제만으로 활성화된다.

## 장애 대응

| 상황 | 행동 |
|------|------|
| GitHub API 실패 (gh api 에러) | 로그 기록, 다음 주기에 재시도 |
| Jira API 실패 (curl 에러/4xx/5xx) | 로그 기록, 다음 주기에 재시도 |
| Rate Limit 도달 (GitHub 429) | 로그 기록, rate_limit API로 리셋 시간 확인 후 대기 |
| 파수꾼 프로세스 죽음 | 내관이 `state/sentinel/heartbeat` mtime 확인 (2분 초과 → 이상) → tmux 세션 재시작 |
| 파수꾼 프로세스 hang | heartbeat 갱신 안됨 → 내관이 SIGTERM → 재시작 |
| jq 파싱 에러 | 로그에 raw 데이터 기록, 해당 폴링 스킵 |
| SIGTERM/SIGINT 수신 | 현재 루프 완료 후 graceful shutdown |

## 인증 정보 요약

| 서비스 | 환경변수 | 비고 |
|--------|---------|------|
| GitHub | `GH_TOKEN` | `gh` CLI가 자동으로 사용. `repo`, `read:org` 스코프 필요 |
| Jira | `JIRA_API_TOKEN` | `eddy@chequer.io` + token으로 Basic Auth 구성 |

#!/usr/bin/env bash
# Jira Watcher
# curl + REST API + JQL 기반 폴링

jira_fetch() {
  local state
  state=$(load_state "jira")
  local last_check
  last_check=$(echo "$state" | jq -r '.last_check // empty')
  local jira_url="${JIRA_URL:-https://chequer.atlassian.net}"
  local jira_email="${JIRA_USER_EMAIL:-eddy@chequer.io}"
  local auth
  auth=$(echo -n "${jira_email}:${JIRA_API_TOKEN}" | base64 | tr -d '\n')

  local time_filter
  if [[ -z "$last_check" ]]; then
    time_filter="-10m"
  else
    time_filter="$last_check"
  fi

  local jql_base
  jql_base=$(get_config "sentinel" "polling.jira.scope.jql_base")

  local jql="${jql_base} AND updated >= \"$time_filter\" ORDER BY updated DESC"

  local request_body
  request_body=$(jq -n --arg jql "$jql" '{
    jql: $jql,
    maxResults: 20,
    fields: ["key", "summary", "status", "assignee", "updated", "comment", "priority", "labels"]
  }')

  local response
  response=$(curl -s -X POST \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "$jira_url/rest/api/3/search/jql" 2>/dev/null) || true

  # 응답 검증: issues 배열이 없으면 에러
  if ! echo "$response" | jq -e '.issues' >/dev/null 2>&1; then
    log "[EVENT] [sentinel] ERROR: Jira API failed: ${response:0:200}"
    echo '{"issues":[]}'
    return 1
  fi

  # last_check 갱신
  local now
  now=$(date -u +"%Y/%m/%d %H:%M")
  save_state "jira" "$(load_state "jira" | jq --arg t "$now" '.last_check = $t')"

  echo "$response"
}

jira_parse() {
  local raw="$1"

  # 빈 결과 단축 경로 (새 API는 total 없음, issues 배열 길이로 판단)
  local issue_count
  issue_count=$(echo "$raw" | jq '.issues | length')
  if [[ "$issue_count" == "0" ]]; then
    echo "[]"
    return 0
  fi

  local state
  state=$(load_state "jira")
  local known_states
  known_states=$(echo "$state" | jq '.known_issues // {}')

  local jira_url="${JIRA_URL:-https://chequer.atlassian.net}"

  # 이벤트 변환
  local events
  events=$(echo "$raw" | jq -c --argjson known "$known_states" --arg jira_url "$jira_url" '[
    .issues[] | {
      key: .key,
      summary: .fields.summary,
      status: .fields.status.name,
      priority_name: .fields.priority.name,
      labels: [.fields.labels[]?],
      updated: .fields.updated,
      prev_status: ($known[.key].status // null)
    } |
    # 상태 변경 없으면 이벤트 미발생 (코멘트만 추가된 경우 등)
    select(.prev_status == null or .prev_status != .status) |
    {
      id: ("evt-jira-" + .key + "-" + (.updated | gsub("[^0-9]"; ""))),
      type: (
        if .prev_status == null then "jira.ticket.assigned"
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
        priority: .priority_name,
        labels: .labels,
        url: ($jira_url + "/browse/" + .key)
      },
      priority: "normal",
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "pending"
    }
  ]')

  # known_issues 갱신
  local updated_known
  updated_known=$(echo "$raw" | jq -c '[.issues[] | {(.key): {status: .fields.status.name}}] | add // {}')
  save_state "jira" "$(load_state "jira" | jq --argjson u "$updated_known" '.known_issues = ($u + (.known_issues // {}))')"

  echo "$events"
}

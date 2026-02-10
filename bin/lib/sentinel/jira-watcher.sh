#!/usr/bin/env bash
# Jira Watcher
# curl + REST API + JQL 기반 폴링

jira_fetch() {
  local state
  state=$(load_state "jira")
  local last_check
  last_check=$(echo "$state" | jq -r '.last_check // empty')
  local jira_url="${JIRA_URL:-https://chequer.atlassian.net}"
  local auth
  auth=$(echo -n "eddy@chequer.io:${JIRA_API_TOKEN}" | base64)

  local time_filter
  if [[ -z "$last_check" ]]; then
    time_filter="-10m"
  else
    time_filter="$last_check"
  fi

  local jql_base
  jql_base=$(get_config "sentinel" "polling.jira.scope.jql_base")
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
    "$jira_url/rest/api/3/search/jql") || {
    log "[EVENT] [sentinel] ERROR: Jira API call failed"
    echo '{"issues":[]}'
    return 1
  }

  # last_check 갱신
  local now
  now=$(date -u +"%Y/%m/%d %H:%M")
  save_state "jira" "$(load_state "jira" | jq --arg t "$now" '.last_check = $t')"

  echo "$response"
}

jira_parse() {
  local raw="$1"

  # 빈 결과 단축 경로
  local total
  total=$(echo "$raw" | jq -r '.total // 0')
  if [[ "$total" == "0" ]]; then
    echo "[]"
    return 0
  fi

  local state
  state=$(load_state "jira")
  local known_states
  known_states=$(echo "$state" | jq '.known_issues // {}')

  # 이벤트 변환
  local events
  events=$(echo "$raw" | jq -c --argjson known "$known_states" '[
    .issues[] | {
      key: .key,
      summary: .fields.summary,
      status: .fields.status.name,
      priority_name: .fields.priority.name,
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
        priority: .priority_name,
        url: ("https://chequer.atlassian.net/browse/" + .key)
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

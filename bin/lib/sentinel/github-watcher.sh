#!/usr/bin/env bash
# GitHub Watcher
# Notifications API + ETag 기반 폴링

github_fetch() {
  local state
  state=$(load_state "github")
  local etag
  etag=$(echo "$state" | jq -r '.etag // empty')

  local args=("/notifications")
  if [[ -n "$etag" ]]; then
    args+=(-H "If-None-Match: $etag")
  fi

  local response
  response=$(gh api "${args[@]}" --include 2>&1)
  local exit_code=$?

  # 304 Not Modified — 새 알림 없음 (정상)
  # gh api는 non-2xx에 exit 1을 반환하므로 exit_code 체크 전에 304를 먼저 확인
  if echo "$response" | head -1 | grep -q "304"; then
    echo "[]"
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    log "[EVENT] [sentinel] ERROR: gh api failed"
    echo "[]"
    return 1
  fi

  # ETag + notification IDs 저장
  local new_etag
  new_etag=$(echo "$response" | grep -i '^etag:' | awk '{print $2}' | tr -d '\r')
  # 빈 ETag 방어: GitHub가 W/"" 또는 "" 를 반환하면 무시 (영구 304 방지)
  local stripped
  stripped=$(echo "$new_etag" | sed 's/^W\///' | tr -d '"')
  if [[ -n "$stripped" ]]; then
    state=$(echo "$state" | jq --arg e "$new_etag" '.etag = $e')
  fi

  # body 추출 (빈 줄 이후)
  local body
  body=$(echo "$response" | sed '1,/^\r*$/d')

  # notification thread IDs 저장 (post_emit에서 읽음 처리용)
  save_state "github" "$(echo "$state" | jq --argjson ids "$(echo "$body" | jq -c '[.[].id] // []')" '.pending_read_ids = $ids')"

  echo "$body"
}

github_post_emit() {
  local state
  state=$(load_state "github")
  local ids
  ids=$(echo "$state" | jq -c '.pending_read_ids // []')
  [[ "$ids" == "[]" ]] && return 0

  echo "$ids" | jq -r '.[]' | while read -r thread_id; do
    gh api -X PATCH "/notifications/threads/${thread_id}" 2>/dev/null || true
  done

  # 처리 완료 후 pending_read_ids 제거
  save_state "github" "$(echo "$state" | jq 'del(.pending_read_ids)')"
}

github_parse() {
  local raw="$1"

  # 빈 배열 단축 경로
  if [[ "$raw" == "[]" || -z "$raw" ]]; then
    echo "[]"
    return 0
  fi

  local allowed_repos allowed_reasons
  allowed_repos=$(get_config "sentinel" "polling.github.scope.repos" 2>/dev/null)
  allowed_reasons=$(get_config "sentinel" "polling.github.scope.filter_reasons" 2>/dev/null)

  # yq 출력을 JSON 배열로 변환
  [[ "$allowed_repos" == "null" || -z "$allowed_repos" ]] && allowed_repos="[]"
  [[ "$allowed_reasons" == "null" || -z "$allowed_reasons" ]] && allowed_reasons="[]"

  # yq는 YAML 형식으로 출력할 수 있으므로 JSON으로 확실히 변환
  allowed_repos=$(echo "$allowed_repos" | yq eval -o=json '.' 2>/dev/null) || allowed_repos="[]"
  allowed_reasons=$(echo "$allowed_reasons" | yq eval -o=json '.' 2>/dev/null) || allowed_reasons="[]"

  echo "$raw" | jq -c --argjson repos "$allowed_repos" --argjson reasons "$allowed_reasons" '[
    .[] |
    select(
      ($repos | length == 0) or (.repository.full_name as $r | $repos | index($r))
    ) |
    select(
      ($reasons | length == 0) or (.reason as $r | $reasons | index($r))
    ) |
    {
      id: ("evt-github-" + .id),
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
    }
  ]'
}

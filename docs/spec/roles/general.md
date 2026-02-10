# 장군 (General)

> 왕의 명을 받아, 도메인 전문성으로 병사에게 정확한 지시를 내린다.

## 개요

| 항목 | 값 |
|------|-----|
| 영문 코드명 | `general` |
| tmux 세션 | `gen-{domain}` |
| 실행 형태 | Bash 스크립트 (task polling loop + `claude -p` 호출) |
| 수명 | 상주 (Always-on) |
| 리소스 | 대기 중 경량, 작업 시 병사를 통해 CC 실행 |

## 용어 정리

| 용어 | 정의 | 기존 사용처 |
|------|------|------------|
| 플러거블 | 장군 시스템의 확장 가능 속성. 매니페스트만 추가하면 새 장군 인식. | king.md "플러거블 축 정리", filesystem.md |
| 플러그인 / CC Plugin | Claude Code Plugin. 병사가 사용하는 실제 도구. | architecture.md, concept.md 등 전체 |
| 장군 매니페스트 | 장군의 선언적 설정 (YAML). 구독 이벤트, 플러그인 등 선언. | king.md, general.md |
| 병사 (Soldier) | 일회성 CC 세션. 플러그인을 장착한 채 실제 작업 수행. | soldier.md |

> "플러거블 컴포넌트", "도구 플러그인" 같은 신규 합성어는 도입하지 않는다. 기존 문서의 "플러거블", "플러그인" 패턴을 그대로 사용.

## 핵심 원칙 — 왕과의 책임 분리

```
왕 (King)                          장군 (General)
─────────────────────────          ─────────────────────────
"무엇을, 누구에게"                   "어떻게"
─────────────────────────          ─────────────────────────
• 이벤트 우선순위 판단                • 도메인별 프롬프트 구성
• 리소스 여유 확인                    • 전문 메모리 관리
• 적합한 장군 선택                    • 병사 실행 + 결과 확인
• 전체 작업 현황 파악                 • 재시도/에스컬레이션 판단
• 병사 수 제한 (max_soldiers)         • 최종 결과만 왕에게 보고
```

> **재시도는 장군 전담**. 왕은 장군이 보고한 최종 결과(success/failed/needs_human)만 처리한다.

---

## 장군의 핵심 루프

모든 장군은 동일한 루프 구조를 공유하며, **도메인별 차이는 프롬프트 템플릿과 메모리**에 있다. 장군별 스크립트(`gen-pr.sh`, `gen-jira.sh` 등)는 `GENERAL_DOMAIN` 환경변수만 설정하고 공통 루프를 호출한다.

```bash
#!/bin/bash
# bin/generals/gen-pr.sh — 장군별 스크립트 (진입점)
GENERAL_DOMAIN="gen-pr"
source "$BASE_DIR/bin/lib/general/common.sh"
main_loop
```

### 공통 메인 루프 (`bin/lib/general/common.sh`)

```bash
main_loop() {
  local max_retries=$(get_config "generals/$GENERAL_DOMAIN" "retry.max_attempts" 2)
  local retry_backoff=$(get_config "generals/$GENERAL_DOMAIN" "retry.backoff_seconds" 60)

  while true; do
    update_heartbeat "$GENERAL_DOMAIN"

    # ── 1. 다음 작업 선택 ──────────────────────────
    local task_file=$(pick_next_task "$GENERAL_DOMAIN")
    if [ -z "$task_file" ]; then
      sleep 10
      continue
    fi

    local task=$(cat "$task_file")
    local task_id=$(echo "$task" | jq -r '.id')

    # task를 in_progress로 이동 (작업 점유)
    mv "$task_file" "$BASE_DIR/queue/tasks/in_progress/${task_id}.json"
    log "[EVENT] [$GENERAL_DOMAIN] Task claimed: $task_id"

    # ── 2. 작업 공간 준비 ──────────────────────────
    local repo=$(echo "$task" | jq -r '.repo // empty')
    local work_dir="$BASE_DIR/workspace/$GENERAL_DOMAIN"
    if [ -n "$repo" ]; then
      work_dir=$(ensure_workspace "$GENERAL_DOMAIN" "$repo")
      if [ $? -ne 0 ]; then
        report_to_king "$task_id" "failed" "Workspace setup failed for $repo"
        continue
      fi
    fi

    # ── 3. 도메인 메모리 로딩 ──────────────────────
    local memory=$(load_domain_memory "$GENERAL_DOMAIN")
    local repo_context=$(load_repo_memory "$GENERAL_DOMAIN" "$repo")

    # ── 4. 프롬프트 조립 ──────────────────────────
    local prompt_file="$BASE_DIR/state/prompts/${task_id}.md"
    build_prompt "$task" "$memory" "$repo_context" > "$prompt_file"

    # ── 5. 실행 + 재시도 루프 (장군 전담) ──────────
    local attempt=0
    local final_status="failed"
    local final_result=""

    while (( attempt <= max_retries )); do
      local raw_file="$BASE_DIR/state/results/${task_id}-raw.json"
      rm -f "$raw_file"  # 이전 시도 결과 제거

      # 병사 실행
      spawn_soldier "$task_id" "$prompt_file" "$work_dir"
      local timeout=$(get_config "generals/$GENERAL_DOMAIN" "timeout_seconds" 1800)
      wait_for_soldier "$task_id" "$raw_file" "$timeout"

      if [ ! -f "$raw_file" ]; then
        log "[ERROR] [$GENERAL_DOMAIN] No result file: $task_id (attempt $attempt)"
        attempt=$((attempt + 1))
        continue
      fi

      local result=$(cat "$raw_file")
      local status=$(echo "$result" | jq -r '.status // "failed"')

      case "$status" in
        success)
          final_status="success"
          final_result="$result"
          update_memory "$result"
          break
          ;;
        needs_human)
          final_status="needs_human"
          final_result="$result"
          break
          ;;
        failed)
          local error=$(echo "$result" | jq -r '.error // "unknown"')
          log "[WARN] [$GENERAL_DOMAIN] Attempt $attempt failed: $task_id — $error"
          attempt=$((attempt + 1))
          if (( attempt <= max_retries )); then
            log "[EVENT] [$GENERAL_DOMAIN] Retrying in ${retry_backoff}s (attempt $attempt/$max_retries)"
            sleep "$retry_backoff"
          fi
          ;;
        *)
          log "[WARN] [$GENERAL_DOMAIN] Unknown status '$status': $task_id"
          attempt=$((attempt + 1))
          ;;
      esac
    done

    # ── 6. 최종 결과를 왕에게 보고 ─────────────────
    if [ "$final_status" = "needs_human" ]; then
      escalate_to_king "$task_id" "$final_result"
    else
      report_to_king "$task_id" "$final_status" \
        "$(echo "$final_result" | jq -r '.summary // "no summary"')" \
        "$final_result"
    fi

    sleep 5
  done
}
```

---

## 핵심 함수 상세

### pick_next_task

자신의 도메인에 배정된 pending task를 priority 순으로 선택. `retry_after`가 미래인 작업은 스킵.

```bash
# bin/lib/general/common.sh

pick_next_task() {
  local general="$1"
  local pending_dir="$BASE_DIR/queue/tasks/pending"
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local best_file=""
  local best_order=99

  for f in "$pending_dir"/*.json; do
    [ -f "$f" ] || continue

    local target=$(jq -r '.target_general' "$f")
    [ "$target" = "$general" ] || continue

    # retry_after가 미래면 스킵
    local retry_after=$(jq -r '.retry_after // ""' "$f")
    if [ -n "$retry_after" ] && [[ "$retry_after" > "$now" ]]; then
      continue
    fi

    # priority 정렬: high(1) > normal(2) > low(3)
    local priority=$(jq -r '.priority' "$f")
    local order=2
    case "$priority" in
      high) order=1 ;;
      normal) order=2 ;;
      low) order=3 ;;
    esac

    if (( order < best_order )); then
      best_order=$order
      best_file="$f"
    fi
  done

  echo "$best_file"  # 빈 문자열이면 할 일 없음
}
```

### spawn_soldier + wait_for_soldier

장군의 `spawn_soldier()`는 pre-flight 검증 후 `bin/spawn-soldier.sh`를 호출하는 **레이어드 구조**이다. tmux 세션 생성은 스크립트가 담당하고, 세션 등록/대기는 함수에 유지한다.

```bash
# bin/lib/general/common.sh

spawn_soldier() {
  local task_id="$1"
  local prompt_file="$2"
  local work_dir="$3"

  # ── Pre-flight 검증 (장군 함수에서 수행) ──
  if [ ! -f "$prompt_file" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Prompt file not found: $prompt_file"
    return 1
  fi
  if [ ! -d "$work_dir" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] Work directory not found: $work_dir"
    return 1
  fi

  # ── 병사 생성 (스크립트 위임) ──
  "$BASE_DIR/bin/spawn-soldier.sh" "$task_id" "$prompt_file" "$work_dir"
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log "[ERROR] [$GENERAL_DOMAIN] spawn-soldier.sh failed for task: $task_id"
    return 1
  fi

  # ── 세션 등록 (장군 함수에서 수행 — flock으로 내관과 경쟁 조건 방지) ──
  local soldier_id=$(cat "$BASE_DIR/state/results/${task_id}-soldier-id")
  local lock_file="$BASE_DIR/state/sessions.lock"
  local session_entry=$(jq -n \
    --arg id "$soldier_id" \
    --arg task "$task_id" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, task_id: $task, started_at: $started}')
  (
    flock -x 200
    echo "$session_entry" >> "$BASE_DIR/state/sessions.json"
  ) 200>"$lock_file"
}

wait_for_soldier() {
  local task_id="$1"
  local raw_file="$2"
  local timeout=${3:-1800}  # 기본 30분
  local waited=0

  while [ ! -f "$raw_file" ] && (( waited < timeout )); do
    sleep 5
    waited=$((waited + 5))
  done

  # 타임아웃 처리
  if (( waited >= timeout )); then
    log "[ERROR] [$GENERAL_DOMAIN] Soldier timeout: $task_id (>${timeout}s)"

    # tmux 세션 강제 종료
    local soldier_id_file="$BASE_DIR/state/results/${task_id}-soldier-id"
    if [ -f "$soldier_id_file" ]; then
      local soldier_id=$(cat "$soldier_id_file")
      if tmux has-session -t "$soldier_id" 2>/dev/null; then
        tmux kill-session -t "$soldier_id"
        log "[SYSTEM] [$GENERAL_DOMAIN] Killed soldier session: $soldier_id"
      fi
    fi

    # 실패 결과 생성
    jq -n \
      --arg task_id "$task_id" \
      --arg error "Timeout after ${timeout} seconds" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id: $task_id, status: "failed", error: $error, completed_at: $ts}' \
      > "$raw_file"
  fi
}
```

> 병사가 Write 도구로 `state/results/{task-id}-raw.json`에 직접 결과를 저장한다. 왕이 폴링하는 `{task-id}.json`과 분리하여, 장군의 재시도 루프 중 왕이 중간 결과를 발견하지 않게 한다. stdout/stderr는 `logs/sessions/{soldier-id}.log`로 캡처 (디버깅용).

### report_to_king

장군이 재시도 루프를 완료한 후, 최종 결과를 왕이 볼 수 있는 경로에 Write-then-Rename으로 작성.

```bash
# bin/lib/general/common.sh

report_to_king() {
  local task_id="$1"
  local status="$2"       # success | failed
  local summary="$3"
  local raw_result="$4"   # 원본 JSON (있으면)

  local result_file="$BASE_DIR/state/results/${task_id}.json"
  local tmp_file="${result_file}.tmp"

  if [ -n "$raw_result" ] && [ "$raw_result" != "" ]; then
    # raw 결과가 있으면 status만 확정하여 최종 결과로 작성
    echo "$raw_result" | jq --arg s "$status" '.status = $s' > "$tmp_file"
  else
    # raw 결과 없이 직접 생성 (workspace 실패 등)
    jq -n \
      --arg task_id "$task_id" \
      --arg status "$status" \
      --arg summary "$summary" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id: $task_id, status: $status, summary: $summary, completed_at: $ts}' \
      > "$tmp_file"
  fi

  mv "$tmp_file" "$result_file"
  log "[EVENT] [$GENERAL_DOMAIN] Reported to king: $task_id ($status)"
}
```

> **파일 존재 = 보고 완료**. 왕은 `state/results/{task-id}.json`만 폴링하며, `-raw.json`은 무시한다.

### escalate_to_king

`needs_human` 상태일 때, checkpoint를 생성하고 왕에게 전달.

```bash
# bin/lib/general/common.sh

escalate_to_king() {
  local task_id="$1"
  local result="$2"

  # Checkpoint 생성 — 사람 응답 후 작업 재개에 필요한 상태
  local checkpoint_file="$BASE_DIR/state/results/${task_id}-checkpoint.json"
  local task=$(cat "$BASE_DIR/queue/tasks/in_progress/${task_id}.json" 2>/dev/null)

  jq -n \
    --arg task_id "$task_id" \
    --arg general "$GENERAL_DOMAIN" \
    --argjson repo "$(echo "$task" | jq '.repo')" \
    --argjson payload "$(echo "$task" | jq '.payload')" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id: $task_id, target_general: $general, repo: $repo,
      payload: $payload, created_at: $ts}' \
    > "$checkpoint_file"

  # 최종 결과에 checkpoint_path 포함하여 왕에게 보고
  local result_file="$BASE_DIR/state/results/${task_id}.json"
  local tmp_file="${result_file}.tmp"

  echo "$result" | jq \
    --arg cp "$checkpoint_file" \
    '.status = "needs_human" | .checkpoint_path = $cp' \
    > "$tmp_file"
  mv "$tmp_file" "$result_file"

  log "[EVENT] [$GENERAL_DOMAIN] Escalated to king: $task_id (needs_human, checkpoint saved)"
}
```

### load_domain_memory + load_repo_memory

```bash
# bin/lib/general/common.sh

load_domain_memory() {
  local domain="$1"
  local memory_dir="$BASE_DIR/memory/generals/$domain"

  if [ -d "$memory_dir" ]; then
    # 모든 .md 파일을 합쳐서 반환 (50KB 제한)
    cat "$memory_dir"/*.md 2>/dev/null | head -c 50000
  else
    echo ""
  fi
}

load_repo_memory() {
  local domain="$1"
  local repo="$2"  # e.g., "querypie/frontend"

  [ -z "$repo" ] && echo "" && return 0

  local repo_slug=$(echo "$repo" | tr '/' '-')  # "querypie-frontend"
  local repo_file="$BASE_DIR/memory/generals/${domain}/repo-${repo_slug}.md"

  if [ -f "$repo_file" ]; then
    cat "$repo_file"
  else
    echo ""
  fi
}
```

### update_memory

병사가 발견한 새로운 패턴을 장군의 메모리에 추가.

```bash
# bin/lib/general/common.sh

update_memory() {
  local result="$1"
  local updates=$(echo "$result" | jq -r '.memory_updates[]' 2>/dev/null)

  [ -z "$updates" ] && return 0

  local memory_file="$BASE_DIR/memory/generals/${GENERAL_DOMAIN}/learned-patterns.md"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # flock으로 동시 쓰기 방지
  (
    flock -x 200
    echo "" >> "$memory_file"
    echo "### $timestamp" >> "$memory_file"
    echo "$updates" | while IFS= read -r line; do
      [ -n "$line" ] && echo "- $line" >> "$memory_file"
    done
  ) 200>"$memory_file.lock"

  local count=$(echo "$updates" | grep -c '[^ ]')
  log "[SYSTEM] [$GENERAL_DOMAIN] Memory updated: $count new patterns"
}
```

### build_prompt

장군별 프롬프트 템플릿에 변수를 치환하여 최종 프롬프트를 stdout으로 출력.

```bash
# bin/lib/general/prompt-builder.sh

build_prompt() {
  local task_json="$1"
  local memory="$2"
  local repo_context="$3"

  local task_id=$(echo "$task_json" | jq -r '.id')
  local task_type=$(echo "$task_json" | jq -r '.type')
  local payload=$(echo "$task_json" | jq -c '.payload')
  local repo=$(echo "$task_json" | jq -r '.repo // ""')

  # 장군별 프롬프트 템플릿 선택
  local template="$BASE_DIR/config/generals/templates/${GENERAL_DOMAIN}.md"
  if [ ! -f "$template" ]; then
    log "[WARN] [$GENERAL_DOMAIN] Template not found: $template, using default"
    template="$BASE_DIR/config/generals/templates/default.md"
  fi

  if [ ! -f "$template" ]; then
    log "[ERROR] [$GENERAL_DOMAIN] No template available"
    return 1
  fi

  # 템플릿의 플레이스홀더를 실제 값으로 치환하여 stdout 출력
  cat "$template" | \
    sed "s|{{TASK_ID}}|$task_id|g" | \
    sed "s|{{TASK_TYPE}}|$task_type|g" | \
    sed "s|{{REPO}}|$repo|g"

  # 템플릿 뒤에 동적 섹션 추가
  echo ""
  echo "## 이번 작업 (payload)"
  echo '```json'
  echo "$payload" | jq .
  echo '```'

  if [ -n "$memory" ]; then
    echo ""
    echo "## 도메인 메모리"
    echo "$memory"
  fi

  if [ -n "$repo_context" ]; then
    echo ""
    echo "## 레포지토리 컨텍스트"
    echo "$repo_context"
  fi

  echo ""
  echo "## 출력 요구사항"
  echo "결과를 아래 경로에 Write 도구로 JSON 파일을 생성할 것:"
  echo '```'
  echo "$BASE_DIR/state/results/${task_id}-raw.json"
  echo '```'
  echo "스키마:"
  echo '```json'
  echo '{"task_id": "'$task_id'", "status": "success|failed|needs_human",'
  echo ' "summary": "...", "error": "...", "question": "...",'
  echo ' "details": {...}, "memory_updates": [...]}'
  echo '```'
}
```

> 프롬프트 템플릿은 `config/generals/templates/{general-domain}.md`에 위치. 각 장군이 도메인별 지시사항과 CC Plugin 사용법을 템플릿에 포함한다.

### ensure_workspace

```bash
# bin/lib/general/common.sh

ensure_workspace() {
  local general="$1"
  local repo="$2"
  local work_dir="$BASE_DIR/workspace/$general"

  mkdir -p "$work_dir" || {
    log "[ERROR] [$general] Failed to create workspace: $work_dir"
    return 1
  }

  # ── CC Plugin 설정 ──
  # 매니페스트의 cc_plugin 정보로 .claude/plugins.json 생성 (없을 때만)
  local manifest="$BASE_DIR/config/generals/${general}.yaml"
  if [ ! -f "$manifest" ]; then
    log "[ERROR] [$general] Manifest not found: $manifest"
    return 1
  fi

  local plugin_name=$(yq eval '.cc_plugin.name // ""' "$manifest" 2>/dev/null || echo "")
  local plugin_path=$(yq eval '.cc_plugin.path // ""' "$manifest" 2>/dev/null || echo "")

  if [ -n "$plugin_name" ] && [ ! -f "$work_dir/.claude/plugins.json" ]; then
    # 플러그인 경로 존재 확인
    if [ ! -d "$BASE_DIR/$plugin_path" ]; then
      log "[ERROR] [$general] Plugin not found: $BASE_DIR/$plugin_path"
      return 1
    fi

    mkdir -p "$work_dir/.claude"
    cat > "$work_dir/.claude/plugins.json" <<EOF
[
  {
    "name": "$plugin_name",
    "path": "$BASE_DIR/$plugin_path"
  }
]
EOF
    log "[SYSTEM] [$general] CC Plugin configured: $plugin_name"
  fi

  # ── 레포 클론/업데이트 ──
  if [ -n "$repo" ]; then
    local repo_dir="$work_dir/$(basename "$repo")"

    if [ ! -d "$repo_dir" ]; then
      log "[SYSTEM] [$general] Cloning repo: $repo"
      if ! git clone "git@github.com:${repo}.git" "$repo_dir" 2>&1; then
        log "[ERROR] [$general] Failed to clone repo: $repo"
        return 1
      fi
    else
      if ! git -C "$repo_dir" fetch origin 2>&1; then
        log "[WARN] [$general] Failed to fetch repo: $repo (continuing with stale)"
      fi
    fi
  fi

  echo "$work_dir"
}
```

> **plugins.json 멱등성**: 파일이 이미 존재하면 덮어쓰지 않는다. 매니페스트의 cc_plugin이 변경된 경우 수동 삭제 후 재생성 필요.

---

## CC Plugin 통합

병사의 도구는 CC Plugin(friday, sunday 등)이다. 장군이 프롬프트에서 플러그인을 지정하는 대신, **workspace 기반으로 CC Plugin을 자동 로드**한다.

### workspace 기반 CC Plugin 설정

```
workspace/
├── gen-pr/
│   ├── .claude/
│   │   └── plugins.json      # friday plugin 참조
│   ├── CLAUDE.md              # gen-pr 도메인 컨텍스트 (선택)
│   ├── querypie-frontend/     # git worktree
│   └── querypie-backend/
├── gen-jira/
│   ├── .claude/
│   │   └── plugins.json      # sunday plugin 참조
│   ├── CLAUDE.md
│   └── ...
└── gen-test/
    ├── .claude/
    │   └── plugins.json      # 신규 test plugin
    └── ...
```

### 메커니즘

1. 장군 매니페스트에 `cc_plugin` 필드 선언 (name, path)
2. `ensure_workspace()`가 workspace 초기 설정 시 `.claude/plugins.json` 자동 생성 (없을 때만)
3. 병사가 `cd '$WORK_DIR' && claude -p`로 실행되면 CC Plugin이 자동 로드
4. 장군의 `build_prompt()`에서 `--plugin` CLI 파라미터 불필요
5. CC Plugin 사용법(커맨드, 워크플로우)은 **프롬프트 템플릿에 포함**

### plugins.json 예시

```json
[
  {
    "name": "friday",
    "path": "/opt/kingdom/plugins/friday"
  }
]
```

---

## 피드백 루프 아키텍처

### 2계층 품질 보장 모델

```
┌─────────────────────────────────────────┐
│ CC Plugin 피드백 루프 (도메인 품질)        │
│                                          │
│  실행 → 평가 → 미달 시 반복 → 완료       │
│  (friday의 ralph-loop, sunday의 리뷰 등)  │
│                                          │
│  출력: status + summary + details         │
└──────────────────┬──────────────────────┘
                   │ raw 결과 (-raw.json)
                   ▼
┌─────────────────────────────────────────┐
│ 장군 재시도 루프 (task 완료 여부)          │
│                                          │
│  success  → 최종 결과 작성 → 왕이 발견    │
│  failed   → 재시도 (max까지) or 최종 실패 │
│  needs_human → checkpoint + 왕에게 전달   │
└─────────────────────────────────────────┘
```

### 핵심 원칙

- **장군은 점수를 매기지 않는다**. CC Plugin이 자체 품질 기준으로 최적화한 결과를 신뢰한다.
- **CC Plugin이 도메인 품질을 보장**한다. friday는 리뷰 품질을, sunday는 코드+스펙 품질을 자체 루프로 검증.
- **장군은 task 완료 확인 + 재시도**만 수행한다. 왕에게는 최종 결과만 전달.

### 결과 파일 분리

| 파일 | 생성자 | 소비자 | 내용 |
|------|--------|--------|------|
| `{task-id}-raw.json` | 병사 | 장군 | CC Plugin이 출력한 원본 결과 |
| `{task-id}.json` | 장군 (report_to_king) | 왕 | 장군이 확정한 최종 결과 |
| `{task-id}-checkpoint.json` | 장군 (escalate_to_king) | 왕 | needs_human 시 작업 재개용 상태 |

### 책임 분리

| 계층 | 책임 | 예시 |
|------|------|------|
| CC Plugin | 도메인 품질 보장 | friday: 리뷰 구체성, 오탐 비율 체크 → 미달 시 자체 반복 |
| 장군 | task 완료 확인 + 재시도 | status=failed → 재시도 (max까지), success → 왕에게 보고 |
| 왕 | 최종 결과 처리 | success → 사절 알림, failed → 에스컬레이션, needs_human → 사절에게 전달 |

---

## 현재 장군 목록

장군은 플러거블이다. 아래 목록은 초기 구성이며, 매니페스트만 추가하면 새 장군을 인식한다.

| 장군 | CC Plugin | 역할 |
|------|-----------|------|
| gen-pr | friday | PR 리뷰 |
| gen-jira | sunday | Jira 티켓 구현 |
| gen-test | (신규) | 테스트 코드 작성 |

### gen-pr: PR Review 장군

| 항목 | 값 |
|------|-----|
| tmux 세션 | `gen-pr` |
| CC Plugin | friday |
| 전문 메모리 | 레포별 리뷰 패턴, 팀별 코드 스타일 |
| 병사 수 | 1 (순차 처리) |

**워크플로우**:
```
task.json 수신
  → 레포 메모리 로딩 (이 프로젝트의 리뷰 기준은?)
  → 프롬프트 조립 (CC Plugin은 workspace가 자동 제공)
  → 병사 실행: PR 체크아웃 → friday 플러그인이 코드 리뷰 + 자체 품질 루프
  → 장군은 status 확인 (success/failed/needs_human)
  → failed: 재시도 (최대 2회)
  → success: 최종 결과를 왕에게 보고
```

**전문 메모리 예시** (`memory/generals/gen-pr/`):
```
patterns.md         — 공통 리뷰 패턴 (자주 발견되는 이슈)
repo-frontend.md    — querypie/frontend 전용 컨텍스트
repo-backend.md     — querypie/backend 전용 컨텍스트
```

---

### gen-test: Test Code 장군 (예시)

> 장군은 플러거블이므로 gen-test는 스케줄 기반 장군의 **예시**이다.

| 항목 | 값 |
|------|-----|
| tmux 세션 | `gen-test` |
| CC Plugin | (신규 구성 필요) |
| 전문 메모리 | 테스트 프레임워크 설정, 레포별 테스트 패턴 |
| 병사 수 | 1 |

**워크플로우**:
```
task.json 수신 (스케줄 기반)
  → 대상 파일/모듈 분석
  → 테스트 전략 수립 (단위 테스트? 통합 테스트?)
  → 병사 실행: CC Plugin이 테스트 코드 작성 → 실행 → 자체 품질 루프
  → 장군은 status 확인
  → success: PR 생성 → 왕에게 보고
  → failed: 재시도 or 에스컬레이션
```

**전문 메모리 예시** (`memory/generals/gen-test/`):
```
frameworks.md       — 프로젝트별 테스트 프레임워크 (Jest, Vitest 등)
patterns.md         — 효과적인 테스트 패턴
coverage-rules.md   — 커버리지 기준
```

---

### gen-jira: Jira Ticket 장군

| 항목 | 값 |
|------|-----|
| tmux 세션 | `gen-jira` |
| CC Plugin | sunday |
| 전문 메모리 | 코드베이스 구조, 이전 티켓 처리 패턴 |
| 병사 수 | 1 |

**워크플로우**:
```
task.json 수신
  → Jira 티켓 상세 읽기
  → 코드베이스 메모리로 영향 범위 파악
  → 프롬프트 조립 (CC Plugin은 workspace가 자동 제공)
  → 병사 실행: sunday 플러그인이 분석 → 구현 → 코드 리뷰 → 스펙 리뷰 (자체 품질 루프)
  → 장군은 status 확인
  → success: PR 생성 + Jira 코멘트 → 왕에게 보고
  → failed: 재시도 or 에스컬레이션
```

**전문 메모리 예시** (`memory/generals/gen-jira/`):
```
codebase-map.md     — 레포지토리 구조, 주요 모듈
past-tickets.md     — 이전 처리한 티켓 패턴
conventions.md      — 브랜치 네이밍, 커밋 컨벤션
```

---

## 확장 가이드

새 장군을 추가하려면:

1. **매니페스트 작성**: `config/generals/gen-{domain}.yaml` (subscribes + schedules + cc_plugin 선언)
2. **CC Plugin 배치**: `plugins/{plugin-name}/` (기존 플러그인 사용 또는 신규 작성)
3. **프롬프트 템플릿**: `config/generals/templates/gen-{domain}.md` (도메인별 지시사항 + CC Plugin 사용법)
4. **스크립트 생성**: `bin/generals/gen-{domain}.sh` (GENERAL_DOMAIN 설정 + main_loop 호출)
5. **메모리 디렉토리**: `memory/generals/{domain}/`
6. **왕/센티널 코드 수정 불필요** — 매니페스트만 추가하면 왕이 자동 인식
7. **시나리오 참고**: [docs/examples/](../examples/)에 이벤트 기반(gen-pr)과 스케줄 기반(gen-test) 장군의 전체 동작 시나리오가 있다

```yaml
# config/generals/gen-docs.yaml (예: 문서 작성 장군)
name: gen-docs
description: "문서 작성 장군"
script: "bin/generals/gen-docs.sh"

cc_plugin:
  name: doc-writer
  path: "plugins/doc-writer"

subscribes: []    # 외부 이벤트 구독 없음 — 순수 스케줄 기반

schedules:
  - name: docs-update
    cron: "0 2 * * 1"
    task_type: "docs-generation"
    payload: {}
```

### workspace 제약

- **장군당 1개 workspace**: `workspace/gen-{domain}/`
- **다른 레포일 때만 병렬 가능**: 같은 레포를 동시에 수정하면 충돌 (workspace가 장군당 1개이므로)
- `ensure_workspace`가 CC Plugin 설정과 레포 클론을 모두 처리

---

## 품질 게이트

### 2계층 모델

**도메인 품질은 CC Plugin이 보장**하고, **장군은 task 완료 여부 + 재시도**를 담당한다.

| 계층 | 주체 | 확인 내용 |
|------|------|----------|
| 1. 도메인 품질 | CC Plugin | 리뷰 구체성, 테스트 통과율, 코드+스펙 품질 등 (자체 피드백 루프) |
| 2. task 완료 + 재시도 | 장군 | status 확인, failed 시 재시도 (max까지), 최종 결과만 왕에게 보고 |
| 3. 최종 처리 | 왕 | 장군이 보고한 최종 결과 수신, 사절 알림, needs_human 처리 |

### CC Plugin별 자체 품질 기준

| 장군 | CC Plugin | 내부 품질 기준 |
|------|-----------|---------------|
| gen-pr | friday | 리뷰의 구체성, 오탐 비율 (ralph-loop) |
| gen-test | (신규) | 테스트 통과율, 커버리지 |
| gen-jira | sunday | 코드 품질 + 스펙 충족도 (code-reviewer + spec-reviewer) |

---

## 장애 대응

| 상황 | 행동 |
|------|------|
| workspace 생성 실패 | 에러 로그, task를 failed로 왕에게 보고 |
| manifest 파싱 실패 | 에러 로그, ensure_workspace 실패 → task failed |
| CC Plugin 경로 없음 | ensure_workspace에서 검증 실패 → task failed |
| git clone 실패 | 에러 로그, task failed로 보고 |
| git fetch 실패 | 경고 로그, stale 상태로 작업 계속 |
| 프롬프트 템플릿 없음 | default 템플릿 사용, 없으면 task failed |
| 병사 타임아웃 (매니페스트 `timeout_seconds`) | tmux 세션 강제 종료, failed 결과 생성 |
| 병사가 결과 파일 미생성 | 타임아웃과 동일 처리 |
| 재시도 max 초과 | 최종 failed로 왕에게 보고 |
| 동시 메모리 쓰기 | flock으로 파일 잠금 |
| 장군 프로세스 죽음 | 내관이 heartbeat 확인 → tmux 재시작 |
| in_progress task 잔존 (장군 재시작 후) | 다음 기동 시 in_progress task는 failed로 처리 후 재배정 대기 |

---

## 스크립트 위치

```
bin/generals/
├── gen-pr.sh                        # GENERAL_DOMAIN="gen-pr" + main_loop
├── gen-test.sh                      # GENERAL_DOMAIN="gen-test" + main_loop
└── gen-jira.sh                      # GENERAL_DOMAIN="gen-jira" + main_loop

bin/lib/general/
├── common.sh                        # main_loop, pick_next_task, spawn_soldier,
│                                    # wait_for_soldier, report_to_king,
│                                    # escalate_to_king, ensure_workspace,
│                                    # load_domain_memory, load_repo_memory,
│                                    # update_memory
└── prompt-builder.sh                # build_prompt

config/generals/
├── gen-pr.yaml                      # 매니페스트
├── gen-jira.yaml
├── gen-test.yaml
└── templates/                       # 프롬프트 템플릿
    ├── gen-pr.md                    # friday 사용법 포함
    ├── gen-jira.md                  # sunday 사용법 포함
    ├── gen-test.md
    └── default.md                   # fallback 템플릿
```

---

## 관련 문서

- [roles/king.md](king.md) — 장군에게 task 배정, 최종 결과 처리 (재시도는 장군 전담)
- [roles/soldier.md](soldier.md) — 병사 생명주기, raw 결과 출력
- [systems/filesystem.md](../systems/filesystem.md) — workspace 디렉토리 구조
- [systems/message-passing.md](../systems/message-passing.md) — 이벤트/작업 큐 구조
- [examples/scenario-gen-pr.md](../examples/scenario-gen-pr.md) — 이벤트 기반 장군 동작 시나리오 (6건)
- [examples/scenario-gen-test.md](../examples/scenario-gen-test.md) — 스케줄 기반 장군 동작 시나리오 (5건)

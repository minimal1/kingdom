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

> **구조화된 출력**: `spawn-soldier.sh`는 실행 전 `.kingdom-task.json` 컨텍스트 파일을 workspace에 생성한다. 병사는 `workspace/CLAUDE.md`(자동 로드)의 지시에 따라 `.kingdom-task.json`을 읽고, Write 도구로 `state/results/{task-id}-raw.json`에 결과를 직접 생성한다.
>
> 왕이 폴링하는 `{task-id}.json`과 분리하여, 장군의 재시도 루프 중 왕이 중간 결과를 발견하지 않게 한다. stdout+stderr는 `logs/sessions/{soldier-id}.log`로 캡처 (디버깅용).
>
> **결과 스키마** (`config/workspace-claude.md` → `workspace/CLAUDE.md`에서 지시):
> ```json
> {
>   "task_id": "string (필수)",
>   "status": "success | failed | needs_human (필수)",
>   "summary": "string (필수)",
>   "error": "string (선택, 실패 시)",
>   "question": "string (선택, needs_human 시)",
>   "memory_updates": ["string"] "(선택)"
> }
> ```

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

장군별 프롬프트 템플릿에 변수를 치환하여 최종 프롬프트를 stdout으로 출력. `{{payload.KEY}}` 구문으로 payload 필드를 인라인 치환할 수 있다.

```bash
# bin/lib/general/prompt-builder.sh

build_prompt() {
  local task_json="$1"
  local memory="$2"
  local repo_context="$3"

  local task_id task_type payload repo
  task_id=$(echo "$task_json" | jq -r '.id')
  task_type=$(echo "$task_json" | jq -r '.type')
  payload=$(echo "$task_json" | jq -c '.payload')
  repo=$(echo "$task_json" | jq -r '.repo // ""')

  # 장군별 프롬프트 템플릿 선택 (없으면 default.md 폴백)
  local template="$BASE_DIR/config/generals/templates/${GENERAL_DOMAIN}.md"
  if [ ! -f "$template" ]; then
    template="$BASE_DIR/config/generals/templates/default.md"
  fi

  # 기본 플레이스홀더 치환
  local content
  content=$(sed -e "s|{{TASK_ID}}|$task_id|g" \
                -e "s|{{TASK_TYPE}}|$task_type|g" \
                -e "s|{{REPO}}|$repo|g" \
                "$template")

  # Payload 필드 치환: {{payload.KEY}} → 실제 값
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local key val
    key=$(echo "$line" | jq -r '.key')
    val=$(echo "$line" | jq -r '.value // ""')
    content=$(echo "$content" | sed "s|{{payload\\.${key}}}|${val}|g")
  done <<< "$(echo "$payload" | jq -c 'to_entries[]' 2>/dev/null || true)"

  echo "$content"

  # 동적 섹션 — 템플릿이 {{payload.*}} 플레이스홀더를 사용하면 payload dump 생략
  if grep -q '{{payload\.' "$template" 2>/dev/null; then
    : # 템플릿이 payload를 인라인으로 소비 — dump 불필요
  else
    echo ""
    echo "## Task Payload"
    echo '```json'
    echo "$payload" | jq .
    echo '```'
  fi

  # 메모리 / 레포 컨텍스트 (있으면 추가)
  [ -n "$memory" ] && echo "" && echo "## Domain Memory" && echo "$memory"
  [ -n "$repo_context" ] && echo "" && echo "## Repository Context" && echo "$repo_context"
}
```

> 프롬프트 템플릿은 `config/generals/templates/{general-domain}.md`에 위치. 각 장군이 도메인별 지시사항과 CC Plugin 커맨드를 템플릿에 포함한다.
>
> **출력 요구사항은 프롬프트에 포함하지 않는다.** `workspace/CLAUDE.md`가 결과 스키마와 Write 도구 사용을 지시하므로, 프롬프트 템플릿에서 별도로 출력 형식을 지시할 필요 없다.
>
> **예시: gen-pr의 prompt.md** — 커맨드 호출 한 줄로 끝남:
> ```
> /friday:review-pr {{payload.pr_number}}
> ```

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

  # ── CC Plugin 검증 (전역 enabledPlugins 확인) ──
  local manifest="$BASE_DIR/config/generals/${general}.yaml"
  if [ ! -f "$manifest" ]; then
    log "[ERROR] [$general] Manifest not found: $manifest"
    return 1
  fi

  local plugin_count=$(yq eval '.cc_plugins | length' "$manifest" 2>/dev/null || echo "0")

  if (( plugin_count > 0 )); then
    local global_settings="$HOME/.claude/settings.json"
    if [ ! -f "$global_settings" ]; then
      log "[ERROR] [$general] ~/.claude/settings.json not found"
      return 1
    fi

    local i=0
    while (( i < plugin_count )); do
      local required_name
      required_name=$(yq eval ".cc_plugins[$i]" "$manifest")
      local found
      found=$(jq -r --arg n "$required_name" \
        '.enabledPlugins // {} | keys[] | select(startswith($n + "@") or . == $n)' \
        "$global_settings" | head -1)
      if [ -z "$found" ]; then
        log "[ERROR] [$general] Required plugin not enabled globally: $required_name"
        return 1
      fi
      i=$((i + 1))
    done
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

> **전역 플러그인 검증**: 매니페스트의 `cc_plugins` 배열에 선언된 플러그인이 `~/.claude/settings.json`의 `enabledPlugins` 객체에 등록되어 있는지 확인한다. `enabledPlugins`는 `{"friday@qp-plugin": true}` 형식의 객체이며, 키의 접두사(`name@`)로 매칭한다.

---

## CC Plugin 통합

병사의 도구는 CC Plugin(friday, sunday 등)이다. 플러그인은 **전역 설치** (`~/.claude/settings.json`의 `enabledPlugins`)로 관리한다.

### 전역 플러그인 설정

플러그인은 마켓플레이스를 통해 설치하며, `~/.claude/settings.json`의 `enabledPlugins` 객체에 등록된다.

```bash
# 마켓플레이스 등록 + 플러그인 설치
claude plugin marketplace add eddy-jeon/qp-plugin
claude plugin install friday@qp-plugin
```

```json
// ~/.claude/settings.json
{
  "enabledPlugins": {
    "friday@qp-plugin": true,
    "sunday@qp-plugin": true
  }
}
```

### 메커니즘

1. 장군 매니페스트에 `cc_plugins` 배열로 필요한 플러그인 선언 (`name@marketplace` 형식)
2. `ensure_workspace()`가 전역 settings에 해당 플러그인이 등록되어 있는지 검증 (객체 키 접두사 매칭)
3. 병사가 `cd '$WORK_DIR' && claude -p`로 실행되면 전역 CC Plugin이 자동 로드
4. 장군의 `build_prompt()`에서 `--plugin` CLI 파라미터 불필요
5. CC Plugin 사용법(커맨드, 워크플로우)은 **프롬프트 템플릿에 포함**
6. 장군 패키지의 `install.sh`가 CC Plugin 마켓플레이스 등록 + 설치를 자동 수행

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
| `{task-id}-raw.json` | 병사 (Write 도구) | 장군 | CLAUDE.md 지시에 따른 구조화 결과 |
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
| gen-pr | friday@qp-plugin | PR 리뷰 |
| gen-jira | sunday@qp-plugin | Jira 티켓 구현 |
| gen-test | saturday@qp-plugin | 테스트 코드 작성 |

### gen-pr: PR Review 장군

| 항목 | 값 |
|------|-----|
| tmux 세션 | `gen-pr` |
| CC Plugin | friday@qp-plugin |
| 구독 이벤트 | `github.pr.review_requested` |
| 전문 메모리 | 레포별 리뷰 패턴, 팀별 코드 스타일 |
| 병사 수 | 1 (순차 처리) |

**프롬프트 (prompt.md)**: `/friday:review-pr {{payload.pr_number}}`

병사가 실행되면 CC Plugin의 `/friday:review-pr` 커맨드가 직접 호출된다. 프롬프트에는 커맨드와 파라미터만 있으면 충분하다 — 리뷰 로직은 friday 플러그인 내부에 있다.

**워크플로우**:
```
task.json 수신 (github.pr.review_requested)
  → 레포 메모리 로딩 (이 프로젝트의 리뷰 기준은?)
  → 프롬프트 조립: /friday:review-pr 42  ({{payload.pr_number}} 치환)
  → 병사 실행: claude -p (CLAUDE.md가 결과 보고 방식 지시)
    → friday 플러그인의 /review-pr 커맨드가 PR 리뷰 수행 + 자체 품질 루프
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

### gen-test: Test Code 장군

> 스케줄 기반 장군의 예시.

| 항목 | 값 |
|------|-----|
| tmux 세션 | `gen-test` |
| CC Plugin | saturday@qp-plugin |
| 구독 이벤트 | 없음 (스케줄 전용) |
| 스케줄 | 평일 22:00 (cron: `0 22 * * 1-5`) |
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
| CC Plugin | sunday@qp-plugin |
| 구독 이벤트 | `jira.ticket.assigned`, `jira.ticket.updated` |
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

새 장군은 **패키지** 단위로 만들고 `install-general.sh`로 설치한다:

1. **패키지 디렉토리 생성**: `manifest.yaml` + `prompt.md` + `install.sh` + `README.md`
2. **CC Plugin 전역 설치** (필요 시): `claude plugin install /path/to/plugin`
3. **설치**: `./install.sh` 실행 (또는 `install-general.sh` 직접 호출)
4. **Kingdom 재시작**: `start.sh` — 왕이 새 매니페스트를 자동 인식

패키지 포맷:
```
gen-docs/
├── manifest.yaml    # 매니페스트 (이벤트 구독, 플러그인, 타임아웃)
├── prompt.md        # 병사 지시용 프롬프트 템플릿
├── install.sh       # 설치 스크립트 (Kingdom의 install-general.sh 호출)
└── README.md        # 설치 가이드 + 사용법
```

```yaml
# manifest.yaml (예: 문서 작성 장군)
name: gen-docs
description: "문서 작성 장군"

cc_plugins:
  - doc-writer@my-marketplace    # plugin-name@marketplace 형식

subscribes: []    # 외부 이벤트 구독 없음 — 순수 스케줄 기반

schedules:
  - name: docs-update
    cron: "0 2 * * 1"
    task_type: "docs-generation"
    payload: {}
```

```bash
# install.sh (패키지 안 — CC Plugin 설치 + Kingdom 설치)
#!/usr/bin/env bash
set -euo pipefail
KINGDOM_BASE_DIR="${KINGDOM_BASE_DIR:-/opt/kingdom}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"

# CC Plugin 자동 설치 (각 장군이 필요한 플러그인을 직접 준비)
if command -v claude &>/dev/null; then
  # 마켓플레이스 등록 + 플러그인 설치
  claude plugin marketplace add owner/my-marketplace 2>/dev/null || true
  claude plugin install doc-writer@my-marketplace 2>/dev/null || true
fi

exec "$KINGDOM_BASE_DIR/bin/install-general.sh" "$PACKAGE_DIR" "$@"
```

> `install-general.sh`가 매니페스트 복사, 프롬프트 템플릿 복사, 엔트리 스크립트 자동 생성, 런타임 디렉토리 생성을 모두 처리한다.
> 왕/센티널 코드 수정 불필요 — 매니페스트만 추가하면 왕이 자동 인식.
>
> **시나리오 참고**: [docs/examples/](../examples/)에 이벤트 기반(gen-pr)과 스케줄 기반(gen-test) 장군의 전체 동작 시나리오가 있다

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
| CC Plugin 전역 미등록 | ensure_workspace에서 enabledPlugins 검증 실패 → task failed |
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
generals/                                # 장군 패키지 (소스)
├── gen-pr/                              # manifest.yaml + prompt.md + install.sh + README.md
├── gen-jira/
└── gen-test/

bin/generals/                            # 엔트리 스크립트 (install-general.sh가 자동 생성)
├── gen-pr.sh                            # GENERAL_DOMAIN="gen-pr" + main_loop
├── gen-test.sh
└── gen-jira.sh

bin/lib/general/
├── common.sh                            # main_loop, pick_next_task, spawn_soldier,
│                                        # wait_for_soldier, report_to_king,
│                                        # escalate_to_king, ensure_workspace,
│                                        # load_domain_memory, load_repo_memory,
│                                        # update_memory
└── prompt-builder.sh                    # build_prompt

bin/install-general.sh                   # 패키지 → 런타임 설치
bin/uninstall-general.sh                 # 장군 정의 제거

config/generals/                         # 런타임 매니페스트 (install-general.sh가 복사)
├── gen-pr.yaml / gen-jira.yaml / gen-test.yaml
└── templates/                           # 프롬프트 템플릿
    ├── gen-pr.md / gen-jira.md / gen-test.md
    └── default.md                       # fallback 템플릿
```

---

## 관련 문서

- [roles/king.md](king.md) — 장군에게 task 배정, 최종 결과 처리 (재시도는 장군 전담)
- [roles/soldier.md](soldier.md) — 병사 생명주기, raw 결과 출력
- [systems/filesystem.md](../systems/filesystem.md) — workspace 디렉토리 구조
- [systems/message-passing.md](../systems/message-passing.md) — 이벤트/작업 큐 구조
- [examples/scenario-gen-pr.md](../examples/scenario-gen-pr.md) — 이벤트 기반 장군 동작 시나리오 (6건)
- [examples/scenario-gen-test.md](../examples/scenario-gen-test.md) — 스케줄 기반 장군 동작 시나리오 (5건)

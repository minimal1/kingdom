#!/usr/bin/env bash
# Kingdom Test Helper
# 모든 테스트 파일에서 source하는 공통 설정

# bats helpers - 프로젝트 루트 기준 절대경로 사용
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_ROOT/test_helpers/bats-support/load.bash"
source "$TESTS_ROOT/test_helpers/bats-assert/load.bash"

# 테스트용 임시 디렉토리를 BASE_DIR로 사용
setup_kingdom_env() {
  export BASE_DIR="$(mktemp -d)"
  export KINGDOM_BASE_DIR="$BASE_DIR"
  export PATH="${TESTS_ROOT}/mocks:$PATH"

  # 기본 디렉토리 생성
  mkdir -p "$BASE_DIR"/{bin/lib,config/generals/templates,logs/sessions,logs/analysis}
  mkdir -p "$BASE_DIR"/queue/{events,tasks,messages}/{pending,completed}
  mkdir -p "$BASE_DIR"/queue/events/dispatched
  mkdir -p "$BASE_DIR"/queue/tasks/in_progress
  mkdir -p "$BASE_DIR"/queue/messages/sent
  mkdir -p "$BASE_DIR"/state/{king,sentinel/seen,envoy,chamberlain,results,prompts}
  mkdir -p "$BASE_DIR"/memory/shared

  # 장군 디렉토리 (테스트 공통)
  local generals=("gen-pr" "gen-jira" "gen-test")
  for g in "${generals[@]}"; do
    mkdir -p "$BASE_DIR/memory/generals/$g"
    mkdir -p "$BASE_DIR/workspace/$g"
  done

  # workspace/CLAUDE.md 생성 (테스트 환경)
  echo "# Kingdom Soldier (test)" > "$BASE_DIR/workspace/CLAUDE.md"
}

teardown_kingdom_env() {
  if [[ -n "$BASE_DIR" && "$BASE_DIR" == /tmp/* ]]; then
    rm -rf "$BASE_DIR"
  fi
}

# 패키지에서 장군 매니페스트를 테스트 환경에 설치
install_test_general() {
  local name="$1"
  local project_root="${TESTS_ROOT}/.."
  mkdir -p "$BASE_DIR/config/generals/templates"
  cp "$project_root/generals/$name/manifest.yaml" "$BASE_DIR/config/generals/${name}.yaml"
  if [ -f "$project_root/generals/$name/prompt.md" ]; then
    cp "$project_root/generals/$name/prompt.md" "$BASE_DIR/config/generals/templates/${name}.md"
  fi
}

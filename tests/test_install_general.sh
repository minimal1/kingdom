#!/usr/bin/env bats
# install-general.sh / uninstall-general.sh tests

setup() {
  load 'test_helper'
  setup_kingdom_env

  # install-general.sh needs common.sh at runtime
  mkdir -p "$BASE_DIR/bin/lib"
  cp "${BATS_TEST_DIRNAME}/../bin/lib/common.sh" "$BASE_DIR/bin/lib/"
  cp "${BATS_TEST_DIRNAME}/../bin/install-general.sh" "$BASE_DIR/bin/"
  cp "${BATS_TEST_DIRNAME}/../bin/uninstall-general.sh" "$BASE_DIR/bin/"
  chmod +x "$BASE_DIR/bin/install-general.sh" "$BASE_DIR/bin/uninstall-general.sh"

  # Create a valid test package
  TEST_PKG="$(mktemp -d)"
  cat > "$TEST_PKG/manifest.yaml" << 'EOF'
name: gen-foo
description: "Test general"
timeout_seconds: 600
cc_plugins: []
subscribes:
  - test.event.foo
schedules: []
EOF
  echo "# Test prompt" > "$TEST_PKG/prompt.md"
}

teardown() {
  teardown_kingdom_env
  [ -n "$TEST_PKG" ] && rm -rf "$TEST_PKG"
}

# --- install-general.sh ---

@test "install: valid package installs successfully" {
  run "$BASE_DIR/bin/install-general.sh" "$TEST_PKG"
  assert_success
  assert_output --partial "Installed general: gen-foo"

  # 3 files created
  assert [ -f "$BASE_DIR/config/generals/gen-foo.yaml" ]
  assert [ -f "$BASE_DIR/config/generals/templates/gen-foo.md" ]
  assert [ -f "$BASE_DIR/bin/generals/gen-foo.sh" ]
}

@test "install: creates runtime directories" {
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  assert [ -d "$BASE_DIR/state/gen-foo" ]
  assert [ -d "$BASE_DIR/memory/generals/gen-foo" ]
  assert [ -d "$BASE_DIR/workspace/gen-foo" ]
}

@test "install: generated entry script contains GENERAL_DOMAIN" {
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  run cat "$BASE_DIR/bin/generals/gen-foo.sh"
  assert_output --partial 'GENERAL_DOMAIN="gen-foo"'
  assert_output --partial 'source "$BASE_DIR/bin/lib/common.sh"'
  assert_output --partial 'main_loop'
}

@test "install: entry script is executable" {
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  assert [ -x "$BASE_DIR/bin/generals/gen-foo.sh" ]
}

@test "install: fails without manifest.yaml" {
  local bad_pkg="$(mktemp -d)"
  echo "# prompt" > "$bad_pkg/prompt.md"
  run "$BASE_DIR/bin/install-general.sh" "$bad_pkg"
  assert_failure
  assert_output --partial "manifest.yaml not found"
  rm -rf "$bad_pkg"
}

@test "install: fails without prompt.md" {
  local bad_pkg="$(mktemp -d)"
  cat > "$bad_pkg/manifest.yaml" << 'EOF'
name: gen-bar
subscribes: []
schedules: []
EOF
  run "$BASE_DIR/bin/install-general.sh" "$bad_pkg"
  assert_failure
  assert_output --partial "prompt.md not found"
  rm -rf "$bad_pkg"
}

@test "install: fails with invalid name format" {
  local bad_pkg="$(mktemp -d)"
  cat > "$bad_pkg/manifest.yaml" << 'EOF'
name: bad_name
subscribes: []
schedules: []
EOF
  echo "# prompt" > "$bad_pkg/prompt.md"
  run "$BASE_DIR/bin/install-general.sh" "$bad_pkg"
  assert_failure
  assert_output --partial "Invalid name"
  rm -rf "$bad_pkg"
}

@test "install: name conflict without --force fails" {
  # First install succeeds
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  # Second install without --force fails
  run "$BASE_DIR/bin/install-general.sh" "$TEST_PKG"
  assert_failure
  assert_output --partial "already installed"
}

@test "install: --force overwrites existing" {
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  run "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" "--force"
  assert_success
  assert_output --partial "Installed general: gen-foo"
}

@test "install: event conflict with another general fails" {
  # Install first general claiming test.event.foo
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null

  # Create second package claiming the same event
  local conflict_pkg="$(mktemp -d)"
  cat > "$conflict_pkg/manifest.yaml" << 'EOF'
name: gen-bar
description: "Conflicting general"
cc_plugins: []
subscribes:
  - test.event.foo
schedules: []
EOF
  echo "# prompt" > "$conflict_pkg/prompt.md"

  run "$BASE_DIR/bin/install-general.sh" "$conflict_pkg"
  assert_failure
  assert_output --partial "already claimed by gen-foo"
  rm -rf "$conflict_pkg"
}

# --- uninstall-general.sh ---

@test "uninstall: removes definition files" {
  "$BASE_DIR/bin/install-general.sh" "$TEST_PKG" > /dev/null
  run "$BASE_DIR/bin/uninstall-general.sh" "gen-foo"
  assert_success
  assert_output --partial "Uninstalled: gen-foo"

  # Definition files removed
  assert [ ! -f "$BASE_DIR/config/generals/gen-foo.yaml" ]
  assert [ ! -f "$BASE_DIR/config/generals/templates/gen-foo.md" ]
  assert [ ! -f "$BASE_DIR/bin/generals/gen-foo.sh" ]

  # Runtime data preserved
  assert [ -d "$BASE_DIR/state/gen-foo" ]
  assert [ -d "$BASE_DIR/memory/generals/gen-foo" ]
  assert [ -d "$BASE_DIR/workspace/gen-foo" ]
}

@test "uninstall: fails for non-installed general" {
  run "$BASE_DIR/bin/uninstall-general.sh" "gen-nonexistent"
  assert_failure
  assert_output --partial "not installed"
}

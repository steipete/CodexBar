#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-app-paths.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

ROOT_RESOLVED=$(cd "$ROOT" && pwd -P)

validate_package_app_path() {
  local label="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    echo "ERROR: $label is empty." >&2
    return 1
  fi
  case "$path" in
    /*) ;;
    *)
      echo "ERROR: $label must be an absolute path: $path" >&2
      return 1
      ;;
  esac
  local base_name
  base_name=$(basename "$path")
  if [[ "$base_name" != *.app ]]; then
    echo "ERROR: $label must point to a .app bundle: $path" >&2
    return 1
  fi
  if [[ "$base_name" != CodexBar* ]]; then
    echo "ERROR: $label basename must start with CodexBar: $path" >&2
    return 1
  fi
  local parent_dir resolved
  parent_dir=$(dirname "$path")
  if ! resolved=$(cd "$parent_dir" 2>/dev/null && pwd -P); then
    mkdir -p "$parent_dir"
    resolved=$(cd "$parent_dir" && pwd -P)
  fi
  resolved="$resolved/$base_name"
  if [[ "$resolved" == "$ROOT_RESOLVED" ]]; then
    echo "ERROR: $label must not target the repo root: $path" >&2
    return 1
  fi
  case "$resolved" in
    "$ROOT_RESOLVED"/*) ;;
    *)
      echo "ERROR: $label must stay inside the repo root ($ROOT_RESOLVED): $path" >&2
      return 1
      ;;
  esac
}

passes=0
assert_rejects() {
  local label="$1"
  local path="$2"
  if validate_package_app_path "$label" "$path" 2>"$TEMP_DIR/reject.log"; then
    echo "ERROR: expected rejection for $label=$path" >&2
    exit 1
  fi
  passes=$((passes + 1))
}

assert_accepts() {
  local label="$1"
  local path="$2"
  validate_package_app_path "$label" "$path"
  passes=$((passes + 1))
}

assert_accepts "default output" "$ROOT/CodexBar.app"
assert_accepts "default stage" "$ROOT/.build/package/CodexBar.app"
assert_accepts "custom stage" "$ROOT/.build/package/CodexBar.debug.app"

assert_rejects "empty path" ""
assert_rejects "relative path" "CodexBar.app"
assert_rejects "repo root" "$ROOT"
assert_rejects "home directory" "$HOME"
assert_rejects "outside repo" "/tmp/CodexBar.app"
assert_rejects "non app bundle" "$ROOT/CodexBar.zip"
assert_rejects "wrong basename" "$ROOT/OtherApp.app"

same_stage="$ROOT/.build/package/CodexBar.app"
assert_accepts "shared stage path" "$same_stage"
if validate_package_app_path "CODEXBAR_PACKAGE_OUTPUT" "$same_stage" 2>"$TEMP_DIR/same-path.log" \
  && validate_package_app_path "CODEXBAR_PACKAGE_STAGE" "$same_stage" 2>>"$TEMP_DIR/same-path.log"
then
  ROOT_RESOLVED=$(cd "$ROOT" && pwd -P)
  resolve_path() {
    local path="$1"
    local base_name parent_dir resolved
    base_name=$(basename "$path")
    parent_dir=$(dirname "$path")
    resolved=$(cd "$parent_dir" && pwd -P)
    printf '%s\n' "$resolved/$base_name"
  }
  final_resolved=$(resolve_path "$same_stage")
  stage_resolved=$(resolve_path "$same_stage")
  if [[ "$final_resolved" == "$stage_resolved" ]]; then
  passes=$((passes + 1))
  else
    echo "ERROR: expected identical resolved package paths for rejection test" >&2
    exit 1
  fi
else
  echo "ERROR: expected package path validation to accept identical stage path inputs" >&2
  exit 1
fi

echo "Package app path tests passed ($passes checks)."

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-make-lint.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/Scripts"

cat > "$fixture/bin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$CODEXBAR_TEST_PLATFORM"
SH

cat > "$fixture/Scripts/lint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEXBAR_TEST_LINT_ARGS"
exit "$CODEXBAR_TEST_LINT_STATUS"
SH
chmod +x "$fixture/bin/uname" "$fixture/Scripts/lint.sh"

assert_dispatch() {
  local platform="$1" target="$2" expected="$3" lint_status="${4:-0}"
  local status=0
  PATH="$fixture/bin:$PATH" \
    CODEXBAR_TEST_PLATFORM="$platform" \
    CODEXBAR_TEST_LINT_ARGS="$fixture/args" \
    CODEXBAR_TEST_LINT_STATUS="$lint_status" \
    MAKEFLAGS= MFLAGS= MAKELEVEL=0 \
    make --no-print-directory --file "$ROOT_DIR/Makefile" --directory "$fixture" "$target" \
      > "$fixture/output" 2>&1 || status=$?

  local actual
  actual="$(cat "$fixture/args")"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s make %s: expected %s, got %s\n' "$platform" "$target" "$expected" "$actual" >&2
    exit 1
  fi
  if [[ "$lint_status" == 0 && "$status" != 0 ]] || [[ "$lint_status" != 0 && "$status" == 0 ]]; then
    cat "$fixture/output" >&2
    printf '%s make %s: did not preserve lint success/failure\n' "$platform" "$target" >&2
    exit 1
  fi
}

for target in check lint; do
  assert_dispatch Linux "$target" lint-linux
  assert_dispatch Darwin "$target" lint
  assert_dispatch Linux "$target" lint-linux 23
  assert_dispatch Darwin "$target" lint 23
done

printf 'Make lint platform dispatch and failure propagation tests passed.\n'

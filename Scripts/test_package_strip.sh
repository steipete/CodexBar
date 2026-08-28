#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_SCRIPT="$ROOT/Scripts/package_app.sh"
FUNCTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/codexbar-package-strip-functions.XXXXXX")
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-strip.XXXXXX")
trap 'rm -rf "$FUNCTIONS_FILE" "$TEMP_DIR"' EXIT

python3 - "$PACKAGE_SCRIPT" "$FUNCTIONS_FILE" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
start = script.index('strip_release_binary() {')
end = script.index('\n}\n', start) + 3
Path(sys.argv[2]).write_text(script[start:end])
PY

xcrun() {
  [[ "$1" == "strip" && "$2" == "-x" ]]
  printf '%s\n' "$3" >> "$STRIP_LOG"
}

source "$FUNCTIONS_FILE"

binary="$TEMP_DIR/CodexBar"
touch "$binary"

STRIP_LOG="$TEMP_DIR/release.log"
LOWER_CONF=release
strip_release_binary "$binary"
grep -Fqx "$binary" "$STRIP_LOG"

STRIP_LOG="$TEMP_DIR/debug.log"
LOWER_CONF=debug
strip_release_binary "$binary"
[[ ! -e "$STRIP_LOG" ]]

STRIP_LOG="$TEMP_DIR/missing.log"
LOWER_CONF=release
strip_release_binary "$TEMP_DIR/MissingBinary"
[[ ! -e "$STRIP_LOG" ]]

echo "Package strip tests passed."

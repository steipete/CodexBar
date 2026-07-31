#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_SCRIPT="$ROOT/Scripts/package_app.sh"
FUNCTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/codexbar-package-runtime-functions.XXXXXX")
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-runtime.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"; rm -rf "$TEMP_DIR"' EXIT

python3 - "$PACKAGE_SCRIPT" "$FUNCTIONS_FILE" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
start = script.index('verify_no_dart_flutter_artifacts() {')
end = script.index('\n}\n', start) + 3
Path(sys.argv[2]).write_text(script[start:end])
PY

source "$FUNCTIONS_FILE"

APP="$TEMP_DIR/CodexBar.app"
mkdir -p "$APP/Contents/Frameworks/Sparkle.framework/Versions"
touch "$APP/Contents/Frameworks/Sparkle.framework/Versions/1"
ln -s 1 "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
verify_no_dart_flutter_artifacts "$APP"

mkdir -p "$APP/Contents/Frameworks/Flutter.framework"
if verify_no_dart_flutter_artifacts "$APP" 2>/dev/null; then
  echo "Contaminated Flutter bundle unexpectedly passed integrity verification" >&2
  exit 1
fi

rm -rf "$APP/Contents/Frameworks/Flutter.framework"
mkdir -p "$APP/Contents/Frameworks/dartvm.framework"
if verify_no_dart_flutter_artifacts "$APP" 2>/dev/null; then
  echo "Contaminated Dart bundle unexpectedly passed integrity verification" >&2
  exit 1
fi

rm -rf "$APP/Contents/Frameworks/dartvm.framework"
mkdir -p "$APP/Contents/Frameworks/Runtime"
ln -s /tmp/libflutter_engine.dylib "$APP/Contents/Frameworks/Runtime/libengine.dylib"
if verify_no_dart_flutter_artifacts "$APP" 2>/dev/null; then
  echo "External linked runtime unexpectedly passed integrity verification" >&2
  exit 1
fi

echo "Package runtime integrity tests passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_SCRIPT="$ROOT/Scripts/package_app.sh"
RELEASE_SCRIPT="$ROOT/Scripts/sign-and-notarize.sh"
FUNCTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/codexbar-package-signing-functions.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"' EXIT

python3 - "$PACKAGE_SCRIPT" "$FUNCTIONS_FILE" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
functions = []
for name in (
    'resolve_package_signing_mode',
    'verify_no_quarantine_attribute',
    'verify_packaged_app_integrity',
):
    start = script.index(f'{name}() {{')
    end = script.index('\n}\n', start) + 3
    functions.append(script[start:end])
Path(sys.argv[2]).write_text('\n\n'.join(functions))
PY

source "$FUNCTIONS_FILE"

unset CODEXBAR_SIGNING
SIGNING_MODE=
resolve_package_signing_mode
[[ "$SIGNING_MODE" == "adhoc" ]]

CODEXBAR_SIGNING=identity
resolve_package_signing_mode
[[ "$SIGNING_MODE" == "identity" ]]

CODEXBAR_SIGNING=invalid
if resolve_package_signing_mode 2>/dev/null; then
  echo "Invalid package signing mode unexpectedly succeeded" >&2
  exit 1
fi

grep -Fq 'CODEXBAR_SIGNING=identity ./Scripts/package_app.sh release' "$RELEASE_SCRIPT"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-signing.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"; rm -rf "$TEMP_DIR"' EXIT
APP="$TEMP_DIR/CodexBar.app"
mkdir -p "$APP/Contents/Frameworks/Sparkle.framework"

xattr() {
  if [[ "${MOCK_QUARANTINE:-0}" == "1" ]]; then
    printf '0081;fake;Safari;https://example.invalid\n'
    return 0
  fi
  return 1
}

codesign() {
  return "${MOCK_CODESIGN_STATUS:-0}"
}

verify_packaged_app_integrity "$APP"

export MOCK_QUARANTINE=1
if verify_packaged_app_integrity "$APP" 2>/dev/null; then
  echo "Quarantined app unexpectedly passed integrity verification" >&2
  exit 1
fi
unset MOCK_QUARANTINE

export MOCK_CODESIGN_STATUS=1
if verify_packaged_app_integrity "$APP" 2>/dev/null; then
  echo "App with an invalid signature unexpectedly passed integrity verification" >&2
  exit 1
fi
unset MOCK_CODESIGN_STATUS

echo "Package signing tests passed."

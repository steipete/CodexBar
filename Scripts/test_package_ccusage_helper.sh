#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_SCRIPT="$ROOT/Scripts/package_app.sh"
FUNCTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/codexbar-package-ccusage-functions.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"' EXIT

python3 - "$PACKAGE_SCRIPT" "$FUNCTIONS_FILE" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
functions = []
for name in ("verify_binary_arches", "install_optional_ccusage_helper"):
    start = script.index(f"{name}() {{")
    end = script.index("\n}\n", start) + 3
    functions.append(script[start:end])
Path(sys.argv[2]).write_text("\n\n".join(functions))
PY

source "$FUNCTIONS_FILE"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-ccusage.XXXXXX")
trap 'rm -f "$FUNCTIONS_FILE"; rm -rf "$TEMP_DIR"' EXIT
APP="$TEMP_DIR/CodexBar.app"
SOURCE="$TEMP_DIR/ccusage"
mkdir -p "$APP/Contents/Helpers"
printf '#!/bin/sh\nexit 0\n' >"$SOURCE"
chmod 755 "$SOURCE"

lipo() {
  printf 'arm64 x86_64\n'
}

ARCH_LIST=(arm64 x86_64)
CODEXBAR_CCUSAGE_SOURCE="$SOURCE"
CODEXBAR_REQUIRE_CCUSAGE=1
CODEXBAR_CCUSAGE_VERSION="20.0.19"
CODEXBAR_CCUSAGE_SHA256="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
install_optional_ccusage_helper
[[ -x "$APP/Contents/Helpers/ccusage" ]]
cmp -s "$SOURCE" "$APP/Contents/Helpers/ccusage"
grep -Fq "version=20.0.19" "$APP/Contents/Helpers/ccusage.provenance"
grep -Fq "sha256=$CODEXBAR_CCUSAGE_SHA256" "$APP/Contents/Helpers/ccusage.provenance"

rm -f "$APP/Contents/Helpers/ccusage" "$APP/Contents/Helpers/ccusage.provenance"
unset CODEXBAR_CCUSAGE_SOURCE
CODEXBAR_REQUIRE_CCUSAGE=0
install_optional_ccusage_helper
[[ ! -e "$APP/Contents/Helpers/ccusage" ]]
[[ ! -e "$APP/Contents/Helpers/ccusage.provenance" ]]

CODEXBAR_REQUIRE_CCUSAGE=1
if install_optional_ccusage_helper 2>"$TEMP_DIR/missing-source.log"; then
  echo "Missing required ccusage source unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq "requires CODEXBAR_CCUSAGE_SOURCE" "$TEMP_DIR/missing-source.log"

CODEXBAR_CCUSAGE_SOURCE="$TEMP_DIR/missing"
CODEXBAR_REQUIRE_CCUSAGE=0
if install_optional_ccusage_helper 2>"$TEMP_DIR/missing-file.log"; then
  echo "Missing ccusage file unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq "is not a file" "$TEMP_DIR/missing-file.log"

CODEXBAR_CCUSAGE_SOURCE="$SOURCE"
CODEXBAR_CCUSAGE_SHA256="$(printf '0%.0s' {1..64})"
if install_optional_ccusage_helper 2>"$TEMP_DIR/hash.log"; then
  echo "SHA-256 mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq "SHA-256 mismatch" "$TEMP_DIR/hash.log"

CODEXBAR_CCUSAGE_SOURCE="$SOURCE"
CODEXBAR_REQUIRE_CCUSAGE=0
CODEXBAR_CCUSAGE_SHA256="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
lipo() {
  printf 'arm64\n'
}
if (install_optional_ccusage_helper) 2>"$TEMP_DIR/arch.log"; then
  echo "Architecture mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq "arch mismatch" "$TEMP_DIR/arch.log"

echo "Package ccusage helper tests passed."

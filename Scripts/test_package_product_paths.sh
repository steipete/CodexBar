#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/package_product_paths.sh"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-paths.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

NATIVE_DIR="$TEMP_DIR/.build/arm64-apple-macosx/release"
SWIFTBUILD_DIR="$TEMP_DIR/.build/out/Products/Release"
STAGE_ROOT="$TEMP_DIR/.build/package-products/release"
mkdir -p "$NATIVE_DIR/CodexBar.dSYM" "$SWIFTBUILD_DIR/Sparkle.framework" "$SWIFTBUILD_DIR/CodexBar.dSYM"
touch "$NATIVE_DIR/CodexBar" "$SWIFTBUILD_DIR/CodexBar"

native=$(codexbar_require_product_file "$NATIVE_DIR" CodexBar arm64)
[[ "$native" == "$NATIVE_DIR/CodexBar" ]]

swiftbuild=$(codexbar_require_product_file "$SWIFTBUILD_DIR" CodexBar arm64)
[[ "$swiftbuild" == "$SWIFTBUILD_DIR/CodexBar" ]]

framework=$(codexbar_require_product_directory "$SWIFTBUILD_DIR" Sparkle.framework packaging)
[[ "$framework" == "$SWIFTBUILD_DIR/Sparkle.framework" ]]

dsym=$(codexbar_require_product_directory "$SWIFTBUILD_DIR" CodexBar.dSYM release)
[[ "$dsym" == "$SWIFTBUILD_DIR/CodexBar.dSYM" ]]

resolved=$(codexbar_resolve_staged_or_reported_file "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64)
[[ "$resolved" == "$SWIFTBUILD_DIR/CodexBar" ]]

resolved_dsym=$(codexbar_resolve_dsym_path "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64)
[[ "$resolved_dsym" == "$SWIFTBUILD_DIR/CodexBar.dSYM" ]]

mkdir -p "$STAGE_ROOT/arm64/CodexBar.dSYM"
touch "$STAGE_ROOT/arm64/CodexBar"
staged=$(codexbar_resolve_staged_or_reported_file "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64)
[[ "$staged" == "$STAGE_ROOT/arm64/CodexBar" ]]
staged_dsym=$(codexbar_resolve_dsym_path "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64)
[[ "$staged_dsym" == "$STAGE_ROOT/arm64/CodexBar.dSYM" ]]

rm -rf "$STAGE_ROOT"
rm "$SWIFTBUILD_DIR/CodexBar"
if codexbar_resolve_staged_or_reported_file "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64 \
  2>"$TEMP_DIR/missing-file.log"; then
  echo "ERROR: Missing reported product unexpectedly fell back to legacy output." >&2
  exit 1
fi
grep -Fq "$SWIFTBUILD_DIR/CodexBar" "$TEMP_DIR/missing-file.log"

rm -rf "$SWIFTBUILD_DIR/Sparkle.framework"
if codexbar_require_product_directory "$SWIFTBUILD_DIR" Sparkle.framework packaging \
  2>"$TEMP_DIR/missing-directory.log"; then
  echo "ERROR: Missing reported framework was accepted." >&2
  exit 1
fi
grep -Fq "$SWIFTBUILD_DIR/Sparkle.framework" "$TEMP_DIR/missing-directory.log"

rm -rf "$SWIFTBUILD_DIR/CodexBar.dSYM"
if codexbar_resolve_dsym_path "$STAGE_ROOT" "$SWIFTBUILD_DIR" CodexBar arm64 \
  2>"$TEMP_DIR/missing-dsym.log"; then
  echo "ERROR: Missing reported dSYM unexpectedly fell back to legacy output." >&2
  exit 1
fi
grep -Fq "$SWIFTBUILD_DIR/CodexBar.dSYM" "$TEMP_DIR/missing-dsym.log"

swift() {
  [[ "$*" == "build --show-bin-path -c release --arch arm64" ]]
  printf '%s\n' "$SWIFTBUILD_DIR"
}
reported=$(codexbar_swiftpm_bin_path release arm64)
[[ "$reported" == "$SWIFTBUILD_DIR" ]]

swift() {
  return 23
}
if codexbar_swiftpm_bin_path release arm64 2>"$TEMP_DIR/query.log"; then
  echo "ERROR: SwiftPM bin-path query failure was ignored." >&2
  exit 1
fi
grep -Fq "SwiftPM failed to report" "$TEMP_DIR/query.log"

swift() {
  return 0
}
if codexbar_swiftpm_bin_path release arm64 2>"$TEMP_DIR/empty.log"; then
  echo "ERROR: Empty SwiftPM bin path was accepted." >&2
  exit 1
fi
grep -Fq "SwiftPM reported an empty" "$TEMP_DIR/empty.log"

# Exercise the real staging boundary with the SDK metadata emitted by SwiftBuild.
python3 - "$ROOT/Scripts/package_app.sh" "$TEMP_DIR/staging.sh" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text()
start = script.index('stage_build_products() {')
end = script.index('\n}\n', start) + 3
Path(sys.argv[2]).write_text(script[start:end])
PY
source "$TEMP_DIR/staging.sh"
swiftpm_bin_path() { printf -v "$2" '%s' "$SWIFTBUILD_DIR"; }
binary_has_arch() { return 0; }
otool() {
  printf '      cmd LC_BUILD_VERSION\n    minos %s\n      sdk %s\n' "$MOCK_MINOS" "$MOCK_SDK"
}
touch "$SWIFTBUILD_DIR/CodexBar" "$SWIFTBUILD_DIR/CodexBarCLI" "$SWIFTBUILD_DIR/CodexBarClaudeWatchdog"
PRODUCT_STAGE_ROOT="$STAGE_ROOT"
SDK_VERSION=27.2
MOCK_MINOS=14.0
MOCK_SDK=14.0
if stage_build_products arm64 2>"$TEMP_DIR/metadata.log"; then
  echo "ERROR: Staging accepted the deployment target as the linked SDK." >&2
  exit 1
fi
MOCK_SDK="$SDK_VERSION"
MOCK_MINOS=27.0
if stage_build_products arm64 2>"$TEMP_DIR/metadata.log"; then
  echo "ERROR: Staging accepted a raised minimum macOS version." >&2
  exit 1
fi
MOCK_MINOS=14.0
stage_build_products arm64
for name in CodexBar CodexBarCLI CodexBarClaudeWatchdog; do
  [[ -f "$STAGE_ROOT/arm64/$name" ]]
done

echo "Package product path and SDK metadata tests passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/sparkle_signing_paths.sh"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-sparkle-signing.XXXXXX")
TEMP_DIR=$(cd "$TEMP_DIR" && pwd -P)
trap 'rm -rf "$TEMP_DIR"' EXIT

make_sparkle_version() {
  local sparkle="$1"
  local version="$2"
  local version_dir="$sparkle/Versions/$version"

  mkdir -p \
    "$version_dir/Updater.app/Contents/MacOS" \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS"
  touch \
    "$version_dir/Sparkle" \
    "$version_dir/Autoupdate" \
    "$version_dir/Updater.app/Contents/MacOS/Updater" \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"
}

SINGLE="$TEMP_DIR/Single Sparkle.framework"
make_sparkle_version "$SINGLE" B
single_version=$(codexbar_sparkle_version_dir "$SINGLE")
[[ "$single_version" == "$SINGLE/Versions/B" ]]

single_targets=$(codexbar_sparkle_signing_targets "$SINGLE")
grep -Fqx "$SINGLE" <<<"$single_targets"
grep -Fqx "$SINGLE/Versions/B/Sparkle" <<<"$single_targets"
grep -Fqx "$SINGLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" <<<"$single_targets"

CURRENT="$TEMP_DIR/Current Sparkle.framework"
make_sparkle_version "$CURRENT" A
make_sparkle_version "$CURRENT" C
ln -s C "$CURRENT/Versions/Current"
current_version=$(codexbar_sparkle_version_dir "$CURRENT")
[[ "$current_version" == "$CURRENT/Versions/C" ]]

rm "$CURRENT/Versions/C/Autoupdate"
if codexbar_sparkle_signing_targets "$CURRENT" >"$TEMP_DIR/missing-target.out" 2>"$TEMP_DIR/missing-target.log"; then
  echo "ERROR: Missing Sparkle signing target was accepted." >&2
  exit 1
fi
grep -Fq "Autoupdate" "$TEMP_DIR/missing-target.log"

AMBIGUOUS="$TEMP_DIR/Ambiguous Sparkle.framework"
make_sparkle_version "$AMBIGUOUS" A
make_sparkle_version "$AMBIGUOUS" B
if codexbar_sparkle_version_dir "$AMBIGUOUS" 2>"$TEMP_DIR/ambiguous.log"; then
  echo "ERROR: Ambiguous Sparkle versions were accepted without Versions/Current." >&2
  exit 1
fi
grep -Fq "multiple version directories" "$TEMP_DIR/ambiguous.log"

echo "Sparkle signing path tests passed."

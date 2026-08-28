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

BROKEN_CURRENT="$TEMP_DIR/Broken Current Sparkle.framework"
make_sparkle_version "$BROKEN_CURRENT" B
ln -s Missing "$BROKEN_CURRENT/Versions/Current"
if codexbar_sparkle_version_dir "$BROKEN_CURRENT" 2>"$TEMP_DIR/broken-current.log"; then
  echo "ERROR: Broken Sparkle Versions/Current was accepted." >&2
  exit 1
fi
grep -Fq "Versions/Current does not resolve" "$TEMP_DIR/broken-current.log"

ESCAPING_CURRENT="$TEMP_DIR/Escaping Current Sparkle.framework"
OUTSIDE_SPARKLE="$TEMP_DIR/Outside Sparkle.framework"
make_sparkle_version "$ESCAPING_CURRENT" B
make_sparkle_version "$OUTSIDE_SPARKLE" C
ln -s "$OUTSIDE_SPARKLE/Versions/C" "$ESCAPING_CURRENT/Versions/Current"
if codexbar_sparkle_version_dir "$ESCAPING_CURRENT" 2>"$TEMP_DIR/escaping-current.log"; then
  echo "ERROR: Escaping Sparkle Versions/Current was accepted." >&2
  exit 1
fi
grep -Fq "outside the framework versions directory" "$TEMP_DIR/escaping-current.log"

SYMLINKED_VERSIONS="$TEMP_DIR/Symlinked Versions Sparkle.framework"
mkdir -p "$SYMLINKED_VERSIONS"
ln -s "$OUTSIDE_SPARKLE/Versions" "$SYMLINKED_VERSIONS/Versions"
if codexbar_sparkle_version_dir "$SYMLINKED_VERSIONS" 2>"$TEMP_DIR/symlinked-versions.log"; then
  echo "ERROR: Symlinked Sparkle Versions directory was accepted." >&2
  exit 1
fi
grep -Fq "versions directory must not be a symlink" "$TEMP_DIR/symlinked-versions.log"

SYMLINKED_FRAMEWORK="$TEMP_DIR/Symlinked Sparkle.framework"
ln -s "$OUTSIDE_SPARKLE" "$SYMLINKED_FRAMEWORK"
if codexbar_sparkle_version_dir "$SYMLINKED_FRAMEWORK" 2>"$TEMP_DIR/symlinked-framework.log"; then
  echo "ERROR: Symlinked Sparkle framework root was accepted." >&2
  exit 1
fi
grep -Fq "framework root must not be a symlink" "$TEMP_DIR/symlinked-framework.log"

SYMLINKED_TARGET="$TEMP_DIR/Symlinked Target Sparkle.framework"
make_sparkle_version "$SYMLINKED_TARGET" B
rm "$SYMLINKED_TARGET/Versions/B/Autoupdate"
ln -s "$OUTSIDE_SPARKLE/Versions/C/Autoupdate" "$SYMLINKED_TARGET/Versions/B/Autoupdate"
if codexbar_sparkle_signing_targets \
  "$SYMLINKED_TARGET" >"$TEMP_DIR/symlinked-target.out" 2>"$TEMP_DIR/symlinked-target.log"; then
  echo "ERROR: Symlinked Sparkle signing target was accepted." >&2
  exit 1
fi
grep -Fq "signing target must not be a symlink" "$TEMP_DIR/symlinked-target.log"

ESCAPING_TARGET_PARENT="$TEMP_DIR/Escaping Target Parent Sparkle.framework"
make_sparkle_version "$ESCAPING_TARGET_PARENT" B
mv "$ESCAPING_TARGET_PARENT/Versions/B/XPCServices" "$TEMP_DIR/displaced-xpc-services"
ln -s "$OUTSIDE_SPARKLE/Versions/C/XPCServices" "$ESCAPING_TARGET_PARENT/Versions/B/XPCServices"
if codexbar_sparkle_signing_targets \
  "$ESCAPING_TARGET_PARENT" >"$TEMP_DIR/escaping-target-parent.out" 2>"$TEMP_DIR/escaping-target-parent.log"; then
  echo "ERROR: Sparkle signing target with an escaping parent was accepted." >&2
  exit 1
fi
grep -Fq "signing target resolves outside its trusted root" "$TEMP_DIR/escaping-target-parent.log"

ESCAPING_SINGLE="$TEMP_DIR/Escaping Single Sparkle.framework"
mkdir -p "$ESCAPING_SINGLE/Versions"
ln -s "$OUTSIDE_SPARKLE/Versions/C" "$ESCAPING_SINGLE/Versions/B"
if codexbar_sparkle_version_dir "$ESCAPING_SINGLE" 2>"$TEMP_DIR/escaping-single.log"; then
  echo "ERROR: Escaping single Sparkle version directory was accepted." >&2
  exit 1
fi
grep -Fq "outside the framework versions directory" "$TEMP_DIR/escaping-single.log"

echo "Sparkle signing path tests passed."

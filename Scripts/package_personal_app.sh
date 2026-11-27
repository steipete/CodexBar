#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env
swift build --package-path Personal -c release --product CodexBar
products=$(swift build --package-path Personal -c release --show-bin-path)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/CodexBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$products/CodexBar" "$app/Contents/MacOS/CodexBar"
install -m 644 Icon.icns "$app/Contents/Resources/Icon.icns"
python3 - "$app/Contents/Info.plist" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess
import sys

Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(
    CFBundleName='CodexBar', CFBundleDisplayName='CodexBar', CFBundleIdentifier='com.steipete.codexbar',
    CFBundleExecutable='CodexBar', CFBundlePackageType='APPL', CFBundleIconFile='Icon',
    CFBundleShortVersionString=sys.argv[2], CFBundleVersion=sys.argv[3], LSUIElement=True,
    LSMinimumSystemVersion='14.0', SUFeedURL='', SUEnableAutomaticChecks=False,
    CodexGitCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    CodexBuildTimestamp=datetime.now(timezone.utc).isoformat(),
)))
PY
codesign --force --sign - "$app"
# This output must be fresh. Never mix in helpers from an upstream build.
[[ ! -e CodexBar.app ]] || { echo 'CodexBar.app already exists in the build directory' >&2; exit 1; }
ditto "$app" CodexBar.app

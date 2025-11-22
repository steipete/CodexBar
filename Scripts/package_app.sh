#!/usr/bin/env bash
set -euo pipefail
CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Force a clean build to avoid stale binaries.
rm -rf "$ROOT/.build"
swift package clean >/dev/null 2>&1 || true

swift build -c "$CONF" --arch arm64

APP="$ROOT/CodexBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Convert new .icon bundle to .icns if present (macOS 14+/IconStudio export)
ICON_SOURCE="$ROOT/Icon.icon"
ICON_TARGET="$ROOT/Icon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
  iconutil --convert icns --output "$ICON_TARGET" "$ICON_SOURCE"
fi

BUNDLE_ID="com.steipete.codexbar"
FEED_URL="https://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml"
AUTO_CHECKS=true
LOWER_CONF=$(printf "%s" "$CONF" | tr '[:upper:]' '[:lower:]')
if [[ "$LOWER_CONF" == "debug" ]]; then
  BUNDLE_ID="com.steipete.codexbar.debug"
  FEED_URL=""
  AUTO_CHECKS=false
fi
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CodexBar</string>
    <key>CFBundleDisplayName</key><string>CodexBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CodexBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.5.3</string>
    <key>CFBundleVersion</key><string>19</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>NSHumanReadableCopyright</key><string>© 2025 Peter Steinberger. MIT License.</string>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=</string>
    <key>SUEnableAutomaticChecks</key><${AUTO_CHECKS}/>
    <key>CodexBuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>CodexGitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

cp ".build/$CONF/CodexBar" "$APP/Contents/MacOS/CodexBar"
chmod +x "$APP/Contents/MacOS/CodexBar"
# Embed Sparkle.framework
if [[ -d ".build/$CONF/Sparkle.framework" ]]; then
  cp -R ".build/$CONF/Sparkle.framework" "$APP/Contents/Frameworks/"
  chmod -R a+rX "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CodexBar"
  # Re-sign Sparkle and all nested components with Developer ID + timestamp
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  CODESIGN_ID="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"
  function resign() { codesign --force --timestamp --options runtime --sign "$CODESIGN_ID" "$1"; }
  # Sign innermost binaries first, then the framework root to seal resources
  resign "$SPARKLE"
  resign "$SPARKLE/Versions/B/Sparkle"
  resign "$SPARKLE/Versions/B/Autoupdate"
  resign "$SPARKLE/Versions/B/Updater.app"
  resign "$SPARKLE/Versions/B/Updater.app/Contents/MacOS/Updater"
  resign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  resign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  resign "$SPARKLE/Versions/B"
  resign "$SPARKLE"
fi

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Strip extended attributes to prevent AppleDouble (._*) files that break code sealing
xattr -cr "$APP"
find "$APP" -name '._*' -delete

# Finally sign the app bundle itself
CODESIGN_ID="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"
codesign --force --timestamp --options runtime --sign "$CODESIGN_ID" "$APP"

echo "Created $APP"

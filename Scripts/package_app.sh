#!/usr/bin/env bash
set -euo pipefail
CONF=${1:-release}
ALLOW_LLDB=${CODEXBAR_ALLOW_LLDB:-0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Load version info
source "$ROOT/version.env"

# Force a clean build to avoid stale binaries.
rm -rf "$ROOT/.build"
swift package clean >/dev/null 2>&1 || true

# Build for host architecture by default; allow overriding via ARCHES (e.g., "arm64 x86_64" for universal).
ARCHES=( ${ARCHES:-} )
if [[ ${#ARCHES[@]} -eq 0 ]]; then
  # Default to host arch; on Intel this is x86_64, on Apple Silicon arm64.
  HOST_ARCH=$(uname -m)
  case "$HOST_ARCH" in
    arm64) ARCHES=(arm64) ;;
    x86_64) ARCHES=(x86_64) ;;
    *) ARCHES=("$HOST_ARCH") ;;
  esac
fi

for A in "${ARCHES[@]}"; do
  swift build -c "$CONF" --arch "$A"
done

APP="$ROOT/CodexBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/PlugIns"

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
WIDGET_BUNDLE_ID="${BUNDLE_ID}.widget"
APP_GROUP_ID="group.com.steipete.codexbar"
if [[ "$BUNDLE_ID" == *".debug"* ]]; then
  APP_GROUP_ID="group.com.steipete.codexbar.debug"
fi
ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
APP_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBar.entitlements"
WIDGET_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBarWidget.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"
if [[ "$ALLOW_LLDB" == "1" && "$LOWER_CONF" != "debug" ]]; then
  echo "ERROR: CODEXBAR_ALLOW_LLDB requires debug configuration" >&2
  exit 1
fi
cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${APP_GROUP_ID}</string>
    </array>
    $(if [[ "$ALLOW_LLDB" == "1" ]]; then echo "    <key>com.apple.security.get-task-allow</key><true/>"; fi)
</dict>
</plist>
PLIST
cat > "$WIDGET_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${APP_GROUP_ID}</string>
    </array>
</dict>
</plist>
PLIST
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
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
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

# If building universal, create a fat binary, else copy the built one.
if [[ ${#ARCHES[@]} -gt 1 ]]; then
  BINARIES=()
  for A in "${ARCHES[@]}"; do
    case "$A" in
      arm64) BINARIES+=(".build/arm64-apple-macosx/$CONF/CodexBar") ;;
      x86_64) BINARIES+=(".build/x86_64-apple-macosx/$CONF/CodexBar") ;;
      *) BINARIES+=(".build/$CONF/CodexBar") ;;
    esac
  done
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/CodexBar"
else
  cp ".build/$CONF/CodexBar" "$APP/Contents/MacOS/CodexBar"
fi
chmod +x "$APP/Contents/MacOS/CodexBar"
# Ship CodexBarCLI alongside the app for easy symlinking.
if [[ -f ".build/$CONF/CodexBarCLI" ]]; then
  if [[ ${#ARCHES[@]} -gt 1 ]]; then
    BINARIES=()
    for A in "${ARCHES[@]}"; do
      case "$A" in
        arm64) BINARIES+=(".build/arm64-apple-macosx/$CONF/CodexBarCLI") ;;
        x86_64) BINARIES+=(".build/x86_64-apple-macosx/$CONF/CodexBarCLI") ;;
        *) BINARIES+=(".build/$CONF/CodexBarCLI") ;;
      esac
    done
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/Helpers/CodexBarCLI"
  else
    cp ".build/$CONF/CodexBarCLI" "$APP/Contents/Helpers/CodexBarCLI"
  fi
  chmod +x "$APP/Contents/Helpers/CodexBarCLI"
fi
# Watchdog helper: ensures `claude` probes die when CodexBar crashes/gets killed.
if [[ -f ".build/$CONF/CodexBarClaudeWatchdog" ]]; then
  if [[ ${#ARCHES[@]} -gt 1 ]]; then
    BINARIES=()
    for A in "${ARCHES[@]}"; do
      case "$A" in
        arm64) BINARIES+=(".build/arm64-apple-macosx/$CONF/CodexBarClaudeWatchdog") ;;
        x86_64) BINARIES+=(".build/x86_64-apple-macosx/$CONF/CodexBarClaudeWatchdog") ;;
        *) BINARIES+=(".build/$CONF/CodexBarClaudeWatchdog") ;;
      esac
    done
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/Helpers/CodexBarClaudeWatchdog"
  else
    cp ".build/$CONF/CodexBarClaudeWatchdog" "$APP/Contents/Helpers/CodexBarClaudeWatchdog"
  fi
  chmod +x "$APP/Contents/Helpers/CodexBarClaudeWatchdog"
fi
if [[ -f ".build/$CONF/CodexBarWidget" ]]; then
  WIDGET_APP="$APP/Contents/PlugIns/CodexBarWidget.appex"
  mkdir -p "$WIDGET_APP/Contents/MacOS" "$WIDGET_APP/Contents/Resources"
  cat > "$WIDGET_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CodexBarWidget</string>
    <key>CFBundleDisplayName</key><string>CodexBar</string>
    <key>CFBundleIdentifier</key><string>${WIDGET_BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CodexBarWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
        <key>NSExtensionPrincipalClass</key><string>CodexBarWidget.CodexBarWidgetBundle</string>
    </dict>
</dict>
</plist>
PLIST
  if [[ ${#ARCHES[@]} -gt 1 ]]; then
    BINARIES=()
    for A in "${ARCHES[@]}"; do
      case "$A" in
        arm64) BINARIES+=(".build/arm64-apple-macosx/$CONF/CodexBarWidget") ;;
        x86_64) BINARIES+=(".build/x86_64-apple-macosx/$CONF/CodexBarWidget") ;;
        *) BINARIES+=(".build/$CONF/CodexBarWidget") ;;
      esac
    done
    lipo -create "${BINARIES[@]}" -output "$WIDGET_APP/Contents/MacOS/CodexBarWidget"
  else
    cp ".build/$CONF/CodexBarWidget" "$WIDGET_APP/Contents/MacOS/CodexBarWidget"
  fi
  chmod +x "$WIDGET_APP/Contents/MacOS/CodexBarWidget"
fi
# Embed Sparkle.framework
if [[ -d ".build/$CONF/Sparkle.framework" ]]; then
  cp -R ".build/$CONF/Sparkle.framework" "$APP/Contents/Frameworks/"
  chmod -R a+rX "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CodexBar"
  # Re-sign Sparkle and all nested components with Developer ID + timestamp
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$ALLOW_LLDB" == "1" ]]; then
  CODESIGN_ID="-"
  CODESIGN_ARGS=(--force --sign "$CODESIGN_ID")
else
  CODESIGN_ID="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$CODESIGN_ID")
fi
function resign() { codesign "${CODESIGN_ARGS[@]}" "$1"; }
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

# Bundle app resources (provider icons, etc.).
APP_RESOURCES_DIR="$ROOT/Sources/CodexBar/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi

# Strip extended attributes to prevent AppleDouble (._*) files that break code sealing
xattr -cr "$APP"
find "$APP" -name '._*' -delete

# Sign widget extension if present
if [[ -d "${APP}/Contents/PlugIns/CodexBarWidget.appex" ]]; then
  codesign "${CODESIGN_ARGS[@]}" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP/Contents/PlugIns/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget"
  codesign "${CODESIGN_ARGS[@]}" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP/Contents/PlugIns/CodexBarWidget.appex"
fi

# Finally sign the app bundle itself
codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"

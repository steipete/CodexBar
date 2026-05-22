#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexBar"
APP_IDENTITY="Developer ID Application: Peter Steinberger (Y5PE65HELJ)"
APP_BUNDLE="CodexBar.app"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"
source "$ROOT/Scripts/release_artifacts.sh"

# Allow building a universal binary if ARCHES is provided; default to universal (arm64 + x86_64).
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ZIP_NAME=$(codexbar_app_zip_name "$MARKETING_VERSION" "$ARCHES_VALUE")
DSYM_ZIP=$(codexbar_dsym_zip_name "$MARKETING_VERSION" "$ARCHES_VALUE")

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi
echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > /tmp/codexbar-api-key.p8
trap 'rm -f /tmp/codexbar-api-key.p8 /tmp/${APP_NAME}Notarize.zip' EXIT

ARCH_LIST=( ${ARCHES_VALUE} )
for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c release --arch "$ARCH"
done
CODEXBAR_WIDGET_METADATA_MODE=required ARCHES="${ARCHES_VALUE}" ./Scripts/package_app.sh release

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
APP_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBar.entitlements"
WIDGET_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBarWidget.entitlements"

echo "Signing with $APP_IDENTITY"
if [[ -f "$APP_BUNDLE/Contents/Helpers/CodexBarCLI" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    "$APP_BUNDLE/Contents/Helpers/CodexBarCLI"
fi
if [[ -f "$APP_BUNDLE/Contents/Helpers/CodexBarClaudeWatchdog" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    "$APP_BUNDLE/Contents/Helpers/CodexBarClaudeWatchdog"
fi
if [[ -d "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget"
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex"
fi
codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_BUNDLE"

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

echo "Submitting for notarization"
xcrun notarytool submit "/tmp/${APP_NAME}Notarize.zip" \
  --key /tmp/codexbar-api-key.p8 \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

echo "Stapling ticket"
xcrun stapler staple "$APP_BUNDLE"

# Strip any extended attributes that would create AppleDouble files when zipping
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

spctl -a -t exec -vv "$APP_BUNDLE"
stapler validate "$APP_BUNDLE"

echo "Packaging dSYM"
FIRST_ARCH="${ARCH_LIST[0]}"
PREFERRED_ARCH_DIR=".build/${FIRST_ARCH}-apple-macosx/release"
DSYM_PATH="${PREFERRED_ARCH_DIR}/${APP_NAME}.dSYM"
if [[ ! -d "$DSYM_PATH" ]]; then
  echo "Missing dSYM at $DSYM_PATH" >&2
  exit 1
fi
if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  MERGED_DSYM_ROOT="${PREFERRED_ARCH_DIR}/${APP_NAME}.dSYM-universal"
  MERGED_DSYM="${MERGED_DSYM_ROOT}/${APP_NAME}.dSYM"
  rm -rf "$MERGED_DSYM_ROOT"
  mkdir -p "$MERGED_DSYM_ROOT"
  cp -R "$DSYM_PATH" "$MERGED_DSYM"
  DWARF_PATH="${MERGED_DSYM}/Contents/Resources/DWARF/${APP_NAME}"
  BINARIES=()
  for ARCH in "${ARCH_LIST[@]}"; do
    ARCH_DSYM=".build/${ARCH}-apple-macosx/release/${APP_NAME}.dSYM/Contents/Resources/DWARF/${APP_NAME}"
    if [[ ! -f "$ARCH_DSYM" ]]; then
      echo "Missing dSYM for ${ARCH} at $ARCH_DSYM" >&2
      exit 1
    fi
    BINARIES+=("$ARCH_DSYM")
  done
  lipo -create "${BINARIES[@]}" -output "$DWARF_PATH"
  DSYM_PATH="$MERGED_DSYM"
fi
"$DITTO_BIN" --norsrc -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"

echo "Done: $ZIP_NAME"

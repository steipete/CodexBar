#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexBar"
APP_IDENTITY="Developer ID Application: Peter Steinberger (Y5PE65HELJ)"
APP_BUNDLE="CodexBar.app"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"
source "$ROOT/Scripts/release_artifacts.sh"
source "$ROOT/Scripts/package_product_paths.sh"
source "$ROOT/Scripts/release_dsym_paths.sh"

# Allow building a universal binary if ARCHES is provided; default to universal (arm64 + x86_64).
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ZIP_NAME=$(codexbar_app_zip_name "$MARKETING_VERSION" "$ARCHES_VALUE")
DSYM_ZIP=$(codexbar_dsym_zip_name "$MARKETING_VERSION" "$ARCHES_VALUE")

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

NOTARIZATION_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-notarize.XXXXXX")
chmod 700 "$NOTARIZATION_TEMP_DIR"
API_KEY_PATH="$NOTARIZATION_TEMP_DIR/codexbar-api-key.p8"
NOTARIZATION_ZIP="$NOTARIZATION_TEMP_DIR/${APP_NAME}Notarize.zip"
trap 'rm -rf "$NOTARIZATION_TEMP_DIR"' EXIT

(
  umask 077
  printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_PATH"
)
chmod 600 "$API_KEY_PATH"

ARCH_LIST=( ${ARCHES_VALUE} )
ARCHES="${ARCHES_VALUE}" CODEXBAR_SIGNING=identity ./Scripts/package_app.sh release

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
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARIZATION_ZIP"

echo "Submitting for notarization"
xcrun notarytool submit "$NOTARIZATION_ZIP" \
  --key "$API_KEY_PATH" \
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
DSYM_STAGE_ROOT="$ROOT/.build/package-products/release"
DSYM_PATHS=()
for ARCH in "${ARCH_LIST[@]}"; do
  STAGED_DSYM="$DSYM_STAGE_ROOT/$ARCH/${APP_NAME}.dSYM"
  if [[ -d "$STAGED_DSYM" ]]; then
    DSYM_PATHS+=("$STAGED_DSYM")
    continue
  fi
  BIN_DIR=$(codexbar_swiftpm_bin_path release "$ARCH")
  DSYM_PATHS+=("$(codexbar_resolve_dsym_path "$DSYM_STAGE_ROOT" "$BIN_DIR" "$APP_NAME" "$ARCH")")
done

DSYM_PATH="${DSYM_PATHS[0]}"
DSYM_DWARF_PATHS=()
for ((index = 0; index < ${#ARCH_LIST[@]}; index++)); do
  ARCH="${ARCH_LIST[$index]}"
  if ! ARCH_DSYM=$(codexbar_require_dsym_dwarf_for_arch "${DSYM_PATHS[$index]}" "$APP_NAME" "$ARCH"); then
    exit 1
  fi
  DSYM_DWARF_PATHS+=("$ARCH_DSYM")
done

if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  MERGED_DSYM_ROOT="${DSYM_STAGE_ROOT}/${APP_NAME}.dSYM-universal"
  MERGED_DSYM="${MERGED_DSYM_ROOT}/${APP_NAME}.dSYM"
  rm -rf "$MERGED_DSYM_ROOT"
  mkdir -p "$MERGED_DSYM_ROOT"
  cp -R "$DSYM_PATH" "$MERGED_DSYM"
  DWARF_PATH="${MERGED_DSYM}/Contents/Resources/DWARF/${APP_NAME}"
  lipo -create "${DSYM_DWARF_PATHS[@]}" -output "$DWARF_PATH"
  DSYM_PATH="$MERGED_DSYM"
fi
if [[ ! -d "$DSYM_PATH" ]]; then
  echo "Missing dSYM at SwiftPM-reported path: $DSYM_PATH" >&2
  exit 1
fi
codexbar_verify_dsym_matches_binary \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  "$DSYM_PATH/Contents/Resources/DWARF/$APP_NAME" \
  "${ARCH_LIST[@]}"
"$DITTO_BIN" --norsrc -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"

echo "Done: $ZIP_NAME"

#!/usr/bin/env bash
set -euo pipefail

PREV_TAG=${1:?"pass previous release tag (e.g. v0.1.0)"}
CUR_TAG=${2:?"pass current release tag (e.g. v0.1.1)"}

PREV_VER=${PREV_TAG#v}
CUR_VER=${CUR_TAG#v}
APP_NAME="CodexBar"

ZIP_URL="https://github.com/steipete/CodexBar/releases/download/${PREV_TAG}/${APP_NAME}-macos-universal-${PREV_VER}.zip"
TMP_DIR=$(mktemp -d /tmp/codexbar-live.XXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading previous release $PREV_TAG from $ZIP_URL"
curl --fail --location --output "$TMP_DIR/prev.zip" "$ZIP_URL"

echo "Installing previous release to /Applications/${APP_NAME}.app"
osascript -e 'tell application "CodexBar" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.25
done
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "ERROR: ${APP_NAME} did not quit before replacement." >&2
  exit 1
fi
rm -rf /Applications/${APP_NAME}.app
ditto -x -k "$TMP_DIR/prev.zip" "$TMP_DIR"
ditto "$TMP_DIR/${APP_NAME}.app" /Applications/${APP_NAME}.app

echo "Launching previous build…"
open -n /Applications/${APP_NAME}.app
sleep 4

cat <<'MSG'
Manual step: trigger "Check for Updates…" in the app and install the update.
Expect to land on the newly released version. When done, confirm below.
MSG

read -rp "Did the update succeed from ${PREV_TAG} to ${CUR_TAG}? (y/N) " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "Live update test NOT confirmed; failing per RUN_SPARKLE_UPDATE_TEST." >&2
  exit 1
fi

installed_ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "/Applications/${APP_NAME}.app/Contents/Info.plist")
if [[ "$installed_ver" != "$CUR_VER" ]]; then
  echo "Live update reported success but installed ${installed_ver}; expected ${CUR_VER}." >&2
  exit 1
fi

echo "Live update test confirmed."

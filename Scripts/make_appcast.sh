#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/release_config.sh"
ZIP=${1:?
"Usage: $0 CodexBar-<ver>.zip"}
FEED_URL=${2:-"$CODEXBAR_APPCAST_URL"}
PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}
if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to your ed25519 private key (Sparkle)." >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "Zip not found: $ZIP" >&2
  exit 1
fi

ZIP_DIR=$(cd "$(dirname "$ZIP")" && pwd)
ZIP_NAME=$(basename "$ZIP")
ZIP_BASE="${ZIP_NAME%.zip}"
VERSION=${SPARKLE_RELEASE_VERSION:-}
if [[ -z "$VERSION" ]]; then
  if [[ "$ZIP_NAME" =~ ^CodexBar-([0-9]+(\.[0-9]+){1,2}([-.][^.]*)?)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "Could not infer version from $ZIP_NAME; set SPARKLE_RELEASE_VERSION." >&2
    exit 1
  fi
fi

NOTES_HTML="${ZIP_DIR}/${ZIP_BASE}.html"
KEEP_NOTES=${KEEP_SPARKLE_NOTES:-0}
if [[ -x "$ROOT/Scripts/changelog-to-html.sh" ]]; then
  "$ROOT/Scripts/changelog-to-html.sh" "$VERSION" >"$NOTES_HTML"
else
  echo "Missing Scripts/changelog-to-html.sh; cannot generate HTML release notes." >&2
  exit 1
fi
cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ "$KEEP_NOTES" != "1" ]]; then
    rm -f "$NOTES_HTML"
  fi
}
trap cleanup EXIT

DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-"${CODEXBAR_RELEASES_URL}/download/v${VERSION}/"}

# Sparkle provides generate_appcast; ensure it's on PATH (via SwiftPM build of Sparkle's bin) or Xcode dmg
if ! command -v generate_appcast >/dev/null; then
  echo "generate_appcast not found in PATH. Install Sparkle tools (see Sparkle docs)." >&2
  exit 1
fi

WORK_DIR=$(mktemp -d /tmp/codexbar-appcast.XXXXXX)

cp "$ROOT/appcast.xml" "$WORK_DIR/appcast.xml"
cp "$ZIP" "$WORK_DIR/$ZIP_NAME"
cp "$NOTES_HTML" "$WORK_DIR/$ZIP_BASE.html"

pushd "$WORK_DIR" >/dev/null
generate_appcast \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --link "$FEED_URL" \
  "$WORK_DIR"
popd >/dev/null

cp "$WORK_DIR/appcast.xml" "$ROOT/appcast.xml"

echo "Appcast generated (appcast.xml). Upload alongside $ZIP at $FEED_URL"

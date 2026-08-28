#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-release-checksum.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

ASSET_NAME="CodexBarCLI-v0.0.0-linux-x86_64.tar.gz"
ASSET_PATH="$TEMP_DIR/source/$ASSET_NAME"
VERIFY_DIR="$TEMP_DIR/verify"
mkdir -p "$(dirname "$ASSET_PATH")" "$VERIFY_DIR"
printf '%s\n' "release checksum fixture" > "$ASSET_PATH"

"$ROOT/Scripts/generate_release_checksum.sh" "$ASSET_PATH"

CHECKSUM_PATH="$ASSET_PATH.sha256"
read -r _ CHECKSUM_ASSET < "$CHECKSUM_PATH"
[[ "$CHECKSUM_ASSET" == "$ASSET_NAME" ]]

mv "$ASSET_PATH" "$CHECKSUM_PATH" "$VERIFY_DIR/"
(
  cd "$VERIFY_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$ASSET_NAME.sha256"
  else
    shasum -a 256 -c "$ASSET_NAME.sha256"
  fi
)

echo "Release checksum tests passed."

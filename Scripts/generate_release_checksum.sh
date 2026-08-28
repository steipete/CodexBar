#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $(basename "$0") <asset>" >&2
  exit 2
fi

ASSET_PATH="$1"
if [[ ! -f "$ASSET_PATH" ]]; then
  echo "Release asset not found: $ASSET_PATH" >&2
  exit 1
fi

OUT_DIR="$(cd "$(dirname "$ASSET_PATH")" && pwd)"
ASSET="$(basename "$ASSET_PATH")"

(
  cd "$OUT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    CHECKSUM=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    CHECKSUM=(shasum -a 256)
  else
    echo "sha256sum or shasum is required." >&2
    exit 1
  fi

  "${CHECKSUM[@]}" "$ASSET" > "$ASSET.sha256"
  read -r _ CHECKSUM_ASSET < "$ASSET.sha256"
  if [[ "$CHECKSUM_ASSET" != "$ASSET" ]]; then
    echo "Checksum file references an unexpected path: $CHECKSUM_ASSET" >&2
    exit 1
  fi
  "${CHECKSUM[@]}" -c "$ASSET.sha256"
)

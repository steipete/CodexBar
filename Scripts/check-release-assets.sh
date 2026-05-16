#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$HOME/Projects/agent-scripts/release/sparkle_lib.sh"

TAG=${1:-$(git describe --tags --abbrev=0)}
ARTIFACT_PREFIX="CodexBar-macos-[A-Za-z0-9_+-]+-"

check_assets "$TAG" "$ARTIFACT_PREFIX"

VERSION=${TAG#v}
if gh --live release view "$TAG" --json assets --jq '.assets[].name' >/dev/null 2>&1; then
  assets=$(gh --live release view "$TAG" --json assets --jq '.assets[].name')
else
  assets=$(gh release view "$TAG" --json assets --jq '.assets[].name')
fi
missing=0
for target in \
  macos-arm64 \
  macos-x86_64 \
  linux-aarch64 \
  linux-x86_64
do
  asset="CodexBarCLI-v${VERSION}-${target}.tar.gz"
  checksum="${asset}.sha256"
  if ! printf "%s\n" "$assets" | grep -Fxq "$asset"; then
    echo "ERROR: CLI asset missing on release $TAG: $asset" >&2
    missing=1
  fi
  if ! printf "%s\n" "$assets" | grep -Fxq "$checksum"; then
    echo "ERROR: CLI checksum missing on release $TAG: $checksum" >&2
    missing=1
  fi
done

if [[ "$missing" == "1" ]]; then
  exit 1
fi

echo "Release $TAG has all CodexBarCLI tarballs and checksums."

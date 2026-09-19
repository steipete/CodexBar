#!/usr/bin/env bash
set -euo pipefail

url="${SWIFT_STATIC_LINUX_SDK_URL:?Swift static SDK URL is required}"
checksum="${SWIFT_STATIC_LINUX_SDK_CHECKSUM:?Swift static SDK checksum is required}"
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/codexbar-swift-sdk.XXXXXX")"
trap 'rm -r "$work_dir"' EXIT
archive="$work_dir/swift.artifactbundle.tar.gz"

# Keep SwiftPM's FoundationNetworking/TLS teardown out of SDK installation.
curl --fail --location --retry 3 --output "$archive" "$url"
if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "$archive" | awk '{print $1}')"
else
  actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
fi
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo "Swift static SDK SHA-256 mismatch." >&2
  exit 1
fi

swift sdk install "$archive"

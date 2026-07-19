#!/usr/bin/env bash
set -euo pipefail
VERSION=${1:?"usage: $0 <version>"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

first_line=$(grep -m1 '^## ' CHANGELOG.md | sed 's/^## //')
if [[ "$first_line" != ${VERSION}* ]]; then
  echo "ERROR: Top CHANGELOG section is '$first_line' but expected '${VERSION} — …'" >&2
  exit 1
fi

grep -q "^## ${VERSION} " CHANGELOG.md || {
  echo "ERROR: No section for version ${VERSION} in CHANGELOG.md" >&2
  exit 1
}

grep -q '^## [0-9]\+\.[0-9]\+\.[0-9].*Unreleased' CHANGELOG.md && {
  echo "ERROR: Top section still labeled Unreleased; finalize changelog first." >&2
  exit 1
}

echo "Changelog OK for ${VERSION}"

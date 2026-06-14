#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_SIZE="${CODEXBAR_TEST_GROUP_SIZE:-12}"
SUITE_TIMEOUT="${CODEXBAR_TEST_SUITE_TIMEOUT:-180}"

cd "${ROOT_DIR}"
exec python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
  --group-size "${GROUP_SIZE}" \
  --timeout "${SUITE_TIMEOUT}" \
  "$@"

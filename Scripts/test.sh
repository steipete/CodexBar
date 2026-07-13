#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_SIZE="${CODEXBAR_TEST_GROUP_SIZE:-12}"
SUITE_TIMEOUT="${CODEXBAR_TEST_SUITE_TIMEOUT:-180}"
RETRY_NON_TIMEOUT_FAILURES="${CODEXBAR_TEST_RETRY_NON_TIMEOUT_FAILURES:-1}"

cd "${ROOT_DIR}"

# Defense in depth: test processes also self-detect, but keep this explicit so runner changes cannot
# expose the user's login Keychain. Deliberate isolated Keychain tests must opt in by setting the allow flag.
if [[ "${CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS:-}" != "1" ]]; then
  export CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1
fi

ARGS=(
  --group-size "${GROUP_SIZE}"
  --timeout "${SUITE_TIMEOUT}"
)

case "${RETRY_NON_TIMEOUT_FAILURES}" in
  0) ARGS+=(--no-retry-non-timeout-failures) ;;
  1) ;;
  *)
    echo "CODEXBAR_TEST_RETRY_NON_TIMEOUT_FAILURES must be 0 or 1" >&2
    exit 2
    ;;
esac

if [[ -n "${CODEXBAR_TEST_SHARD_INDEX:-}" || -n "${CODEXBAR_TEST_SHARD_COUNT:-}" ]]; then
  ARGS+=(
    --shard-index "${CODEXBAR_TEST_SHARD_INDEX:?CODEXBAR_TEST_SHARD_COUNT requires CODEXBAR_TEST_SHARD_INDEX}"
    --shard-count "${CODEXBAR_TEST_SHARD_COUNT:?CODEXBAR_TEST_SHARD_INDEX requires CODEXBAR_TEST_SHARD_COUNT}"
  )
fi

exec python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" "${ARGS[@]}" "$@"

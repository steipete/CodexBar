#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-test-sharding.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

IFS= read -r -d '' FAKE_SWIFT_SCRIPT <<'EOF' || true
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_SWIFT_LOG}"
if [[ "$*" == "test list" ]]; then
  printf '%s\n' \
    "CodexBarTests.Alpha/test_one()" \
    "CodexBarTests.Alpha/test_two(argument:)" \
    "CodexBarTests.Beta/test_two" \
    'CodexBarTests.`top level works`()' \
    'CodexBarTests.`top/level slash works`()'
  exit 0
fi
if [[ "$*" == *"|"* ]]; then
  group_runs="$(grep -c '|' "${FAKE_SWIFT_LOG}")"
  if [[ "${FAKE_SWIFT_GROUP_ALWAYS_FAIL:-0}" == "1" || "${group_runs}" -eq 1 ]]; then
    exit 1
  fi
fi
EOF

export FAKE_SWIFT_LOG="${TEMP_DIR}/swift.log"

python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
  --group-size 4 \
  --timeout 10 \
  --swift-command /bin/bash \
  --swift-command-arg=-c \
  --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
  --swift-command-arg=fake-swift \
  >"${TEMP_DIR}/retry.log"
grep -Fq "failed with exit code 1; retrying shard once" "${TEMP_DIR}/retry.log"
grep -Fq "CodexBarTests\\.Alpha" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\.Beta" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\..*top\\ level\\ works" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\..*top/level\\ slash\\ works" "${FAKE_SWIFT_LOG}"
[[ "$(wc -l < "${FAKE_SWIFT_LOG}")" -eq 3 ]]

python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
  --group-size 1 \
  --timeout 10 \
  --shard-index 0 \
  --shard-count 2 \
  --list-only \
  --swift-command /bin/bash \
  --swift-command-arg=-c \
  --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
  --swift-command-arg=fake-swift \
  >"${TEMP_DIR}/shard-0.log"

python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
  --group-size 1 \
  --timeout 10 \
  --shard-index 1 \
  --shard-count 2 \
  --list-only \
  --swift-command /bin/bash \
  --swift-command-arg=-c \
  --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
  --swift-command-arg=fake-swift \
  >"${TEMP_DIR}/shard-1.log"

cat "${TEMP_DIR}/shard-0.log" "${TEMP_DIR}/shard-1.log" \
  | grep -v '^Discovered ' \
  | sort >"${TEMP_DIR}/shards-combined.log"
python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
  --group-size 1 \
  --timeout 10 \
  --list-only \
  --swift-command /bin/bash \
  --swift-command-arg=-c \
  --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
  --swift-command-arg=fake-swift \
  | grep -v '^Discovered ' \
  | sort >"${TEMP_DIR}/shards-expected.log"
diff -u "${TEMP_DIR}/shards-expected.log" "${TEMP_DIR}/shards-combined.log"

if FAKE_SWIFT_GROUP_ALWAYS_FAIL=1 \
  python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
    --group-size 4 \
    --timeout 10 \
    --swift-command /bin/bash \
    --swift-command-arg=-c \
    --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
    --swift-command-arg=fake-swift \
    >"${TEMP_DIR}/failure.log" 2>&1; then
  echo "ERROR: Repeated shard failure was masked." >&2
  exit 1
fi

echo "Swift test sharding tests passed."

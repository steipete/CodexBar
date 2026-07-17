#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-test-sharding.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

IFS= read -r -d '' FAKE_SWIFT_SCRIPT <<'EOF' || true
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_SWIFT_LOG}"
if [[ "$*" == "test list" ]]; then
  if [[ "${FAKE_SWIFT_MODE:-success}" == "list_fail" ]]; then
    sleep 0.25
    printf 'test-list stdout marker\n'
    printf 'test-list stderr marker\n' >&2
    exit 42
  fi
  printf '%s\n' \
    "CodexBarTests.Alpha/test_one()" \
    "CodexBarTests.Alpha/test_two(argument:)" \
    "CodexBarTests.Beta/test_two" \
    "CodexBarTests.Gamma/test_three" \
    "CodexBarTests.Delta/test_four" \
    "CodexBarTests.Epsilon/test_five" \
    "CodexBarTests.Zeta/test_six" \
    "CodexBarTests.Eta/test_seven" \
    "CodexBarTests.Theta/test_eight" \
    'CodexBarTests.`top level works`()' \
    'CodexBarTests.`top/level slash works`()'
  exit 0
fi

is_group=0
if [[ "$*" == *"|"* ]]; then
  is_group=1
fi

next_group_attempt() {
  local attempt=0
  if [[ -f "${FAKE_SWIFT_STATE}" ]]; then
    read -r attempt < "${FAKE_SWIFT_STATE}"
  fi
  attempt=$((attempt + 1))
  printf '%s\n' "${attempt}" > "${FAKE_SWIFT_STATE}"
  printf '%s\n' "${attempt}"
}

case "${FAKE_SWIFT_MODE:-success}" in
  group_fail_once)
    if [[ "${is_group}" == "1" && "$(next_group_attempt)" == "1" ]]; then
      exit 1
    fi
    ;;
  group_always_fail)
    if [[ "${is_group}" == "1" ]]; then
      exit 1
    fi
    ;;
  group_timeout)
    if [[ "${is_group}" == "1" ]]; then
      sleep 2
    fi
    ;;
  singleton_timeout)
    if [[ "${is_group}" == "0" ]]; then
      sleep 2
    fi
    ;;
  group_fail_then_timeout)
    if [[ "${is_group}" == "1" ]]; then
      attempt="$(next_group_attempt)"
      if [[ "${attempt}" == "1" ]]; then
        exit 1
      fi
      sleep 2
    fi
    ;;
esac
EOF

reset_case() {
  local name="$1"
  export FAKE_SWIFT_LOG="${TEMP_DIR}/${name}-swift.log"
  export FAKE_SWIFT_STATE="${TEMP_DIR}/${name}-state"
  export GITHUB_STEP_SUMMARY="${TEMP_DIR}/${name}-summary.md"
  rm -f "${FAKE_SWIFT_LOG}" "${FAKE_SWIFT_STATE}" "${GITHUB_STEP_SUMMARY}"
}

run_harness() {
  python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" \
    "$@" \
    --swift-command /bin/bash \
    --swift-command-arg=-c \
    --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
    --swift-command-arg=fake-swift
}

python3 - "${ROOT_DIR}/.github/workflows/ci.yml" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text()
if "types: [opened, synchronize, reopened, ready_for_review, converted_to_draft]" not in workflow:
    raise SystemExit("CI must rerun when a pull request becomes ready or draft")
if "CI_PULL_REQUEST_DRAFT: ${{ github.event.pull_request.draft || false }}" not in workflow:
    raise SystemExit("CI must pass draft state to the macOS test gate")
if "macos-tests-deferred: ${{ steps.macos-tests.outputs.macos-tests-deferred }}" not in workflow:
    raise SystemExit("CI must expose whether macOS tests were deferred")
job_match = re.search(r"(?ms)^  swift-test-macos:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)", workflow)
if not job_match:
    raise SystemExit("swift-test-macos job not found in CI workflow")

job = job_match.group("body")
required_not_deferred = (
    "if: ${{ needs.changes.outputs.macos-tests == 'true' && "
    "needs.changes.outputs.macos-tests-deferred != 'true' }}"
)
if required_not_deferred not in job:
    raise SystemExit("swift-test-macos must skip only required tests explicitly deferred for drafts")
if not re.search(r"(?m)^\s+shard-index:\s+\[0,\s*1\]\s*$", job):
    raise SystemExit("swift-test-macos must run exactly two shard indexes: [0, 1]")
if not re.search(r"(?m)^\s+shard-count:\s+\[2\]\s*$", job):
    raise SystemExit("swift-test-macos shard-count must be [2]")
if "CODEXBAR_TEST_SHARD_INDEX=${{ matrix.shard-index }}" not in job:
    raise SystemExit("swift-test-macos must pass matrix.shard-index to Scripts/test.sh")
if "CODEXBAR_TEST_SHARD_COUNT=${{ matrix.shard-count }}" not in job:
    raise SystemExit("swift-test-macos must pass matrix.shard-count to Scripts/test.sh")
PY

reset_case retry
export FAKE_SWIFT_MODE=group_fail_once
run_harness --group-size 4 --timeout 10 > "${TEMP_DIR}/retry.log"
grep -Fq "failed with exit code 1; retrying group once" "${TEMP_DIR}/retry.log"
grep -Fq "Swift test timing summary:" "${TEMP_DIR}/retry.log"
grep -Fq '| Discovered selections | `10` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected selections | `10` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected groups | `3` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| First-pass successful groups | `2` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| First-pass failed groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Full-group retries | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Recovered groups | `1` |' "${GITHUB_STEP_SUMMARY}"
[[ "$(grep -c '^test --skip-build --no-parallel' "${FAKE_SWIFT_LOG}")" -eq 4 ]]
grep -Fq "CodexBarTests\\.Alpha" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\.Beta" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\..*top\\ level\\ works" "${FAKE_SWIFT_LOG}"
grep -Fq "CodexBarTests\\..*top/level\\ slash\\ works" "${FAKE_SWIFT_LOG}"
[[ "$(wc -l < "${FAKE_SWIFT_LOG}")" -eq 5 ]]

reset_case strict
export FAKE_SWIFT_MODE=group_fail_once
set +e
CODEXBAR_TEST_GROUP_SIZE=4 \
  CODEXBAR_TEST_SUITE_TIMEOUT=10 \
  CODEXBAR_TEST_RETRY_NON_TIMEOUT_FAILURES=0 \
  "${ROOT_DIR}/Scripts/test.sh" \
    --limit-groups 1 \
    --swift-command /bin/bash \
    --swift-command-arg=-c \
    --swift-command-arg="${FAKE_SWIFT_SCRIPT}" \
    --swift-command-arg=fake-swift \
    > "${TEMP_DIR}/strict.log" 2>&1
strict_status=$?
set -e
[[ "${strict_status}" -eq 1 ]]
grep -Fq '| First-pass failed groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Full-group retries | `0` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Isolated selection retries | `0` |' "${GITHUB_STEP_SUMMARY}"
[[ "$(wc -l < "${FAKE_SWIFT_LOG}")" -eq 2 ]]

reset_case shard-0
export FAKE_SWIFT_MODE=success
run_harness --group-size 4 --timeout 10 --shard-index 0 --shard-count 2 > "${TEMP_DIR}/shard-0.log"
grep -Fq '| Shard | `1/2` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected selections | `6` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected groups | `2` |' "${GITHUB_STEP_SUMMARY}"

reset_case shard-1
run_harness --group-size 4 --timeout 10 --shard-index 1 --shard-count 2 > "${TEMP_DIR}/shard-1.log"
grep -Fq '| Shard | `2/2` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected selections | `4` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Selected groups | `1` |' "${GITHUB_STEP_SUMMARY}"

reset_case shard-list-0
run_harness --group-size 4 --timeout 10 --shard-index 0 --shard-count 2 --list-only \
  > "${TEMP_DIR}/shard-list-0.log"
reset_case shard-list-1
run_harness --group-size 4 --timeout 10 --shard-index 1 --shard-count 2 --list-only \
  > "${TEMP_DIR}/shard-list-1.log"
cat "${TEMP_DIR}/shard-list-0.log" "${TEMP_DIR}/shard-list-1.log" \
  | grep -v '^Discovered ' \
  | sort > "${TEMP_DIR}/shards-combined.log"
reset_case shard-list-all
run_harness --group-size 4 --timeout 10 --list-only \
  | grep -v '^Discovered ' \
  | sort > "${TEMP_DIR}/shards-expected.log"
diff -u "${TEMP_DIR}/shards-expected.log" "${TEMP_DIR}/shards-combined.log"

reset_case group-timeout
export FAKE_SWIFT_MODE=group_timeout
run_harness --group-size 4 --limit-groups 1 --timeout 1 > "${TEMP_DIR}/group-timeout.log"
grep -Fq "timed out; retrying selections one at a time" "${TEMP_DIR}/group-timeout.log"
grep -Fq '| Timed out groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Recovered groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Isolated selection retries | `4` |' "${GITHUB_STEP_SUMMARY}"

reset_case singleton-timeout
export FAKE_SWIFT_MODE=singleton_timeout
set +e
run_harness --group-size 1 --limit-groups 1 --timeout 1 > "${TEMP_DIR}/singleton-timeout.log" 2>&1
singleton_timeout_status=$?
set -e
[[ "${singleton_timeout_status}" -eq 124 ]]
grep -Fq '| Timed out groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Recovered groups | `0` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Isolated selection retries | `0` |' "${GITHUB_STEP_SUMMARY}"

reset_case retry-timeout
export FAKE_SWIFT_MODE=group_fail_then_timeout
run_harness --group-size 4 --limit-groups 1 --timeout 1 > "${TEMP_DIR}/retry-timeout.log"
grep -Fq '| Full-group retries | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Timed out groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Recovered groups | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Isolated selection retries | `4` |' "${GITHUB_STEP_SUMMARY}"

reset_case repeated-failure
export FAKE_SWIFT_MODE=group_always_fail
set +e
run_harness --group-size 4 --limit-groups 1 --timeout 10 > "${TEMP_DIR}/failure.log" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -eq 1 ]]
grep -Fq '| Full-group retries | `1` |' "${GITHUB_STEP_SUMMARY}"
grep -Fq '| Recovered groups | `0` |' "${GITHUB_STEP_SUMMARY}"

reset_case list-failure
export FAKE_SWIFT_MODE=list_fail
set +e
run_harness --group-size 1 --timeout 10 > "${TEMP_DIR}/list-failure.log" 2>&1
list_failure_status=$?
set -e
[[ "${list_failure_status}" -ne 0 ]]
grep -Fq "test-list stdout marker" "${TEMP_DIR}/list-failure.log"
grep -Fq "test-list stderr marker" "${TEMP_DIR}/list-failure.log"
grep -Eq -- '- Discovery seconds: 0\.[1-9]' "${TEMP_DIR}/list-failure.log"
grep -Fq '| Discovered selections | `0` |' "${GITHUB_STEP_SUMMARY}"

echo "Swift test sharding tests passed."

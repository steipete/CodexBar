#!/usr/bin/env bash

set -euo pipefail

lint_result="${1:-}"
changes_result="${2:-}"
macos_tests_required="${3:-}"
macos_test_result="${4:-}"
macos_tests_deferred="${5:-}"

if [[ "$lint_result" != "success" ]]; then
  printf 'lint job finished with %s\n' "${lint_result:-<empty>}" >&2
  exit 1
fi

if [[ "$changes_result" != "success" ]]; then
  printf 'changes job finished with %s\n' "${changes_result:-<empty>}" >&2
  exit 1
fi

case "${macos_tests_required}:${macos_tests_deferred}:${macos_test_result}" in
  true:false:success)
    printf 'Lint and macOS Swift test shards passed.\n'
    ;;
  false:false:skipped)
    printf 'Lint passed; macOS Swift tests skipped by the macOS test gate.\n'
    ;;
  true:true:skipped)
    printf 'macOS Swift tests are required but deferred; aggregate CI remains incomplete\n' >&2
    exit 1
    ;;
  *)
    printf 'macOS test gate/result mismatch: required=%s deferred=%s result=%s\n' \
      "${macos_tests_required:-<empty>}" "${macos_tests_deferred:-<empty>}" \
      "${macos_test_result:-<empty>}" >&2
    exit 1
    ;;
esac

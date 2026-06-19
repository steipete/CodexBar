#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"

ensure_tools() {
  # Always delegate to the installer so pinned versions are enforced.
  # The installer is idempotent and exits early when the expected versions are already present.
  "${ROOT_DIR}/Scripts/install_lint_tools.sh"
}

check_codex_parser_hash() {
  "${ROOT_DIR}/Scripts/regenerate-codex-parser-hash.sh" --check
}

check_package_product_paths() {
  "${ROOT_DIR}/Scripts/test_package_product_paths.sh"
}

check_release_dsym_paths() {
  "${ROOT_DIR}/Scripts/test_release_dsym_paths.sh"
}

check_sparkle_signing_paths() {
  "${ROOT_DIR}/Scripts/test_sparkle_signing_paths.sh"
}

check_swift_test_sharding() {
  "${ROOT_DIR}/Scripts/test_swift_test_sharding.sh"
}

check_app_locales() {
  node "${ROOT_DIR}/Scripts/check-app-locales.mjs" --test
  node "${ROOT_DIR}/Scripts/check-app-locales.mjs"
}

check_site_locales() {
  node "${ROOT_DIR}/Scripts/check-site-locales.mjs"
  node --check "${ROOT_DIR}/docs/site.js"
}

run_portable_checks() {
  check_codex_parser_hash
  check_package_product_paths
  check_release_dsym_paths
  check_sparkle_signing_paths
  check_swift_test_sharding
  check_site_locales
  ensure_tools
}

run_swiftformat_lint() {
  "${BIN_DIR}/swiftformat" Sources Tests --lint
}

run_swiftlint() {
  "${BIN_DIR}/swiftlint" --strict
}

cmd="${1:-lint}"

case "$cmd" in
  lint)
    check_app_locales
    run_portable_checks
    run_swiftformat_lint
    run_swiftlint
    ;;
  lint-linux)
    run_portable_checks
    run_swiftlint
    ;;
  lint-macos)
    check_app_locales
    ensure_tools
    run_swiftformat_lint
    ;;
  format)
    ensure_tools
    "${BIN_DIR}/swiftformat" Sources Tests
    ;;
  *)
    printf 'Usage: %s [lint|lint-linux|lint-macos|format]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac

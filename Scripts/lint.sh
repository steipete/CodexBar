#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"

ensure_swiftformat() {
  "${ROOT_DIR}/Scripts/install_lint_tools.sh" swiftformat
}

ensure_swiftlint() {
  "${ROOT_DIR}/Scripts/install_lint_tools.sh" swiftlint
}

check_codex_parser_hash() {
  "${ROOT_DIR}/Scripts/regenerate-codex-parser-hash.sh" --check
}

check_package_product_paths() {
  "${ROOT_DIR}/Scripts/test_package_product_paths.sh"
}

check_package_strip() {
  "${ROOT_DIR}/Scripts/test_package_strip.sh"
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

check_ci_path_gate() {
  "${ROOT_DIR}/Scripts/test_ci_path_gate.sh"
}

check_shell_scripts() {
  local count=0
  local script
  for script in "${ROOT_DIR}"/Scripts/*.sh "${ROOT_DIR}"/Scripts/mac-release; do
    [[ -f "$script" ]] || continue
    bash -n "$script"
    count=$((count + 1))
  done
  printf 'shell scripts OK: %d files\n' "$count"
}

check_app_locales() {
  node "${ROOT_DIR}/Scripts/check-app-locales.mjs" --test
  node "${ROOT_DIR}/Scripts/check-app-locales.mjs"
}

check_site_locales() {
  node "${ROOT_DIR}/Scripts/check-site-locales.mjs"
  node --check "${ROOT_DIR}/docs/site.js"
}

check_documentation_links() {
  node "${ROOT_DIR}/Scripts/check-documentation-links.mjs"
}

check_llms_index() {
  node "${ROOT_DIR}/Scripts/generate-llms.mjs" --check
}

run_portable_checks() {
  check_codex_parser_hash
  check_package_product_paths
  check_package_strip
  check_release_dsym_paths
  check_sparkle_signing_paths
  check_swift_test_sharding
  check_ci_path_gate
  check_shell_scripts
  check_documentation_links
  check_llms_index
  check_site_locales
}

run_swiftformat_lint() {
  ensure_swiftformat
  "${BIN_DIR}/swiftformat" Sources Tests --lint
}

run_swiftlint() {
  ensure_swiftlint
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
    run_swiftformat_lint
    ;;
  format)
    ensure_swiftformat
    "${BIN_DIR}/swiftformat" Sources Tests
    ;;
  *)
    printf 'Usage: %s [lint|lint-linux|lint-macos|format]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac

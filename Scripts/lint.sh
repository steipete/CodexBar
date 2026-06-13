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

cmd="${1:-lint}"

case "$cmd" in
  lint)
    check_codex_parser_hash
    check_package_product_paths
    check_release_dsym_paths
    ensure_tools
    "${BIN_DIR}/swiftformat" Sources Tests --lint
    "${BIN_DIR}/swiftlint" --strict
    ;;
  format)
    ensure_tools
    "${BIN_DIR}/swiftformat" Sources Tests
    ;;
  *)
    printf 'Usage: %s [lint|format]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac

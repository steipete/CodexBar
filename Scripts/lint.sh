#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"

ensure_tools() {
  # Always delegate to the installer so pinned versions are enforced.
  # The installer is idempotent and exits early when the expected versions are already present.
  "${ROOT_DIR}/Scripts/install_lint_tools.sh"
}

cmd="${1:-lint}"

developer_dir="$(xcode-select -p 2>/dev/null || true)"
sourcekit_lib_dir=""
if [[ -n "${developer_dir}" && -d "${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework" ]]; then
  sourcekit_lib_dir="${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/lib"
elif [[ -d /Library/Developer/CommandLineTools/usr/lib/sourcekitdInProc.framework ]]; then
  sourcekit_lib_dir="/Library/Developer/CommandLineTools/usr/lib"
fi

if [[ -n "${sourcekit_lib_dir}" ]]; then
  export DYLD_FRAMEWORK_PATH="${sourcekit_lib_dir}${DYLD_FRAMEWORK_PATH:+:${DYLD_FRAMEWORK_PATH}}"
fi

case "$cmd" in
  lint)
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

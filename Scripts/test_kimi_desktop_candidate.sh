#!/bin/bash
# Build/test synthetic candidates only. Never install, launch, or probe an account.
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo "usage: $0 /absolute/path/to/patched/SweetCookieKit build|test|reader-test|full-test" >&2
    exit 2
fi
case "$2" in build|test|reader-test|full-test) ;; *) exit 2 ;; esac
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Native candidate verification requires macOS; Linux portability tests are separate." >&2
    exit 2
fi
dependency_path="$(cd "$1" && pwd -P)"
expected_revision=4fecf1158b2a64045ad3d85e11aab3d8b6d73e7d
if [[ "$(git -C "$dependency_path" rev-parse HEAD)" != "$expected_revision" ||
      -n "$(git -C "$dependency_path" status --porcelain)" ]]; then
    echo "Expected clean SweetCookieKit candidate $expected_revision" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
export CODEXBAR_KIMI_DESKTOP_CANDIDATE_PATH="$dependency_path"
export CODEXBAR_KIMI_CORE_TESTS=1
export CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1
export CODEXBAR_TEST_CODEX_FILE_ISOLATION=1
export CODEXBAR_TEST_SESSION_FILE_ISOLATION=1
case "$2" in
    build)
        exec swift build --scratch-path .build/kimi-core --target CodexBarCore
        ;;
    reader-test)
        exec swift test --package-path "$dependency_path" \
            --filter 'ChromiumLevelDBCurrentRecordTests|ChromiumStrictCurrentValueTests'
        ;;
    test)
        swift test --package-path "$dependency_path" \
            --filter 'ChromiumLevelDBCurrentRecordTests|ChromiumStrictCurrentValueTests'
        exec swift test --scratch-path .build/kimi-core
        ;;
    full-test)
        # Optional app-dependent graph requires full Xcode/actool. Never install tools here.
        unset CODEXBAR_KIMI_CORE_TESTS
        exec swift test --filter 'KimiLocalStorageTests|KimiDesktopNativeCandidateTests'
        ;;
esac

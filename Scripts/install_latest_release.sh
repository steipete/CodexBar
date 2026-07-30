#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LATEST_RELEASE_URL="https://github.com/steipete/CodexBar/releases/latest"
RELEASE_TAG_URL_PREFIX="https://github.com/steipete/CodexBar/releases/tag/"
RELEASE_DOWNLOAD_URL_PREFIX="https://github.com/steipete/CodexBar/releases/download/"
INSTALL_APP="/Applications/CodexBar.app"
OFFICIAL_BUNDLE_ID="com.steipete.codexbar"
OFFICIAL_TEAM_ID="Y5PE65HELJ"
OFFICIAL_IDENTITY="Developer ID Application: Peter Steinberger (Y5PE65HELJ)"
FORCE=0
VERIFY_ONLY=0

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--force] [--verify-only]

Downloads the latest stable CodexBar release from GitHub, verifies its version,
Developer ID signature, team, and notarization, then safely installs and launches it.

Options:
  --force        Reinstall even when the same official version is already installed.
  --verify-only  Download and verify the release without installing or launching it.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --force) FORCE=1 ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) fail "Unsupported argument: ${argument}" ;;
    esac
done

TMP_ROOT=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TMP_ROOT" ]]; then
        /bin/rm -rf "$TMP_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT

TMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexbar-release.XXXXXX")"
RELEASE_ZIP="${TMP_ROOT}/CodexBar.zip"
EXTRACT_DIR="${TMP_ROOT}/extracted"

log "==> Checking the latest CodexBar GitHub release"
if ! RESOLVED_RELEASE_URL="$(
    /usr/bin/curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 20 \
        --proto '=https' \
        --proto-redir '=https' \
        --output /dev/null \
        --write-out '%{url_effective}' \
        "$LATEST_RELEASE_URL"
)"
then
    fail "GitHub release lookup failed."
fi
case "$RESOLVED_RELEASE_URL" in
    "${RELEASE_TAG_URL_PREFIX}"*) ;;
    *) fail "Unexpected latest-release redirect: ${RESOLVED_RELEASE_URL}" ;;
esac
TAG_NAME="${RESOLVED_RELEASE_URL#${RELEASE_TAG_URL_PREFIX}}"
case "$TAG_NAME" in
    v[0-9]*) ;;
    *) fail "Unexpected GitHub release tag: ${TAG_NAME:-missing}" ;;
esac
case "$TAG_NAME" in
    *[!A-Za-z0-9._-]*) fail "Unsafe GitHub release tag: ${TAG_NAME}" ;;
esac
VERSION="${TAG_NAME#v}"
EXPECTED_ASSET_NAME="CodexBar-macos-universal-${VERSION}.zip"
ASSET_URL="${RELEASE_DOWNLOAD_URL_PREFIX}${TAG_NAME}/${EXPECTED_ASSET_NAME}"

installed_official_version() {
    [[ -d "$INSTALL_APP" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$INSTALL_APP" >/dev/null 2>&1 || return 1
    local installed_bundle_id
    installed_bundle_id="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${INSTALL_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    [[ "$installed_bundle_id" == "$OFFICIAL_BUNDLE_ID" ]] || return 1
    local signature
    signature="$(/usr/bin/codesign -d --verbose=4 "$INSTALL_APP" 2>&1 || true)"
    printf '%s\n' "$signature" | /usr/bin/grep -Fx "Identifier=${OFFICIAL_BUNDLE_ID}" >/dev/null || return 1
    printf '%s\n' "$signature" | /usr/bin/grep -Fx "Authority=${OFFICIAL_IDENTITY}" >/dev/null || return 1
    printf '%s\n' "$signature" | /usr/bin/grep -Fx "TeamIdentifier=${OFFICIAL_TEAM_ID}" >/dev/null || return 1
    local gatekeeper
    if ! gatekeeper="$(/usr/sbin/spctl -a -vvv -t execute "$INSTALL_APP" 2>&1)"; then
        return 1
    fi
    printf '%s\n' "$gatekeeper" | /usr/bin/grep -Fx 'source=Notarized Developer ID' >/dev/null || return 1
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "${INSTALL_APP}/Contents/Info.plist" 2>/dev/null
}

if [[ "$FORCE" == "0" && "$VERIFY_ONLY" == "0" ]]; then
    INSTALLED_VERSION="$(installed_official_version || true)"
    if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
        log "Already installed: CodexBar ${VERSION} with the official Developer ID signature."
        exit 0
    fi
fi

log "==> Downloading ${EXPECTED_ASSET_NAME}"
/usr/bin/curl --fail --location --silent --show-error --retry 3 \
    --connect-timeout 20 \
    --proto '=https' \
    --proto-redir '=https' \
    --output "$RELEASE_ZIP" \
    "$ASSET_URL"

/bin/mkdir "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$RELEASE_ZIP" "$EXTRACT_DIR"
RELEASE_APP="${EXTRACT_DIR}/CodexBar.app"
[[ -d "$RELEASE_APP" ]] || fail "Release archive does not contain CodexBar.app."

RELEASE_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${RELEASE_APP}/Contents/Info.plist" 2>/dev/null || true
)"
RELEASE_VERSION="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "${RELEASE_APP}/Contents/Info.plist" 2>/dev/null || true
)"
[[ "$RELEASE_BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" ]] || \
    fail "Unexpected release bundle identifier: ${RELEASE_BUNDLE_ID:-missing}"
[[ "$RELEASE_VERSION" == "$VERSION" ]] || \
    fail "Release app version ${RELEASE_VERSION:-missing} does not match tag ${TAG_NAME}."

verify_universal_binary() {
    local relative_path="$1"
    local binary="${RELEASE_APP}/${relative_path}"
    local architectures
    [[ -x "$binary" ]] || fail "Release app is missing executable ${relative_path}."
    architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null || true)"
    case " ${architectures} " in
        *" arm64 "*) ;;
        *) fail "Release executable ${relative_path} is missing the arm64 architecture." ;;
    esac
    case " ${architectures} " in
        *" x86_64 "*) ;;
        *) fail "Release executable ${relative_path} is missing the x86_64 architecture." ;;
    esac
}

for RELEASE_EXECUTABLE_PATH in \
    Contents/MacOS/CodexBar \
    Contents/Helpers/CodexBarCLI \
    Contents/Helpers/CodexBarClaudeWatchdog \
    Contents/PlugIns/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget \
    Contents/Frameworks/Sparkle.framework/Sparkle \
    Contents/Frameworks/Sparkle.framework/Autoupdate \
    Contents/Frameworks/Sparkle.framework/Updater.app/Contents/MacOS/Updater \
    Contents/Frameworks/Sparkle.framework/XPCServices/Downloader.xpc/Contents/MacOS/Downloader \
    Contents/Frameworks/Sparkle.framework/XPCServices/Installer.xpc/Contents/MacOS/Installer
do
    verify_universal_binary "$RELEASE_EXECUTABLE_PATH"
done

log "==> Verifying Developer ID signature and notarization"
if ! CODESIGN_VERIFY_INFO="$(
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$RELEASE_APP" 2>&1
)"
then
    printf '%s\n' "$CODESIGN_VERIFY_INFO" >&2
    fail "Code-signature verification failed for the downloaded release."
fi
SIGNATURE_INFO="$(/usr/bin/codesign -d --verbose=4 "$RELEASE_APP" 2>&1 || true)"
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -Fx "Identifier=${OFFICIAL_BUNDLE_ID}" >/dev/null || \
    fail "Release app has an unexpected code-signing identifier."
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -Fx "Authority=${OFFICIAL_IDENTITY}" >/dev/null || \
    fail "Release app is not signed by ${OFFICIAL_IDENTITY}."
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -Fx "TeamIdentifier=${OFFICIAL_TEAM_ID}" >/dev/null || \
    fail "Release app has an unexpected signing team."

if ! GATEKEEPER_INFO="$(/usr/sbin/spctl -a -vvv -t execute "$RELEASE_APP" 2>&1)"; then
    printf '%s\n' "$GATEKEEPER_INFO" >&2
    fail "Gatekeeper rejected the downloaded release."
fi
printf '%s\n' "$GATEKEEPER_INFO" | /usr/bin/grep -F 'source=Notarized Developer ID' >/dev/null || {
    printf '%s\n' "$GATEKEEPER_INFO" >&2
    fail "Downloaded release is not accepted as a notarized Developer ID app."
}

if [[ "$VERIFY_ONLY" == "1" ]]; then
    log "Verified CodexBar ${VERSION}; no installation was performed."
    exit 0
fi

log "==> Installing and launching official CodexBar ${VERSION}"
CODEXBAR_PREBUILT_APP="$RELEASE_APP" \
CODEXBAR_SIGNING=identity \
CODEXBAR_ALLOW_LLDB=0 \
CODEXBAR_EXPECTED_APP_VERSION="$VERSION" \
CODEXBAR_REQUIRE_NOTARIZATION=1 \
APP_IDENTITY="$OFFICIAL_IDENTITY" \
APP_TEAM_ID="$OFFICIAL_TEAM_ID" \
    "${ROOT_DIR}/Scripts/build_install_and_run.sh" release

INSTALLED_BUILD="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "${INSTALL_APP}/Contents/Info.plist" 2>/dev/null || true
)"
log "Installed official CodexBar ${VERSION} (${INSTALLED_BUILD:-unknown build})."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
INSTALL_DIR="/Applications"
PREBUILT_APP="${CODEXBAR_PREBUILT_APP:-}"
SOURCE_APP="${PREBUILT_APP:-${ROOT_DIR}/CodexBar.app}"
DESTINATION_APP="${INSTALL_DIR}/CodexBar.app"
DESTINATION_EXECUTABLE="${DESTINATION_APP}/Contents/MacOS/CodexBar"
APP_NAME="CodexBar"
SIGNING_MODE="${CODEXBAR_SIGNING:-identity}"
SIGNING_IDENTITY="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"
EXPECTED_APP_VERSION="${CODEXBAR_EXPECTED_APP_VERSION:-}"
REQUIRE_NOTARIZATION="${CODEXBAR_REQUIRE_NOTARIZATION:-0}"
VERIFY_LAUNCH="${CODEXBAR_VERIFY_LAUNCH:-0}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

canonical_path() {
    if [[ -x /usr/bin/realpath ]]; then
        /usr/bin/realpath "$1"
    elif [[ -x /bin/realpath ]]; then
        /bin/realpath "$1"
    else
        fail "macOS realpath utility is unavailable."
    fi
}

signing_team_id() {
    local identity="$1"
    local subject
    subject="$(
        /usr/bin/security find-certificate -c "$identity" -p 2>/dev/null \
            | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
            || true
    )"
    if [[ "$subject" =~ (^|,)OU=([A-Z0-9]{10})(,|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    elif [[ "$identity" =~ \(([A-Z0-9]{10})\)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $(basename "$0") [release|debug]

Builds CodexBar.app and installs it to ${DESTINATION_APP}.
A running installed CodexBar instance is quit before replacement and is not relaunched.
Stable identity signing is required by default; explicitly set CODEXBAR_SIGNING=adhoc
only when accepting an unstable local signature for the production bundle identifier.
EOF
    exit 0
fi

if [[ $# -gt 1 ]]; then
    fail "Expected at most one build configuration argument."
fi
case "$CONFIGURATION" in
    debug) EXPECTED_BUNDLE_ID="com.steipete.codexbar.debug" ;;
    release) EXPECTED_BUNDLE_ID="com.steipete.codexbar" ;;
    *) fail "Unsupported build configuration: ${CONFIGURATION} (expected debug or release)" ;;
esac

[[ -d "$INSTALL_DIR" ]] || fail "Installation directory does not exist: ${INSTALL_DIR}"

case "$SIGNING_MODE" in
    identity)
        if [[ "${CODEXBAR_ALLOW_LLDB:-0}" == "1" ]]; then
            fail "CODEXBAR_ALLOW_LLDB=1 forces ad-hoc signing and cannot be used for a stable /Applications install."
        fi
        if [[ -z "$PREBUILT_APP" ]] && \
            ! /usr/bin/security find-identity -p codesigning -v 2>/dev/null \
                | /usr/bin/grep -F "\"${SIGNING_IDENTITY}\"" >/dev/null 2>&1
        then
            fail "Required signing identity is unavailable: ${SIGNING_IDENTITY}. Use a stable signing certificate, or run ./Scripts/install_latest_release.sh from the repository root."
        fi
        RESOLVED_TEAM_ID="$(signing_team_id "$SIGNING_IDENTITY")"
        [[ -n "$RESOLVED_TEAM_ID" ]] || fail "Could not determine the team ID for signing identity: ${SIGNING_IDENTITY}"
        if [[ -n "${APP_TEAM_ID:-}" && "$APP_TEAM_ID" != "$RESOLVED_TEAM_ID" ]]; then
            fail "APP_TEAM_ID=${APP_TEAM_ID} does not match signing identity team ${RESOLVED_TEAM_ID}."
        fi
        export CODEXBAR_SIGNING="identity"
        export APP_IDENTITY="$SIGNING_IDENTITY"
        export APP_TEAM_ID="$RESOLVED_TEAM_ID"
        ;;
    adhoc)
        [[ -z "$PREBUILT_APP" ]] || fail "Prebuilt app installation requires identity signing verification."
        log "WARNING: Installing an ad-hoc signed production bundle can invalidate app-group and Tahoe menu bar state."
        ;;
    *)
        fail "Unsupported CODEXBAR_SIGNING: ${SIGNING_MODE} (expected identity or adhoc)"
        ;;
esac

case "$REQUIRE_NOTARIZATION" in
    0|1) ;;
    *) fail "Unsupported CODEXBAR_REQUIRE_NOTARIZATION: ${REQUIRE_NOTARIZATION} (expected 0 or 1)" ;;
esac
case "$VERIFY_LAUNCH" in
    0|1) ;;
    *) fail "Unsupported CODEXBAR_VERIFY_LAUNCH: ${VERIFY_LAUNCH} (expected 0 or 1)" ;;
esac
if [[ -n "$PREBUILT_APP" ]]; then
    [[ -n "$EXPECTED_APP_VERSION" ]] || fail "Prebuilt app installation requires CODEXBAR_EXPECTED_APP_VERSION."
    [[ "$REQUIRE_NOTARIZATION" == "1" ]] || fail "Prebuilt app installation requires CODEXBAR_REQUIRE_NOTARIZATION=1."
fi

if [[ -n "$PREBUILT_APP" ]]; then
    log "==> Using prebuilt app ${SOURCE_APP}"
else
    log "==> Building ${CONFIGURATION} app (${SIGNING_MODE} signing)"
    "${ROOT_DIR}/Scripts/package_app.sh" "$CONFIGURATION"
fi
[[ -d "$SOURCE_APP" ]] || fail "Source app does not exist: ${SOURCE_APP}"

USE_SUDO=0
if [[ ! -w "$INSTALL_DIR" ]]; then
    USE_SUDO=1
elif [[ -e "$DESTINATION_APP" ]] && { [[ ! -O "$DESTINATION_APP" ]] || [[ ! -w "$DESTINATION_APP" ]]; }; then
    USE_SUDO=1
fi
if [[ "$USE_SUDO" == "1" ]]; then
    command -v sudo >/dev/null 2>&1 || fail "Installing to ${INSTALL_DIR} requires administrator privileges."
fi

run_install_command() {
    if [[ "$USE_SUDO" == "1" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

verify_expected_app() {
    local app="$1"
    local bundle_id
    local version
    local signature
    local gatekeeper

    run_install_command /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
    bundle_id="$(
        run_install_command /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${app}/Contents/Info.plist" 2>/dev/null || true
    )"
    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] \
        || fail "Packaged app has an unexpected bundle identifier (expected ${EXPECTED_BUNDLE_ID})."
    if [[ -n "$EXPECTED_APP_VERSION" ]]; then
        version="$(
            run_install_command /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "${app}/Contents/Info.plist" 2>/dev/null || true
        )"
        [[ "$version" == "$EXPECTED_APP_VERSION" ]] \
            || fail "Packaged app version ${version:-missing} does not match ${EXPECTED_APP_VERSION}."
    fi

    signature="$(run_install_command /usr/bin/codesign -d --verbose=4 "$app" 2>&1 || true)"
    printf '%s\n' "$signature" | /usr/bin/grep -Fx "Identifier=${EXPECTED_BUNDLE_ID}" >/dev/null \
        || fail "Packaged app has an unexpected code-signing identifier (expected ${EXPECTED_BUNDLE_ID})."
    if [[ "$SIGNING_MODE" == "identity" ]]; then
        printf '%s\n' "$signature" | /usr/bin/grep -Fx "Authority=${SIGNING_IDENTITY}" >/dev/null \
            || fail "Packaged app is not signed by the required identity: ${SIGNING_IDENTITY}"
        printf '%s\n' "$signature" | /usr/bin/grep -Fx "TeamIdentifier=${APP_TEAM_ID}" >/dev/null \
            || fail "Packaged app is not signed by the required team: ${APP_TEAM_ID}"
    fi

    if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
        if ! gatekeeper="$(run_install_command /usr/sbin/spctl -a -vvv -t execute "$app" 2>&1)"; then
            printf '%s\n' "$gatekeeper" >&2
            fail "Gatekeeper rejected the packaged app."
        fi
        printf '%s\n' "$gatekeeper" | /usr/bin/grep -Fx 'source=Notarized Developer ID' >/dev/null || {
            printf '%s\n' "$gatekeeper" >&2
            fail "Packaged app is not accepted as a notarized Developer ID app."
        }
    fi
}

process_executable() {
    local pid="$1"
    /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

CURRENT_DESTINATION_EXECUTABLE=""
if [[ -x "$DESTINATION_EXECUTABLE" ]]; then
    CURRENT_DESTINATION_EXECUTABLE="$(canonical_path "$DESTINATION_EXECUTABLE")"
fi

running_installed_pids() {
    local executable
    local pid
    for pid in $(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true); do
        executable="$(process_executable "$pid" || true)"
        if [[ "$executable" == "$DESTINATION_EXECUTABLE" ]] || \
            { [[ -n "$CURRENT_DESTINATION_EXECUTABLE" ]] && [[ "$executable" == "$CURRENT_DESTINATION_EXECUTABLE" ]]; }; then
            printf '%s\n' "$pid"
        fi
    done
}

launch_installed_app() {
    /usr/bin/osascript - "$DESTINATION_APP" <<'APPLESCRIPT' >/dev/null
on run arguments
    set appAlias to POSIX file (item 1 of arguments) as alias
    tell application "Finder" to open appAlias
end run
APPLESCRIPT
}

stop_installed_app() {
    local pids
    local pid
    for _ in {1..20}; do
        pids="$(running_installed_pids)"
        [[ -n "$pids" ]] || return 0
        for pid in $pids; do
            /bin/kill "$pid" >/dev/null 2>&1 || true
        done
        sleep 0.25
    done
    [[ -z "$(running_installed_pids)" ]]
}

STAGING_DIR=""
STAGED_APP=""
BACKUP_APP=""
PREVIOUS_APP_MOVED=0
PREVIOUS_APP_WAS_RUNNING=0
NEW_APP_INSTALLED=0
INSTALL_COMPLETE=0

cleanup_install() {
    local status=$?
    local preserve_staging=0
    trap - EXIT

    if [[ "$INSTALL_COMPLETE" != "1" ]]; then
        if [[ "$NEW_APP_INSTALLED" == "1" ]]; then
            if ! stop_installed_app; then
                printf 'ERROR: Could not stop the failed newly installed app; backup retained at %s\n' "$BACKUP_APP" >&2
                preserve_staging=1
            elif ! run_install_command /bin/rm -rf "$DESTINATION_APP" >/dev/null 2>&1; then
                preserve_staging=1
            fi
        fi
        if [[ "$PREVIOUS_APP_MOVED" == "1" ]] && { [[ -e "$BACKUP_APP" ]] || [[ -L "$BACKUP_APP" ]]; }; then
            if [[ "$preserve_staging" == "0" ]]; then
                if ! run_install_command /bin/mv "$BACKUP_APP" "$DESTINATION_APP" >/dev/null 2>&1; then
                    preserve_staging=1
                elif [[ "$PREVIOUS_APP_WAS_RUNNING" == "1" ]] && ! launch_installed_app; then
                    printf 'WARNING: Restored the previous app but could not relaunch it.\n' >&2
                fi
            fi
            if [[ "$preserve_staging" == "1" ]]; then
                printf 'ERROR: Could not restore the previous app; backup retained at %s\n' "$BACKUP_APP" >&2
            fi
        elif [[ "$PREVIOUS_APP_WAS_RUNNING" == "1" && "$NEW_APP_INSTALLED" == "0" ]] && \
            ! launch_installed_app
        then
            printf 'WARNING: Replacement failed before installation and the previous app could not be relaunched.\n' >&2
        fi
    fi

    if [[ -n "$STAGING_DIR" && "$preserve_staging" == "0" ]]; then
        run_install_command /bin/rm -rf "$STAGING_DIR" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup_install EXIT

log "==> Staging app in ${INSTALL_DIR}"
STAGING_DIR="$(run_install_command /usr/bin/mktemp -d "${INSTALL_DIR}/.codexbar-install.XXXXXX")"
STAGED_APP="${STAGING_DIR}/CodexBar.app"
BACKUP_APP="${STAGING_DIR}/Previous-CodexBar.app"
run_install_command /usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
verify_expected_app "$STAGED_APP"

RUNNING_PIDS="$(running_installed_pids)"
if [[ -n "$RUNNING_PIDS" ]]; then
    PREVIOUS_APP_WAS_RUNNING=1
    log "==> Quitting installed CodexBar instance"
    stop_installed_app \
        || fail "The installed CodexBar did not quit; close it manually and run the script again."
fi

log "==> Installing ${DESTINATION_APP}"
if [[ -e "$DESTINATION_APP" || -L "$DESTINATION_APP" ]]; then
    PREVIOUS_APP_MOVED=1
    run_install_command /bin/mv "$DESTINATION_APP" "$BACKUP_APP"
fi
NEW_APP_INSTALLED=1
run_install_command /bin/mv "$STAGED_APP" "$DESTINATION_APP"
verify_expected_app "$DESTINATION_APP"

if [[ "$VERIFY_LAUNCH" == "1" ]]; then
    log "==> Launching and validating installed CodexBar before committing replacement"
    "${ROOT_DIR}/Scripts/build_install_and_run.sh" --launch-installed-only
fi

INSTALL_COMPLETE=1
run_install_command /bin/rm -rf "$STAGING_DIR"
STAGING_DIR=""
trap - EXIT
log "Installed ${DESTINATION_APP}"

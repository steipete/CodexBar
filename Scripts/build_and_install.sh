#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
INSTALL_DIR="/Applications"
SOURCE_APP="${ROOT_DIR}/CodexBar.app"
DESTINATION_APP="${INSTALL_DIR}/CodexBar.app"
DESTINATION_EXECUTABLE="${DESTINATION_APP}/Contents/MacOS/CodexBar"
APP_NAME="CodexBar"
SIGNING_MODE="${CODEXBAR_SIGNING:-identity}"
SIGNING_IDENTITY="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
    debug|release) ;;
    *) fail "Unsupported build configuration: ${CONFIGURATION} (expected debug or release)" ;;
esac

[[ -d "$INSTALL_DIR" ]] || fail "Installation directory does not exist: ${INSTALL_DIR}"

case "$SIGNING_MODE" in
    identity)
        if [[ "${CODEXBAR_ALLOW_LLDB:-0}" == "1" ]]; then
            fail "CODEXBAR_ALLOW_LLDB=1 forces ad-hoc signing and cannot be used for a stable /Applications install."
        fi
        if ! /usr/bin/security find-identity -p codesigning -v 2>/dev/null \
            | /usr/bin/grep -F "\"${SIGNING_IDENTITY}\"" >/dev/null 2>&1
        then
            fail "Required signing identity is unavailable: ${SIGNING_IDENTITY}. Use a stable signing certificate, or run package_app.sh without installing."
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
        log "WARNING: Installing an ad-hoc signed production bundle can invalidate app-group and Tahoe menu bar state."
        ;;
    *)
        fail "Unsupported CODEXBAR_SIGNING: ${SIGNING_MODE} (expected identity or adhoc)"
        ;;
esac

log "==> Building ${CONFIGURATION} app (${SIGNING_MODE} signing)"
"${ROOT_DIR}/Scripts/package_app.sh" "$CONFIGURATION"
[[ -d "$SOURCE_APP" ]] || fail "Build did not create ${SOURCE_APP}"

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

verify_expected_signature() {
    local app="$1"
    [[ "$SIGNING_MODE" == "identity" ]] || return 0
    /usr/bin/codesign -d --verbose=4 "$app" 2>&1 \
        | /usr/bin/grep -F "Authority=${SIGNING_IDENTITY}" >/dev/null \
        || fail "Packaged app is not signed by the required identity: ${SIGNING_IDENTITY}"
}

process_executable() {
    local pid="$1"
    /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

CURRENT_DESTINATION_EXECUTABLE=""
if [[ -x "$DESTINATION_EXECUTABLE" ]]; then
    CURRENT_DESTINATION_EXECUTABLE="$(/bin/realpath "$DESTINATION_EXECUTABLE")"
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

STAGING_DIR=""
STAGED_APP=""
BACKUP_APP=""
PREVIOUS_APP_MOVED=0
NEW_APP_INSTALLED=0
INSTALL_COMPLETE=0

cleanup_install() {
    local status=$?
    local preserve_staging=0
    trap - EXIT

    if [[ "$INSTALL_COMPLETE" != "1" ]]; then
        if [[ "$NEW_APP_INSTALLED" == "1" ]]; then
            if ! run_install_command /bin/rm -rf "$DESTINATION_APP" >/dev/null 2>&1; then
                preserve_staging=1
            fi
        fi
        if [[ "$PREVIOUS_APP_MOVED" == "1" ]] && { [[ -e "$BACKUP_APP" ]] || [[ -L "$BACKUP_APP" ]]; }; then
            if [[ "$preserve_staging" == "0" ]]; then
                if ! run_install_command /bin/mv "$BACKUP_APP" "$DESTINATION_APP" >/dev/null 2>&1; then
                    preserve_staging=1
                fi
            fi
            if [[ "$preserve_staging" == "1" ]]; then
                printf 'ERROR: Could not restore the previous app; backup retained at %s\n' "$BACKUP_APP" >&2
            fi
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
run_install_command /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
verify_expected_signature "$STAGED_APP"

RUNNING_PIDS="$(running_installed_pids)"
if [[ -n "$RUNNING_PIDS" ]]; then
    log "==> Quitting installed CodexBar instance"
    for _ in {1..20}; do
        RUNNING_PIDS="$(running_installed_pids)"
        [[ -n "$RUNNING_PIDS" ]] || break
        for pid in $RUNNING_PIDS; do
            /bin/kill "$pid" >/dev/null 2>&1 || true
        done
        sleep 0.25
    done
    if [[ -n "$(running_installed_pids)" ]]; then
        fail "The installed CodexBar did not quit; close it manually and run the script again."
    fi
fi

log "==> Installing ${DESTINATION_APP}"
if [[ -e "$DESTINATION_APP" || -L "$DESTINATION_APP" ]]; then
    PREVIOUS_APP_MOVED=1
    run_install_command /bin/mv "$DESTINATION_APP" "$BACKUP_APP"
fi
NEW_APP_INSTALLED=1
run_install_command /bin/mv "$STAGED_APP" "$DESTINATION_APP"
run_install_command /usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"
verify_expected_signature "$DESTINATION_APP"

INSTALL_COMPLETE=1
run_install_command /bin/rm -rf "$STAGING_DIR"
STAGING_DIR=""
trap - EXIT
log "Installed ${DESTINATION_APP}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
INSTALLED_APP="/Applications/CodexBar.app"
SIGNING_MODE="${CODEXBAR_SIGNING:-identity}"
SIGNING_IDENTITY="${APP_IDENTITY:-Developer ID Application: Peter Steinberger (Y5PE65HELJ)}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $(basename "$0") [release|debug]

Runs git pull --ff-only. Builds, installs, and launches through
Scripts/build_install_and_run.sh when HEAD or configuration differs from the last successful install.
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

case "$SIGNING_MODE" in
    identity)
        EXPECTED_TEAM_ID="$(signing_team_id "$SIGNING_IDENTITY")"
        [[ -n "$EXPECTED_TEAM_ID" ]] || fail "Could not determine the team ID for signing identity: ${SIGNING_IDENTITY}"
        if [[ -n "${APP_TEAM_ID:-}" && "$APP_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
            fail "APP_TEAM_ID=${APP_TEAM_ID} does not match signing identity team ${EXPECTED_TEAM_ID}."
        fi
        ;;
    adhoc) EXPECTED_TEAM_ID="${APP_TEAM_ID:-Y5PE65HELJ}" ;;
    *) fail "Unsupported CODEXBAR_SIGNING: ${SIGNING_MODE} (expected identity or adhoc)" ;;
esac

installed_bundle_matches() {
    local expected_head="$1"
    local bundle_id
    local installed_commit
    local installed_team_id
    local signature
    [[ -x "${INSTALLED_APP}/Contents/MacOS/CodexBar" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$INSTALLED_APP" >/dev/null 2>&1 || return 1
    bundle_id="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || return 1
    installed_team_id="$(
        /usr/libexec/PlistBuddy -c 'Print :CodexBarTeamID' \
            "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    [[ "$installed_team_id" == "$EXPECTED_TEAM_ID" ]] || return 1
    installed_commit="$(
        /usr/libexec/PlistBuddy -c 'Print :CodexGitCommit' \
            "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    case "$installed_commit" in
        ""|*[!0-9a-f]*) return 1 ;;
    esac
    [[ "$expected_head" == "${installed_commit}"* ]] || return 1
    signature="$(/usr/bin/codesign -d --verbose=4 "$INSTALLED_APP" 2>&1 || true)"
    printf '%s\n' "$signature" | /usr/bin/grep -Fx "Identifier=${EXPECTED_BUNDLE_ID}" >/dev/null || return 1
    if [[ "$SIGNING_MODE" == "identity" ]]; then
        printf '%s\n' "$signature" | /usr/bin/grep -Fx "Authority=${SIGNING_IDENTITY}" >/dev/null || return 1
        printf '%s\n' "$signature" | /usr/bin/grep -Fx "TeamIdentifier=${EXPECTED_TEAM_ID}" >/dev/null
    else
        printf '%s\n' "$signature" | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null
    fi
}

GIT_DIR="$(git -C "$ROOT_DIR" rev-parse --absolute-git-dir)"
INSTALL_STATE_FILE="${GIT_DIR}/codexbar-last-installed-head"
LAST_INSTALLED_HEAD=""
LAST_INSTALLED_CONFIGURATION=""
if [[ -f "$INSTALL_STATE_FILE" ]]; then
    {
        IFS= read -r LAST_INSTALLED_HEAD || true
        IFS= read -r LAST_INSTALLED_CONFIGURATION || true
    } < "$INSTALL_STATE_FILE"
fi

BEFORE_HEAD="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
log "==> Pulling latest changes"
git -C "$ROOT_DIR" pull --ff-only
AFTER_HEAD="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"

if [[ "$LAST_INSTALLED_HEAD" == "$AFTER_HEAD" && "$LAST_INSTALLED_CONFIGURATION" == "$CONFIGURATION" ]]; then
    if installed_bundle_matches "$AFTER_HEAD"; then
        log "Already up to date and installed (${CONFIGURATION}); skipping build."
        exit 0
    fi
    log "==> Recorded install no longer matches ${INSTALLED_APP}; reinstalling"
fi

if [[ "$BEFORE_HEAD" == "$AFTER_HEAD" ]]; then
    log "==> Retrying current commit because the installed bundle is missing, replaced, or unrecorded"
else
    log "==> Updated ${BEFORE_HEAD:0:12} -> ${AFTER_HEAD:0:12}"
fi
"${ROOT_DIR}/Scripts/build_install_and_run.sh" "$CONFIGURATION"

STATE_TMP="$(/usr/bin/mktemp "${INSTALL_STATE_FILE}.XXXXXX")"
printf '%s\n%s\n' "$AFTER_HEAD" "$CONFIGURATION" > "$STATE_TMP"
/bin/mv "$STATE_TMP" "$INSTALL_STATE_FILE"
log "Recorded successful install of ${AFTER_HEAD:0:12}."

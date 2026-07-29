#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

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
    debug|release) ;;
    *) fail "Unsupported build configuration: ${CONFIGURATION} (expected debug or release)" ;;
esac

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
    log "Already up to date and installed (${CONFIGURATION}); skipping build."
    exit 0
fi

if [[ "$BEFORE_HEAD" == "$AFTER_HEAD" ]]; then
    log "==> Retrying current commit because no successful install was recorded"
else
    log "==> Updated ${BEFORE_HEAD:0:12} -> ${AFTER_HEAD:0:12}"
fi
"${ROOT_DIR}/Scripts/build_install_and_run.sh" "$CONFIGURATION"

STATE_TMP="$(/usr/bin/mktemp "${INSTALL_STATE_FILE}.XXXXXX")"
printf '%s\n%s\n' "$AFTER_HEAD" "$CONFIGURATION" > "$STATE_TMP"
/bin/mv "$STATE_TMP" "$INSTALL_STATE_FILE"
log "Recorded successful install of ${AFTER_HEAD:0:12}."

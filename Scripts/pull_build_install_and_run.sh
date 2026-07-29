#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $(basename "$0") [release|debug]

Runs git pull --ff-only. If the current commit changes, builds, installs, and
launches the new CodexBar.app via Scripts/build_install_and_run.sh.
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

BEFORE_HEAD="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
log "==> Pulling latest changes"
git -C "$ROOT_DIR" pull --ff-only
AFTER_HEAD="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"

if [[ "$BEFORE_HEAD" == "$AFTER_HEAD" ]]; then
    log "Already up to date; skipping build and install."
    exit 0
fi

log "==> Updated ${BEFORE_HEAD:0:12} -> ${AFTER_HEAD:0:12}"
exec "${ROOT_DIR}/Scripts/build_install_and_run.sh" "$CONFIGURATION"

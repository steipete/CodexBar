#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED_APP="/Applications/CodexBar.app"
INSTALLED_EXECUTABLE="${INSTALLED_APP}/Contents/MacOS/CodexBar"
APP_NAME="CodexBar"
LAUNCH_ONLY=0

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

if [[ "${1:-}" == "--launch-installed-only" ]]; then
    LAUNCH_ONLY=1
    shift
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $(basename "$0") [release|debug]

Builds and installs CodexBar.app, quits the previous installed instance immediately
before replacement, then asks Finder to launch the new app through LaunchServices.
EOF
    exit 0
fi

process_executable() {
    local pid="$1"
    /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

installed_app_pids() {
    local executable
    local pid
    for pid in $(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true); do
        executable="$(process_executable "$pid" || true)"
        if [[ "$executable" == "$INSTALLED_EXECUTABLE" || "$executable" == "$EXPECTED_EXECUTABLE" ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

launch_installed_app() {
    /usr/bin/osascript - "$INSTALLED_APP" <<'APPLESCRIPT' >/dev/null
on run arguments
    set appAlias to POSIX file (item 1 of arguments) as alias
    tell application "Finder" to open appAlias
end run
APPLESCRIPT
}

blocked_status_item_log() {
    /usr/bin/log show --style compact --last 2m --info --debug \
        --predicate 'category == "appStatusItems"' 2>/dev/null \
        | /usr/bin/grep -F "Moving host to blocked list; (bid:${INSTALLED_BUNDLE_ID}-" \
        | /usr/bin/grep -F -- "-${APP_PID})" \
        | /usr/bin/tail -1 \
        || true
}

if [[ "$LAUNCH_ONLY" == "0" ]]; then
    CODEXBAR_VERIFY_LAUNCH=1 "${ROOT_DIR}/Scripts/build_and_install.sh" "$@"
    exit 0
fi
[[ $# -eq 0 ]] || fail "The internal launch-only mode does not accept arguments."
[[ -x "$INSTALLED_EXECUTABLE" ]] || fail "Installed executable is missing: ${INSTALLED_EXECUTABLE}"

EXPECTED_EXECUTABLE="$(canonical_path "$INSTALLED_EXECUTABLE")"
INSTALLED_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
)"
[[ -n "$INSTALLED_BUNDLE_ID" ]] || fail "Installed app has no CFBundleIdentifier."
APP_PID="$(installed_app_pids)"
if [[ "$APP_PID" == *$'\n'* ]]; then
    fail "Multiple installed CodexBar processes are already running."
fi

if [[ -z "$APP_PID" ]]; then
    log "==> Asking Finder to launch ${INSTALLED_APP} through LaunchServices"
    launch_installed_app
    for _ in {1..25}; do
        APP_PID="$(installed_app_pids)"
        if [[ "$APP_PID" == *$'\n'* ]]; then
            fail "LaunchServices started multiple installed CodexBar processes; close the extras and retry."
        fi
        [[ -z "$APP_PID" ]] || break
        sleep 0.2
    done
else
    log "==> Installed CodexBar already started during replacement"
fi

[[ -n "$APP_PID" ]] || \
    fail "CodexBar did not start or exited before detection. Check crash logs in Console.app."

for _ in {1..10}; do
    sleep 0.4
    if ! /bin/kill -0 "$APP_PID" >/dev/null 2>&1; then
        fail "The newly installed CodexBar exited immediately. Check crash logs in Console.app."
    fi
    RUNNING_EXECUTABLE="$(process_executable "$APP_PID" || true)"
    if [[ "$RUNNING_EXECUTABLE" != "$EXPECTED_EXECUTABLE" && "$RUNNING_EXECUTABLE" != "$INSTALLED_EXECUTABLE" ]]; then
        fail "PID ${APP_PID} is not running the installed CodexBar executable."
    fi
    CURRENT_PIDS="$(installed_app_pids)"
    if [[ "$CURRENT_PIDS" != "$APP_PID" ]]; then
        fail "The installed CodexBar process changed or another instance appeared; close the extras and retry."
    fi
done

BLOCKED_STATUS_ITEM_LOG="$(blocked_status_item_log)"
if [[ -n "$BLOCKED_STATUS_ITEM_LOG" ]]; then
    printf '%s\n' "$BLOCKED_STATUS_ITEM_LOG" >&2
    fail "CodexBar is running (pid ${APP_PID}), but macOS Control Center blocked its menu bar item. A disabled terminal or launcher may own a stale CodexBar attribution; see docs/packaging.md."
fi

log "OK: Installed CodexBar is running cleanly (pid ${APP_PID})."

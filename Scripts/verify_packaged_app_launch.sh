#!/usr/bin/env bash
# Launch smoke check for the packaged app (#2738).
#
# 0.48.0 crashed at launch on every user machine because SwiftPM's generated
# `Bundle.module` accessor only probes the app bundle root and the
# compile-time build directory. Local testing passed only because the build
# machine still had the checkout at that exact path. This check reproduces a
# user machine: it copies the packaged app to a temp directory, launches the
# binary directly (skipping LaunchServices, so it cannot re-activate a running
# production CodexBar) with every file read under the repo checkout denied via
# sandbox-exec, and requires the process to stay alive. A resource-bundle
# regression now fails packaging instead of shipping.

set -euo pipefail

APP_BUNDLE="${1:?usage: verify_packaged_app_launch.sh /path/to/CodexBar.app}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SMOKE_SECONDS="${CODEXBAR_LAUNCH_SMOKE_SECONDS:-6}"
# Swift runtime trap signatures for a missing SwiftPM resource bundle. These
# always hard-fail packaging, even without a GUI session.
FATAL_PATTERN='Fatal error|could not load resource bundle|unable to find bundle named'

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [[ "${CODEXBAR_SKIP_LAUNCH_SMOKE:-0}" == "1" ]]; then
  log "Launch smoke check: skipped (CODEXBAR_SKIP_LAUNCH_SMOKE=1)."
  exit 0
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/CodexBar" ]]; then
  echo "ERROR: Launch smoke check: missing executable in ${APP_BUNDLE}" >&2
  exit 1
fi
if [[ ! -x "$APP_BUNDLE/Contents/Helpers/CodexBarCLI" ]]; then
  echo "ERROR: Launch smoke check: missing Helpers/CodexBarCLI in ${APP_BUNDLE}" >&2
  exit 1
fi
if [[ ! -d "$APP_BUNDLE/Contents/Helpers/CodexBar_CodexBarCore.bundle" ]]; then
  echo "ERROR: Launch smoke check: missing CodexBarCore resource bundle beside Helpers/CodexBarCLI" >&2
  exit 1
fi

if ! command -v sandbox-exec >/dev/null 2>&1; then
  warn "Launch smoke check skipped: sandbox-exec is unavailable on this system."
  exit 0
fi
# Managed sandbox (Muse) blocks sandbox-exec with Operation not permitted.
if ! sandbox-exec -p "(version 1)(allow default)" /usr/bin/true >/dev/null 2>&1; then
  warn "Launch smoke check skipped: sandbox-exec denied (Operation not permitted under managed sandbox)."
  exit 0
fi

# Launching a menu-bar app without an Aqua session (SSH, headless CI) can fail
# for reasons unrelated to resources. In that case only the resource-bundle
# fatal signature fails packaging; other early exits merely warn.
GUI_SESSION=1
if [[ "$(launchctl managername 2>/dev/null || true)" != "Aqua" ]]; then
  GUI_SESSION=0
  warn "Launch smoke check: no Aqua session; only the resource-bundle fatal signature will fail packaging."
fi

SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-launch-smoke.XXXXXX")"
SMOKE_PID=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  # Kill only our own spawned PID; never pattern-kill, so a running production
  # CodexBar is untouched.
  if [[ -n "$SMOKE_PID" ]]; then
    if kill -0 "$SMOKE_PID" 2>/dev/null; then
      kill "$SMOKE_PID" 2>/dev/null || true
      for _ in {1..15}; do
        kill -0 "$SMOKE_PID" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 "$SMOKE_PID" 2>/dev/null || true
    fi
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT INT TERM

cp -R "$APP_BUNDLE" "$SMOKE_DIR/CodexBar.app"
SMOKE_BIN="$SMOKE_DIR/CodexBar.app/Contents/MacOS/CodexBar"
CLI_BIN="$SMOKE_DIR/CodexBar.app/Contents/Helpers/CodexBarCLI"
CLI_SYMLINK_DIR="$SMOKE_DIR/bin"
CLI_SYMLINK="$CLI_SYMLINK_DIR/codexbar"
SMOKE_LOG="$SMOKE_DIR/launch.log"
PROBE_LOG="$SMOKE_DIR/probe.log"
CLI_PROBE_LOG="$SMOKE_DIR/cli-probe.log"
CLI_SYMLINK_PROBE_LOG="$SMOKE_DIR/cli-symlink-probe.log"
mkdir -p "$CLI_SYMLINK_DIR"
ln -s "$CLI_BIN" "$CLI_SYMLINK"
SANDBOX_PROFILE="(version 1)
(allow default)
(deny file-read* (subpath \"${ROOT}\"))"

fail_with_probe_log() {
  echo "ERROR: $1" >&2
  echo "----- probe output (tail) -----" >&2
  tail -40 "$PROBE_LOG" >&2 || true
  echo "-------------------------------" >&2
  exit 1
}

fail_with_cli_probe_log() {
  echo "ERROR: $1" >&2
  echo "----- CLI probe output (tail) -----" >&2
  tail -40 "$CLI_PROBE_LOG" >&2 || true
  echo "-----------------------------------" >&2
  exit 1
}

fail_with_cli_symlink_probe_log() {
  echo "ERROR: $1" >&2
  echo "----- CLI symlink probe output (tail) -----" >&2
  tail -40 "$CLI_SYMLINK_PROBE_LOG" >&2 || true
  echo "-------------------------------------------" >&2
  exit 1
}

# Probe the executable-context resolver before the app-context resolver. The
# checkout denial proves the helper is using its adjacent bundle rather than
# SwiftPM's compile-time development path.
log "Launch smoke check: probing packaged Helpers CLI resource loads with ${ROOT} unreadable."
(
  cd "$SMOKE_DIR"
  exec env CODEXBAR_RESOURCE_SMOKE=1 sandbox-exec -p "$SANDBOX_PROFILE" "$CLI_BIN"
) >"$CLI_PROBE_LOG" 2>&1 &
SMOKE_PID=$!
CLI_PROBE_OK=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    CLI_PROBE_OK=1
    break
  fi
  sleep 0.5
done
if [[ "$CLI_PROBE_OK" == "0" ]]; then
  fail_with_cli_probe_log "Launch smoke check FAILED: Helpers CLI resource probe did not finish within 30s."
fi
CLI_PROBE_STATUS=0
wait "$SMOKE_PID" || CLI_PROBE_STATUS=$?
SMOKE_PID=""
if [[ "$CLI_PROBE_STATUS" -ne 0 ]] || ! grep -q "CODEXBAR_RESOURCE_SMOKE_OK" "$CLI_PROBE_LOG"; then
  fail_with_cli_probe_log "Launch smoke check FAILED: packaged Helpers CLI cannot load CodexBarCore resources without the build checkout. Exit status: ${CLI_PROBE_STATUS}."
fi
log "Launch smoke check: Helpers CLI resource probe OK."

log "Launch smoke check: probing symlinked Helpers CLI resource loads with ${ROOT} unreadable."
(
  cd "$SMOKE_DIR"
  exec env CODEXBAR_RESOURCE_SMOKE=1 sandbox-exec -p "$SANDBOX_PROFILE" "$CLI_SYMLINK"
) >"$CLI_SYMLINK_PROBE_LOG" 2>&1 &
SMOKE_PID=$!
CLI_SYMLINK_PROBE_OK=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    CLI_SYMLINK_PROBE_OK=1
    break
  fi
  sleep 0.5
done
if [[ "$CLI_SYMLINK_PROBE_OK" == "0" ]]; then
  fail_with_cli_symlink_probe_log "Launch smoke check FAILED: symlinked Helpers CLI resource probe did not finish within 30s."
fi
CLI_SYMLINK_PROBE_STATUS=0
wait "$SMOKE_PID" || CLI_SYMLINK_PROBE_STATUS=$?
SMOKE_PID=""
if [[ "$CLI_SYMLINK_PROBE_STATUS" -ne 0 ]] || ! grep -q "CODEXBAR_RESOURCE_SMOKE_OK" "$CLI_SYMLINK_PROBE_LOG"; then
  fail_with_cli_symlink_probe_log "Launch smoke check FAILED: symlinked packaged Helpers CLI cannot load CodexBarCore resources without the build checkout. Exit status: ${CLI_SYMLINK_PROBE_STATUS}."
fi
log "Launch smoke check: symlinked Helpers CLI resource probe OK."

# Phase 1 (deterministic, headless-safe): CODEXBAR_RESOURCE_SMOKE=1 makes the
# app force the resource loads that trapped in 0.48.0 and exit before any UI.
# The loads are lazy in normal operation, so the liveness phase below cannot be
# relied on alone to reach them.
log "Launch smoke check: probing packaged resource loads with ${ROOT} unreadable."
(
  cd "$SMOKE_DIR"
  exec env CODEXBAR_RESOURCE_SMOKE=1 sandbox-exec -p "$SANDBOX_PROFILE" "$SMOKE_BIN"
) >"$PROBE_LOG" 2>&1 &
SMOKE_PID=$!
PROBE_OK=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    PROBE_OK=1
    break
  fi
  sleep 0.5
done
if [[ "$PROBE_OK" == "0" ]]; then
  fail_with_probe_log "Launch smoke check FAILED: resource probe did not finish within 30s."
fi
PROBE_STATUS=0
wait "$SMOKE_PID" || PROBE_STATUS=$?
SMOKE_PID=""
if [[ "$PROBE_STATUS" -ne 0 ]] || ! grep -q "CODEXBAR_RESOURCE_SMOKE_OK" "$PROBE_LOG"; then
  fail_with_probe_log "Launch smoke check FAILED: packaged app cannot load its resource bundles without the build checkout (the 0.48.0 crash class, #2738). Do not ship this build. Exit status: ${PROBE_STATUS}."
fi
log "Launch smoke check: resource probe OK."

# Phase 2: launch the app for real and require it to stay alive.
log "Launch smoke check: running packaged binary with ${ROOT} unreadable for ${SMOKE_SECONDS}s."
(
  cd "$SMOKE_DIR"
  exec sandbox-exec -p "$SANDBOX_PROFILE" "$SMOKE_BIN"
) >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!

ALIVE=1
TICKS=$((SMOKE_SECONDS * 2))
for _ in $(seq 1 "$TICKS"); do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    ALIVE=0
    break
  fi
  sleep 0.5
done

fail_with_log() {
  echo "ERROR: $1" >&2
  echo "----- launch output (tail) -----" >&2
  tail -40 "$SMOKE_LOG" >&2 || true
  echo "--------------------------------" >&2
  exit 1
}

if grep -Eq "$FATAL_PATTERN" "$SMOKE_LOG"; then
  fail_with_log "Launch smoke check FAILED: packaged app hit a resource-bundle fatal error with the build checkout unreachable (the 0.48.0 crash class, #2738). Do not ship this build."
fi

if [[ "$ALIVE" == "1" ]]; then
  log "Launch smoke check OK: packaged app survived ${SMOKE_SECONDS}s without the build checkout."
  exit 0
fi

wait "$SMOKE_PID" 2>/dev/null || true
SMOKE_PID=""

if [[ "$GUI_SESSION" == "0" ]]; then
  warn "Launch smoke check inconclusive: app exited early without the resource-bundle fatal signature (no Aqua session; likely unrelated to resources)."
  exit 0
fi

fail_with_log "Launch smoke check FAILED: packaged app exited within ${SMOKE_SECONDS}s of a direct launch."

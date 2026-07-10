#!/usr/bin/env bash
# Live reproduction helper for CodexBar Keychain prompt reports (#1991 / #2025 / #2024).
# Exits 0 when the expected hang/prompt window is observed; 1 on unexpected failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${CODEXBAR_CLI:-/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI}"
APP_BUNDLE="${CODEXBAR_APP:-/Applications/CodexBar.app}"
HANG_SECONDS="${HANG_SECONDS:-12}"
MODE="${1:-all}"

log() { printf '[repro-keychain] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

require_cli() {
  [[ -x "$CLI" ]] || die "Missing CodexBarCLI at $CLI"
}

seed_oauth_claude_cache() {
  python3 - "$APP_BUNDLE" <<'PY'
import base64
import json
import subprocess
import sys

app_bundle = sys.argv[1]
creds_json = json.dumps(
    {
        "claudeAiOauth": {
            "accessToken": "repro-cache-token",
            "expiresAt": 1999999999999,
            "scopes": ["user:profile"],
            "refreshToken": "repro-cache-refresh",
        }
    }
).encode()
entry = {
    "data": base64.b64encode(creds_json).decode(),
    "storedAt": "2026-07-10T04:20:00Z",
    "owner": "claudeCLI",
}
payload = json.dumps(entry)
subprocess.run(
    ["security", "delete-generic-password", "-s", "com.steipete.codexbar.cache", "-a", "oauth.claude"],
    capture_output=True,
)
result = subprocess.run(
    [
        "security",
        "add-generic-password",
        "-s",
        "com.steipete.codexbar.cache",
        "-a",
        "oauth.claude",
        "-l",
        "CodexBar Cache",
        "-w",
        payload,
        "-T",
        f"{app_bundle}/Contents/MacOS/CodexBar",
        "-T",
        f"{app_bundle}/Contents/Helpers/CodexBarCLI",
    ],
    capture_output=True,
    text=True,
)
if result.returncode != 0:
    raise SystemExit(result.stderr.strip() or "failed to seed oauth.claude cache")
print("seeded oauth.claude cache")
PY
}

wait_for_hang() {
  local label="$1"
  shift
  local pid log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/codexbar-repro-log.XXXXXX")"
  "$@" >"${log_file}.out" 2>"${log_file}" &
  pid=$!
  log "started $label (pid=$pid); watching for ${HANG_SECONDS}s"
  sleep "$HANG_SECONDS"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    log "REPRO OK: $label hung for >=${HANG_SECONDS}s (likely macOS Keychain UI)"
    if [[ -s "${log_file}" ]]; then
      log "recent log lines:"
      tail -5 "${log_file}" | sed 's/^/[repro-keychain]   /'
    fi
    rm -f "${log_file}" "${log_file}.out"
    return 0
  fi
  wait "$pid"
  local status=$?
  log "REPRO MISS: $label finished early with exit $status"
  if [[ -s "${log_file}" ]]; then
    tail -10 "${log_file}" | sed 's/^/[repro-keychain]   /'
  fi
  rm -f "${log_file}" "${log_file}.out"
  return 1
}

cleanup() {
  if [[ -f "${HOME}/.claude/.credentials.json.repro-backup" ]]; then
    mv "${HOME}/.claude/.credentials.json.repro-backup" "${HOME}/.claude/.credentials.json"
  else
    rm -f "${HOME}/.claude/.credentials.json"
  fi
  defaults delete com.steipete.codexbar claudeOAuthKeychainPromptMode 2>/dev/null || true
  security delete-generic-password -s "com.steipete.codexbar.cache" -a "oauth.claude" 2>/dev/null || true
}

repro_2025() {
  log "=== #2025 / #1991: Claude oauth.claude cache under never prompt ==="
  mkdir -p "${HOME}/.claude"
  if [[ -f "${HOME}/.claude/.credentials.json" ]]; then
    cp "${HOME}/.claude/.credentials.json" "${HOME}/.claude/.credentials.json.repro-backup"
  fi
  cat >"${HOME}/.claude/.credentials.json" <<'EOF'
{
  "claudeAiOauth": {
    "accessToken": "repro-file-token",
    "expiresAt": 1999999999999,
    "scopes": ["user:profile"],
    "refreshToken": "repro-file-refresh"
  }
}
EOF
  defaults write com.steipete.codexbar claudeOAuthKeychainPromptMode onlyOnUserAction
  pkill -x CodexBar 2>/dev/null || true
  sleep 1
  log "establishing credentials-file fingerprint"
  "$CLI" usage --provider claude --source oauth --json-output --log-level info >/dev/null 2>&1 || true
  seed_oauth_claude_cache
  defaults write com.steipete.codexbar claudeOAuthKeychainPromptMode never
  wait_for_hang "CodexBarCLI claude oauth" \
    "$CLI" usage --provider claude --source oauth --json-output --log-level debug
}

repro_2024() {
  log "=== #2024: browser Safe Storage via Claude web cookie import ==="
  defaults delete com.steipete.codexbar browserCookieAccessDeniedUntil 2>/dev/null || true
  pkill -x CodexBar 2>/dev/null || true
  sleep 1
  wait_for_hang "CodexBarCLI claude web" \
    "$CLI" usage --provider claude --source web --json-output --log-level debug
}

main() {
  require_cli
  trap cleanup EXIT
  case "$MODE" in
    2025) repro_2025 ;;
    2024) repro_2024 ;;
    all)
      repro_2025 || true
      repro_2024 || true
      ;;
    *)
      die "usage: $0 [2025|2024|all]"
      ;;
  esac
  cleanup
  trap - EXIT
}

main "$@"

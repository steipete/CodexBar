#!/usr/bin/env bash
# Live reproduction helper for CodexBar Keychain prompt reports (#1991 / #2025 / #2024).
# Exits 0 when the expected hang/prompt window is observed; 1 on unexpected failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${CODEXBAR_CLI:-/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI}"
APP_BUNDLE="${CODEXBAR_APP:-/Applications/CodexBar.app}"
HANG_SECONDS="${HANG_SECONDS:-12}"
MODE="${1:-all}"
APP_DEFAULTS_DOMAIN="com.steipete.codexbar"
CLI_DEFAULTS_DOMAIN="CodexBarCLI"
PROMPT_MODE_KEY="claudeOAuthKeychainPromptMode"
BROWSER_COOKIE_KEY="browserCookieAccessDeniedUntil"

CREDS_BACKUP=""
CREDS_CREATED=0
PROMPT_MODE_APP_BACKUP=""
PROMPT_MODE_CLI_BACKUP=""
PROMPT_MODE_APP_HAD=0
PROMPT_MODE_CLI_HAD=0
PROMPT_MODE_CHANGED=0
CACHE_BACKUP=""
CACHE_HAD_ITEM=0
CACHE_SEEDED=0
BROWSER_COOKIE_BACKUP=""
BROWSER_COOKIE_HAD=0
BROWSER_COOKIE_TOUCHED=0
REPRO_FAILED=0

log() { printf '[repro-keychain] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

require_cli() {
  [[ -x "$CLI" ]] || die "Missing CodexBarCLI at $CLI"
}

backup_prompt_mode() {
  if defaults read "$APP_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" &>/dev/null; then
    PROMPT_MODE_APP_BACKUP="$(defaults read "$APP_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY")"
    PROMPT_MODE_APP_HAD=1
  fi
  if defaults read "$CLI_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" &>/dev/null; then
    PROMPT_MODE_CLI_BACKUP="$(defaults read "$CLI_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY")"
    PROMPT_MODE_CLI_HAD=1
  fi
}

set_prompt_mode() {
  defaults write "$APP_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" "$1"
  defaults write "$CLI_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" "$1"
  PROMPT_MODE_CHANGED=1
}

restore_prompt_mode() {
  [[ $PROMPT_MODE_CHANGED -eq 1 ]] || return 0
  if [[ $PROMPT_MODE_APP_HAD -eq 1 ]]; then
    defaults write "$APP_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" "$PROMPT_MODE_APP_BACKUP"
  else
    defaults delete "$APP_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" 2>/dev/null || true
  fi
  if [[ $PROMPT_MODE_CLI_HAD -eq 1 ]]; then
    defaults write "$CLI_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" "$PROMPT_MODE_CLI_BACKUP"
  else
    defaults delete "$CLI_DEFAULTS_DOMAIN" "$PROMPT_MODE_KEY" 2>/dev/null || true
  fi
}

backup_browser_cookie_cooldown() {
  local plist="${HOME}/Library/Preferences/${CLI_DEFAULTS_DOMAIN}.plist"
  if [[ ! -f "$plist" ]] || ! defaults read "$CLI_DEFAULTS_DOMAIN" "$BROWSER_COOKIE_KEY" &>/dev/null; then
    return 0
  fi
  BROWSER_COOKIE_BACKUP="$(mktemp "${TMPDIR:-/tmp}/codexbar-browser-cookie-backup.XXXXXX.plist")"
  python3 - "$CLI_DEFAULTS_DOMAIN" "$BROWSER_COOKIE_KEY" "$BROWSER_COOKIE_BACKUP" <<'PY'
import plistlib
import pathlib
import sys

domain, key, out_path = sys.argv[1:4]
plist_path = pathlib.Path.home() / "Library/Preferences" / f"{domain}.plist"
data = plistlib.load(plist_path.open("rb"))
with open(out_path, "wb") as handle:
    plistlib.dump({key: data[key]}, handle)
PY
  BROWSER_COOKIE_HAD=1
}

clear_browser_cookie_cooldown_for_repro() {
  defaults delete "$CLI_DEFAULTS_DOMAIN" "$BROWSER_COOKIE_KEY" 2>/dev/null || true
  BROWSER_COOKIE_TOUCHED=1
}

restore_browser_cookie_cooldown() {
  [[ $BROWSER_COOKIE_TOUCHED -eq 1 ]] || return 0
  if [[ $BROWSER_COOKIE_HAD -eq 1 && -n "$BROWSER_COOKIE_BACKUP" && -f "$BROWSER_COOKIE_BACKUP" ]]; then
    defaults import "$CLI_DEFAULTS_DOMAIN" "$BROWSER_COOKIE_BACKUP"
  else
    defaults delete "$CLI_DEFAULTS_DOMAIN" "$BROWSER_COOKIE_KEY" 2>/dev/null || true
  fi
  rm -f "$BROWSER_COOKIE_BACKUP"
  BROWSER_COOKIE_BACKUP=""
}

backup_oauth_cache() {
  CACHE_BACKUP="$(mktemp "${TMPDIR:-/tmp}/codexbar-oauth-cache-backup.XXXXXX")"
  if security find-generic-password -s "com.steipete.codexbar.cache" -a "oauth.claude" -w \
    >"$CACHE_BACKUP" 2>/dev/null; then
    CACHE_HAD_ITEM=1
  else
    rm -f "$CACHE_BACKUP"
    CACHE_BACKUP=""
  fi
}

restore_oauth_cache() {
  security delete-generic-password -s "com.steipete.codexbar.cache" -a "oauth.claude" 2>/dev/null || true
  if [[ $CACHE_HAD_ITEM -eq 1 && -n "$CACHE_BACKUP" && -s "$CACHE_BACKUP" ]]; then
    security add-generic-password \
      -s "com.steipete.codexbar.cache" \
      -a "oauth.claude" \
      -l "CodexBar Cache" \
      -w "$(cat "$CACHE_BACKUP")" \
      -T "${APP_BUNDLE}/Contents/MacOS/CodexBar" \
      -T "${APP_BUNDLE}/Contents/Helpers/CodexBarCLI" \
      2>/dev/null || true
  fi
  rm -f "$CACHE_BACKUP"
  CACHE_BACKUP=""
}

seed_oauth_claude_cache() {
  backup_oauth_cache
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
  CACHE_SEEDED=1
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
  if [[ -n "$CREDS_BACKUP" && -f "$CREDS_BACKUP" ]]; then
    mv "$CREDS_BACKUP" "${HOME}/.claude/.credentials.json"
  elif [[ $CREDS_CREATED -eq 1 ]]; then
    rm -f "${HOME}/.claude/.credentials.json"
  fi

  restore_prompt_mode
  restore_browser_cookie_cooldown

  if [[ $CACHE_SEEDED -eq 1 || $CACHE_HAD_ITEM -eq 1 ]]; then
    restore_oauth_cache
  fi
}

repro_2025() {
  log "=== #2025 / #1991: Claude oauth.claude cache under never prompt ==="
  backup_prompt_mode
  mkdir -p "${HOME}/.claude"
  if [[ -f "${HOME}/.claude/.credentials.json" ]]; then
    CREDS_BACKUP="${HOME}/.claude/.credentials.json.repro-backup"
    cp "${HOME}/.claude/.credentials.json" "$CREDS_BACKUP"
  else
    CREDS_CREATED=1
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
  set_prompt_mode onlyOnUserAction
  pkill -x CodexBar 2>/dev/null || true
  sleep 1
  log "establishing credentials-file fingerprint"
  "$CLI" usage --provider claude --source oauth --json-output --log-level info >/dev/null 2>&1 || true
  seed_oauth_claude_cache
  set_prompt_mode never
  wait_for_hang "CodexBarCLI claude oauth" \
    "$CLI" usage --provider claude --source oauth --json-output --log-level debug
}

repro_2024() {
  log "=== #2024: browser Safe Storage via Claude web cookie import ==="
  backup_browser_cookie_cooldown
  clear_browser_cookie_cooldown_for_repro
  pkill -x CodexBar 2>/dev/null || true
  sleep 1
  wait_for_hang "CodexBarCLI claude web" \
    "$CLI" usage --provider claude --source web --json-output --log-level debug
}

run_repro() {
  if ! "$@"; then
    REPRO_FAILED=1
  fi
}

main() {
  require_cli
  trap cleanup EXIT
  case "$MODE" in
    2025) run_repro repro_2025 ;;
    2024) run_repro repro_2024 ;;
    all)
      run_repro repro_2025
      run_repro repro_2024
      ;;
    *)
      die "usage: $0 [2025|2024|all]"
      ;;
  esac
  cleanup
  trap - EXIT
  return "$REPRO_FAILED"
}

main "$@"
exit $?

#!/usr/bin/env bash
# Live verification for CodexBar #1844 / PR #1848
# Usage: ./Scripts/verify_1844_live.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARTIFACT="${TMPDIR:-/tmp}/codexbar-1844-verify"
mkdir -p "$ARTIFACT"

CLI="${CODEXBAR_CLI:-$ROOT/.build/release/CodexBarCLI}"
if [[ ! -x "$CLI" ]]; then
  CLI="$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI"
fi
if [[ ! -x "$CLI" ]]; then
  echo "Building CodexBarCLI..."
  swift build -c release --product CodexBarCLI
  CLI="$ROOT/.build/release/CodexBarCLI"
fi

log() { printf '[verify-1844] %s\n' "$*"; }

log "Phase 1: macOS integration tests"
swift test --filter 'mcp O auth|delegated retry experimental|load with auto refresh expired claude CLI owner throws mcp' \
  2>&1 | tee "$ARTIFACT/integration-tests.log"
log "Phase 1 passed"

KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="codexbar-verify-1844"
CREDS_REAL="$HOME/.claude/.credentials.json"
CREDS_BACKUP="$ARTIFACT/credentials.json.backup"
CONFIG="$ARTIFACT/config.json"
MCP_PAYLOAD='{"mcpOAuth":{"plugin:slack:slack":{"accessToken":""},"craft":{"accessToken":""}}}'
EXPIRED_PAYLOAD='{"claudeAiOauth":{"accessToken":"verify-expired-redacted","expiresAt":1000,"scopes":["user:profile"],"refreshToken":"verify-refresh-redacted"}}'

HAD_CREDS=0
[[ -f "$CREDS_REAL" ]] && HAD_CREDS=1 && cp -p "$CREDS_REAL" "$CREDS_BACKUP"

cleanup() {
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
  if [[ "$HAD_CREDS" -eq 1 && -f "$CREDS_BACKUP" ]]; then
    mv -f "$CREDS_BACKUP" "$CREDS_REAL"
  else
    rm -f "$CREDS_REAL"
  fi
}
trap cleanup EXIT

log "Phase 2: optional Keychain fixture E2E"
log "Approve the macOS Keychain prompt if shown (required once to install the test fixture)."

security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
if ! security add-generic-password \
  -a "$KEYCHAIN_ACCOUNT" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$MCP_PAYLOAD" \
  -T "$CLI" \
  -U 2>"$ARTIFACT/keychain-install.err"; then
  log "Phase 2 skipped: could not install Keychain fixture (see $ARTIFACT/keychain-install.err)"
  log "Phase 1 integration results remain valid for review."
  exit 0
fi

mkdir -p "$HOME/.claude"
printf '%s\n' "$EXPIRED_PAYLOAD" >"$CREDS_REAL"
chmod 600 "$CREDS_REAL"
printf '%s\n' '{"version":1,"providers":[{"id":"claude","enabled":true}]}' >"$CONFIG"

PROC_LOG="$ARTIFACT/e2e-proc.log"
: >"$PROC_LOG"
log "Running background Claude OAuth CLI probe"
(
  CODEXBAR_CONFIG="$CONFIG" CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW=1 \
    "$CLI" usage --provider claude --source oauth --format json --json-output --log-level debug \
      >"$ARTIFACT/e2e-stdout.json" 2>"$ARTIFACT/e2e-stderr.jsonl"
) &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  { date -u +%H:%M:%S; pgrep -P "$PID" -l 2>/dev/null || true
    pgrep -fl '/usr/bin/open|firefox|claude' 2>/dev/null | rg -v 'CodexBarCLI|verify_1844' || true
  } >>"$PROC_LOG"
  sleep 0.05
done
wait "$PID" || true

{
  echo "# CodexBar #1844 E2E verification"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "claude: $(claude --version 2>/dev/null || echo n/a)"
  echo
  echo "## stdout"
  cat "$ARTIFACT/e2e-stdout.json"
  echo
  echo "## stderr (filtered)"
  rg -i 'mcp|delegated|expired|oauth|touch|open|only prompt' "$ARTIFACT/e2e-stderr.jsonl" || true
  echo
  echo "## child processes"
  cat "$PROC_LOG"
} | tee "$ARTIFACT/E2E-REPORT.md"

if rg -q '/usr/bin/open|firefox' "$PROC_LOG" 2>/dev/null; then
  log "Phase 2 failed: browser or open helper launched"
  exit 1
fi
if rg -q 'delegated refresh touch' "$ARTIFACT/e2e-stderr.jsonl" 2>/dev/null; then
  log "Phase 2 failed: delegated CLI touch ran"
  exit 1
fi
if ! rg -qi 'mcp oauth|MCP OAuth state only|only prompt on user action' \
  "$ARTIFACT/e2e-stderr.jsonl" "$ARTIFACT/e2e-stdout.json" 2>/dev/null; then
  log "Phase 2 failed: expected fail-closed OAuth messaging not found"
  exit 1
fi

log "Phase 2 passed: background probe failed closed without open or delegated CLI touch"
log "Report: $ARTIFACT/E2E-REPORT.md"

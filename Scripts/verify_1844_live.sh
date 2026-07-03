#!/usr/bin/env bash
# Isolated live verification for CodexBar #1844 / PR #1848.
# Uses only synthetic credentials under a disposable HOME and keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '[verify-1844] %s\n' "$*"; }

ARTIFACT="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-1844-verify.XXXXXX")"
chmod 700 "$ARTIFACT"
HOME_FIXTURE="$ARTIFACT/home"
KEYCHAIN="$ARTIFACT/claude-fixture.keychain-db"
KEYCHAIN_PASSWORD="codexbar-1844-synthetic-fixture"
CONFIG="$ARTIFACT/config.json"
CLI="${CODEXBAR_CLI:-$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI}"
APP="${CODEXBAR_APP_BINARY:-$ROOT/CodexBar.app/Contents/MacOS/CodexBar}"
MCP_PAYLOAD='{"mcpOAuth":{"plugin:synthetic":{"accessToken":"synthetic-mcp-token"}}}'
EXPIRED_PAYLOAD='{"claudeAiOauth":{"accessToken":"synthetic-expired-token","expiresAt":1000,"scopes":["user:profile"],"refreshToken":"synthetic-refresh-token"}}'

if [[ ! -x "$CLI" ]]; then
  log "Missing packaged CLI: $CLI"
  log "Run ./Scripts/package_app.sh, then retry."
  exit 2
fi
if [[ ! -x "$APP" ]]; then
  log "Missing packaged app binary: $APP"
  exit 2
fi

cleanup() {
  /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Artifacts: $ARTIFACT"
log "Phase 1: focused integration tests"
{
  swift test --filter ClaudeOAuthTests
  swift test --filter ClaudeUsageTests
  swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
  swift test --filter 'expired claude CLI owner blocks background'
  swift test --filter ClaudeOAuthCredentialsStoreSecurityCLITests
  swift test --filter ClaudeOAuthCredentialsStoreIsolatedSecurityCLITests
  swift test --filter ClaudeOAuthCredentialsStoreMCPOnlyGuardTests
} 2>&1 | tee "$ARTIFACT/integration-tests.log"
log "Phase 1 passed"

log "Phase 2: disposable HOME, keychain, credentials, config, and Claude CLI canary"
mkdir -p "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/Library/Preferences" "$ARTIFACT/bin"
chmod 700 "$HOME_FIXTURE" "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/Library" \
  "$HOME_FIXTURE/Library/Preferences" "$ARTIFACT/bin"
printf '%s\n' "$EXPIRED_PAYLOAD" >"$HOME_FIXTURE/.claude/.credentials.json"
chmod 600 "$HOME_FIXTURE/.claude/.credentials.json"
printf '%s\n' '{"version":1,"providers":[{"id":"claude","enabled":true,"source":"oauth"}]}' >"$CONFIG"
chmod 600 "$CONFIG"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "args:" >>"$CODEXBAR_CLAUDE_INVOCATIONS"' \
  'printf " %q" "$@" >>"$CODEXBAR_CLAUDE_INVOCATIONS"' \
  'printf "\\n" >>"$CODEXBAR_CLAUDE_INVOCATIONS"' \
  'if [[ "$*" == "auth status --json" ]]; then printf "{\"loggedIn\":true}\\n"; exit 0; fi' \
  'if [[ "$*" == "--version" ]]; then printf "2.1.0\\n"; exit 0; fi' \
  'if IFS= read -r line; then' \
  '  printf "stdin:%s\\n" "$line" >>"$CODEXBAR_CLAUDE_INVOCATIONS"' \
  '  if [[ "$line" == *"/status"* ]]; then printf touched >"$CODEXBAR_CLAUDE_TOUCH_CANARY"; fi' \
  'fi' \
  'exit 99' \
  >"$ARTIFACT/bin/claude"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf touched >"$CODEXBAR_OPEN_TOUCH_CANARY"' \
  'exit 99' \
  >"$ARTIFACT/bin/open"
chmod 700 "$ARTIFACT/bin/claude" "$ARTIFACT/bin/open"

/usr/bin/security list-keychains -d user >"$ARTIFACT/keychains-before.txt"
/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
/usr/bin/security set-keychain-settings -t 3600 "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
/usr/bin/security add-generic-password \
  -a codexbar-verify-1844 \
  -s 'Claude Code-credentials' \
  -w "$MCP_PAYLOAD" \
  -A \
  "$KEYCHAIN"
/usr/bin/security list-keychains -d user >"$ARTIFACT/keychains-after.txt"
if ! cmp -s "$ARTIFACT/keychains-before.txt" "$ARTIFACT/keychains-after.txt"; then
  log "Phase 2 failed: creating the disposable keychain changed the user search list"
  exit 1
fi
/usr/bin/security find-generic-password \
  -s 'Claude Code-credentials' \
  -w \
  "$KEYCHAIN" >"$ARTIFACT/keychain-fixture.json"
cmp -s "$ARTIFACT/keychain-fixture.json" <(printf '%s\n' "$MCP_PAYLOAD")

PROC_LOG="$ARTIFACT/e2e-processes.log"
STDOUT="$ARTIFACT/e2e-stdout.json"
STDERR="$ARTIFACT/e2e-stderr.jsonl"
CANARY="$ARTIFACT/claude-status-canary"
INVOCATIONS="$ARTIFACT/claude-invocations.log"
OPEN_CANARY="$ARTIFACT/open-touch-canary"
: >"$PROC_LOG"
: >"$INVOCATIONS"

set +e
(
  env \
    HOME="$HOME_FIXTURE" \
    CFFIXED_USER_HOME="$HOME_FIXTURE" \
    CODEXBAR_CONFIG="$CONFIG" \
    CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 \
    CODEXBAR_CLAUDE_SECURITY_CLI_KEYCHAIN="$KEYCHAIN" \
    CODEXBAR_CLAUDE_TOUCH_CANARY="$CANARY" \
    CODEXBAR_CLAUDE_INVOCATIONS="$INVOCATIONS" \
    CODEXBAR_OPEN_TOUCH_CANARY="$OPEN_CANARY" \
    CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW=1 \
    CLAUDE_CLI_PATH="$ARTIFACT/bin/claude" \
    PATH="$ARTIFACT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$CLI" usage --provider claude --source oauth --format json --pretty --log-level debug \
      >"$STDOUT" 2>"$STDERR"
) &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  {
    date -u +%H:%M:%S
    pgrep -P "$PID" -l 2>/dev/null || true
  } >>"$PROC_LOG"
  sleep 0.02
done
wait "$PID"
CLI_STATUS=$?
set -e

{
  echo "# CodexBar #1844 isolated E2E verification"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "candidate: $(git rev-parse HEAD)"
  echo "packaged-cli: $CLI"
  echo "cli-exit: $CLI_STATUS"
  echo "default-keychain-search-list-unchanged: yes"
  echo "real-home-referenced: no"
  echo "claude-status-canary: $([[ -e "$CANARY" ]] && echo touched || echo untouched)"
  echo "open-touch-canary: $([[ -e "$OPEN_CANARY" ]] && echo touched || echo untouched)"
  echo
  echo "## stdout"
  cat "$STDOUT"
  echo
  echo "## stderr (filtered)"
  rg -i 'mcp|delegated|expired|oauth|touch|open|only prompt|user action' "$STDERR" || true
  echo
  echo "## Claude CLI invocations"
  cat "$INVOCATIONS"
  echo
  echo "## child processes"
  cat "$PROC_LOG"
} | tee "$ARTIFACT/E2E-REPORT.md"

if [[ "$CLI_STATUS" -eq 0 ]]; then
  log "Phase 2 failed: the MCP-only fixture unexpectedly produced successful OAuth usage"
  exit 1
fi
if [[ -e "$CANARY" ]]; then
  log "Phase 2 failed: delegated Claude CLI /status touch ran"
  exit 1
fi
if [[ -e "$OPEN_CANARY" ]]; then
  log "Phase 2 failed: browser/open helper ran"
  exit 1
fi
if rg -q '/usr/bin/open|(^|/)open$|firefox|Google Chrome|Safari' "$PROC_LOG" 2>/dev/null; then
  log "Phase 2 failed: an open helper or browser was a probe child"
  exit 1
fi
if ! rg -qi 'MCP OAuth state only|mcpOAuthOnlyKeychain|MCP OAuth' "$STDERR" "$STDOUT"; then
  log "Phase 2 failed: expected MCP-only fail-closed message not found"
  exit 1
fi

log "Phase 2 passed: exact packaged CLI failed closed without delegated /status touch or browser child"

log "Phase 3: isolated packaged app runtime smoke"
APP_PROC_LOG="$ARTIFACT/app-processes.log"
APP_STDOUT="$ARTIFACT/app-stdout.log"
APP_STDERR="$ARTIFACT/app-stderr.log"
: >"$APP_PROC_LOG"
: >"$INVOCATIONS"
(
  env \
    HOME="$HOME_FIXTURE" \
    CFFIXED_USER_HOME="$HOME_FIXTURE" \
    CODEXBAR_CONFIG="$CONFIG" \
    CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 \
    CODEXBAR_CLAUDE_SECURITY_CLI_KEYCHAIN="$KEYCHAIN" \
    CODEXBAR_CLAUDE_TOUCH_CANARY="$CANARY" \
    CODEXBAR_CLAUDE_INVOCATIONS="$INVOCATIONS" \
    CODEXBAR_OPEN_TOUCH_CANARY="$OPEN_CANARY" \
    CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW=1 \
    CLAUDE_CLI_PATH="$ARTIFACT/bin/claude" \
    PATH="$ARTIFACT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$APP" >"$APP_STDOUT" 2>"$APP_STDERR"
) &
APP_PID=$!
APP_OBSERVED_CLI=0
POST_DISCOVERY_TICKS=0
for _ in $(seq 1 1000); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    log "Phase 3 failed: packaged app exited before the isolated startup smoke completed"
    wait "$APP_PID" || true
    exit 1
  fi
  {
    date -u +%H:%M:%S
    pgrep -P "$APP_PID" -l 2>/dev/null || true
  } >>"$APP_PROC_LOG"
  if rg -q '^args: --version$' "$INVOCATIONS"; then
    APP_OBSERVED_CLI=1
    POST_DISCOVERY_TICKS=$((POST_DISCOVERY_TICKS + 1))
    if [[ "$POST_DISCOVERY_TICKS" -ge 250 ]]; then
      break
    fi
  fi
  sleep 0.02
done
kill "$APP_PID"
wait "$APP_PID" 2>/dev/null || true

if [[ "$APP_OBSERVED_CLI" -ne 1 ]]; then
  log "Phase 3 failed: packaged app never exercised the isolated Claude CLI fixture"
  exit 1
fi
if [[ -e "$CANARY" ]]; then
  log "Phase 3 failed: packaged app invoked delegated Claude CLI /status touch"
  exit 1
fi
if [[ -e "$OPEN_CANARY" ]]; then
  log "Phase 3 failed: packaged app invoked browser/open helper"
  exit 1
fi
if rg -q '/usr/bin/open|(^|/)open$|firefox|Google Chrome|Safari' "$APP_PROC_LOG" 2>/dev/null; then
  log "Phase 3 failed: an open helper or browser was an app child"
  exit 1
fi
{
  echo
  echo "## packaged app runtime"
  echo "app-binary: $APP"
  echo "isolated-claude-cli-discovery-observed: yes"
  echo "post-discovery-observation-seconds: 5"
  echo "app-stayed-running: yes"
  echo "claude-status-canary: untouched"
  echo "open-touch-canary: untouched"
  echo "browser-child: none"
  echo
  echo "## packaged app Claude CLI invocations"
  cat "$INVOCATIONS"
} | tee -a "$ARTIFACT/E2E-REPORT.md"

log "Phase 3 passed: packaged app exercised CLI discovery without delegated /status touch or browser child"
log "Report: $ARTIFACT/E2E-REPORT.md"

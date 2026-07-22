#!/usr/bin/env bash
# Live verification for the Claude credential-ownership boundary.
# CodexBar must use Claude-owned interfaces and never read Claude Code's Keychain item itself.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '[verify-claude-ownership] %s\n' "$*"; }
fail() {
  log "$*"
  exit 1
}

ARTIFACT="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-claude-ownership.XXXXXX")"
APP_BUNDLE="$ROOT/CodexBar.app"
CLI="$APP_BUNDLE/Contents/Helpers/CodexBarCLI"
APP="$APP_BUNDLE/Contents/MacOS/CodexBar"
LIVE_TIMEOUT_SECONDS="${CODEXBAR_VERIFY_LIVE_TIMEOUT_SECONDS:-45}"

write_source_snapshot() {
  local output="$1"
  local path kind mode digest link_target
  : >"$output"
  while IFS= read -r -d '' path; do
    if [[ -L "$path" ]]; then
      kind="symlink"
      mode="$(/usr/bin/stat -f '%Lp' "$path")"
      link_target="$(/usr/bin/readlink "$path")"
      digest="$(printf '%s' "$link_target" | shasum -a 256 | awk '{print $1}')"
    elif [[ -f "$path" ]]; then
      kind="file"
      mode="$(/usr/bin/stat -f '%Lp' "$path")"
      digest="$(shasum -a 256 "$path" | awk '{print $1}')"
    else
      # Keep tracked deletions in the snapshot so the digest describes the exact dirty worktree.
      kind="missing"
      mode="-"
      digest="-"
    fi
    printf '%s\0%s\0%s\0%s\0' "$path" "$kind" "$mode" "$digest" >>"$output"
  done < <(git ls-files -z --cached --others --exclude-standard)
}

case "$LIVE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail "CODEXBAR_VERIFY_LIVE_TIMEOUT_SECONDS must be an integer from 5 through 300." ;;
esac
if (( LIVE_TIMEOUT_SECONDS < 5 || LIVE_TIMEOUT_SECONDS > 300 )); then
  fail "CODEXBAR_VERIFY_LIVE_TIMEOUT_SECONDS must be an integer from 5 through 300."
fi

CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  fail "Claude CLI is not installed or is not on PATH."
fi

log "Artifacts: $ARTIFACT"
log "Phase 0: package the current source as a Release bundle"
SOURCE_SNAPSHOT_BEFORE="$ARTIFACT/source-snapshot-before.bin"
SOURCE_SNAPSHOT_AFTER="$ARTIFACT/source-snapshot-after.bin"
write_source_snapshot "$SOURCE_SNAPSHOT_BEFORE"
SOURCE_SNAPSHOT_SHA256="$(shasum -a 256 "$SOURCE_SNAPSHOT_BEFORE" | awk '{print $1}')"
./Scripts/package_app.sh release 2>&1 | tee "$ARTIFACT/package-release.log"
write_source_snapshot "$SOURCE_SNAPSHOT_AFTER"
SOURCE_SNAPSHOT_AFTER_SHA256="$(shasum -a 256 "$SOURCE_SNAPSHOT_AFTER" | awk '{print $1}')"
if [[ "$SOURCE_SNAPSHOT_SHA256" != "$SOURCE_SNAPSHOT_AFTER_SHA256" ]]; then
  fail "The source worktree changed while the Release bundle was being packaged; rerun against a stable tree."
fi

for binary in "$CLI" "$APP"; do
  if [[ ! -x "$binary" ]]; then
    fail "Release packaging did not produce the required executable: $binary"
  fi
done

CLI_SHA256="$(shasum -a 256 "$CLI" | awk '{print $1}')"
APP_SHA256="$(shasum -a 256 "$APP" | awk '{print $1}')"
WORKTREE_STATE="clean"
if [[ -n "$(git status --porcelain)" ]]; then
  WORKTREE_STATE="dirty"
fi
log "Phase 0 passed"

log "Phase 1: ownership, routing, account, config, session, and prompt-safety tests"
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --no-parallel \
  --filter ClaudeCredentialOwnershipBoundaryTests \
  --filter ClaudeOAuthNoninteractiveCredentialLoadTests \
  --filter ClaudeOAuthCredentialsStoreTemporaryKeychainCacheTests \
  --filter ClaudeOAuthUpgradeCompatibilityTests \
  --filter ClaudeBaselineCharacterizationTests \
  --filter ClaudeDebugDiagnosticsTests \
  --filter ClaudeSourcePlannerTests \
  --filter ClaudeTokenAccountRoutingTests \
  --filter ClaudeActiveAccountIdentityInvalidationTests \
  --filter ClaudeConfigPathsTests \
  --filter ClaudeOAuthCredentialsProfileCacheTests \
  --filter ClaudeOAuthRefreshFailureGateTests \
  --filter ClaudeCLISessionTests \
  --filter TTYIntegrationTests \
  --filter KeychainPromptSafetyAuditTests \
  2>&1 | tee "$ARTIFACT/focused-tests.log"

LIVE_CLAUDE_KEYCHAIN_PROOF=1 \
  CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 \
  swift test --no-parallel --filter ClaudeKeychainLiveProofTests \
  2>&1 | tee "$ARTIFACT/live-owner-tests.log"
log "Phase 1 passed"

log "Phase 2: all first-party Release executables contain no known foreign-reader markers"
FIRST_PARTY_BINARIES=()
for scan_root in \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Helpers" \
  "$APP_BUNDLE/Contents/PlugIns"
do
  [[ -d "$scan_root" ]] || continue
  while IFS= read -r -d '' binary; do
    if /usr/bin/file -b "$binary" | rg -q 'Mach-O'; then
      FIRST_PARTY_BINARIES+=("$binary")
    fi
  # Packaging intentionally produces owner-only mode 0700 files under umask 077, so do not require group/other
  # execute bits. `file` is the authoritative Mach-O discriminator.
  done < <(/usr/bin/find "$scan_root" -type f -print0)
done

if (( ${#FIRST_PARTY_BINARIES[@]} == 0 )); then
  fail "Release bundle contains no first-party Mach-O executables to audit."
fi

FORBIDDEN='Claude Code-credentials|find-generic-password|/usr/bin/security'
BINARY_HASH_MANIFEST="$ARTIFACT/first-party-release-executables.sha256"
: >"$BINARY_HASH_MANIFEST"
binary_index=0
for binary in "${FIRST_PARTY_BINARIES[@]}"; do
  binary_index=$((binary_index + 1))
  binary_relative_path="${binary#"$APP_BUNDLE/"}"
  binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
  printf '%s  %s\n' "$binary_sha256" "$binary_relative_path" >>"$BINARY_HASH_MANIFEST"
  output="$ARTIFACT/release-${binary_index}-$(basename "$binary").strings.txt"
  strings "$binary" >"$output"
  if rg -n "$FORBIDDEN" "$output" >"$output.matches"; then
    fail "Release artifact still contains a known foreign-reader marker: $binary"
  fi
done
log "Phase 2 passed"

log "Phase 3: bounded owner-mediated CLI fetch plus process and unified-log audit"
VERIFIER_HELPER_SOURCE="$ARTIFACT/verifier-helper.c"
VERIFIER_HELPER="$ARTIFACT/CodexBarOwnershipVerifierHelper"
cat >"$VERIFIER_HELPER_SOURCE" <<'EOF'
#include <errno.h>
#include <os/log.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc >= 3 && strcmp(argv[1], "--group-exec") == 0) {
        if (setpgid(0, 0) != 0) {
            perror("setpgid");
            return 70;
        }
        execv(argv[2], &argv[2]);
        perror("execv");
        return 71;
    }
    if (argc == 3 && strcmp(argv[1], "--log-canary") == 0) {
        os_log_t logger = os_log_create("com.steipete.codexbar.verifier", "visibility");
        os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, "%{public}s", argv[2]);
        usleep(200000);
        return 0;
    }
    fprintf(stderr, "usage: verifier-helper --group-exec <program> [args...] | --log-canary <marker>\n");
    return 64;
}
EOF
/usr/bin/xcrun clang -O2 "$VERIFIER_HELPER_SOURCE" -o "$VERIFIER_HELPER"

START_LOCAL="$(date '+%Y-%m-%d %H:%M:%S')"
STDOUT="$ARTIFACT/live-cli-stdout.json"
STDERR="$ARTIFACT/live-cli-stderr.log"
ISOLATED_CONFIG="$ARTIFACT/no-user-config.json"
PROCESS_SNAPSHOTS="$ARTIFACT/live-cli-process-tree.log"
SECURITY_DESCENDANTS="$ARTIFACT/security-descendants.log"
UNOWNED_SECURITY_DESCENDANTS="$ARTIFACT/unowned-security-descendants.log"
: >"$PROCESS_SNAPSHOTS"

snapshot_cli_process_tree() {
  local queue=("$CLI_PID")
  local queue_index=0
  local parent_pid child_pid process_record

  while (( queue_index < ${#queue[@]} )); do
    parent_pid="${queue[$queue_index]}"
    queue_index=$((queue_index + 1))
    while IFS= read -r child_pid; do
      [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
      process_record="$(/bin/ps -p "$child_pid" -o pid= -o ppid= -o comm= 2>/dev/null || true)"
      if [[ -n "$process_record" ]]; then
        printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$process_record" \
          >>"$PROCESS_SNAPSHOTS"
        queue+=("$child_pid")
      fi
    done < <(/usr/bin/pgrep -P "$parent_pid" 2>/dev/null || true)
  done
  return 0
}

set +e
"$VERIFIER_HELPER" --group-exec /usr/bin/env \
  -u ANTHROPIC_ADMIN_KEY \
  -u ANTHROPIC_ADMIN_API_KEY \
  -u CODEXBAR_CLAUDE_OAUTH_TOKEN \
  -u CODEXBAR_CLAUDE_OAUTH_SCOPES \
  -u CODEXBAR_CLAUDE_OAUTH_CLIENT_ID \
  -u CODEXBAR_CLAUDE_SECURITY_CLI_KEYCHAIN \
  -u CODEXBAR_DISABLE_KEYCHAIN_ACCESS \
  -u CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS \
  CODEXBAR_CONFIG="$ISOLATED_CONFIG" \
  CLAUDE_CLI_PATH="$CLAUDE_BIN" \
  DISABLE_AUTOUPDATER=1 \
  "$CLI" usage --provider claude --source cli --format json --json-only \
  >"$STDOUT" 2>"$STDERR" &
CLI_PID=$!
set -e

CLI_TIMED_OUT=0
CLI_DEADLINE_EPOCH=$(( $(date +%s) + LIVE_TIMEOUT_SECONDS ))
while true; do
  CLI_PROCESS_STATE="$(
    /bin/ps -p "$CLI_PID" -o stat= 2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ -z "$CLI_PROCESS_STATE" || "$CLI_PROCESS_STATE" == Z* ]]; then
    break
  fi
  snapshot_cli_process_tree
  if (( $(date +%s) >= CLI_DEADLINE_EPOCH )); then
    CLI_TIMED_OUT=1
    /bin/kill -TERM -- "-$CLI_PID" 2>/dev/null || true
    for _ in {1..20}; do
      CLI_PROCESS_STATE="$(
        /bin/ps -p "$CLI_PID" -o stat= 2>/dev/null | tr -d '[:space:]' || true
      )"
      [[ -z "$CLI_PROCESS_STATE" || "$CLI_PROCESS_STATE" == Z* ]] && break
      sleep 0.1
    done
    /bin/kill -KILL -- "-$CLI_PID" 2>/dev/null || true
    break
  fi
  sleep 0.02
done
snapshot_cli_process_tree

set +e
wait "$CLI_PID"
CLI_STATUS=$?
set -e
if [[ "$CLI_TIMED_OUT" -eq 1 ]]; then
  CLI_STATUS=124
fi

/usr/bin/awk '
  {
    normalized_command = $4
    sub(/^\(/, "", normalized_command)
    sub(/\)$/, "", normalized_command)
    if (normalized_command ~ /(^|\/)security$/ && !seen[$2]++) print $2, $3, $4
  }
' "$PROCESS_SNAPSHOTS" | /usr/bin/sort -n >"$SECURITY_DESCENDANTS"
SECURITY_DESCENDANT_COUNT="$(wc -l <"$SECURITY_DESCENDANTS" | tr -d ' ')"

# Claude can legitimately start its own MCP subprocesses; those owner-controlled tools may in turn use the macOS
# `security` CLI (for example, GitHub tooling). Reject only a security descendant whose ancestry reaches CodexBarCLI
# without first crossing the installed `claude` owner boundary. A direct or shell-wrapped CodexBar reader therefore
# fails, while Claude-owned descendants remain visible in the retained evidence without being misattributed.
/usr/bin/awk -v root_pid="$CLI_PID" '
  {
    pid = $2
    normalized_command = $4
    sub(/^\(/, "", normalized_command)
    sub(/\)$/, "", normalized_command)
    if (!(pid in parent) || command[pid] == "<defunct>") {
      parent[pid] = $3
      command[pid] = normalized_command
    }
    if (normalized_command ~ /(^|\/)security$/) security[pid] = 1
  }
  END {
    for (pid in security) {
      current = pid
      crossed_owner = 0
      for (depth = 0; depth < 128; depth++) {
        ancestor = parent[current]
        if (ancestor == root_pid) break
        if (!ancestor || ancestor == current) break
        if (command[ancestor] ~ /(^|\/)claude$/) crossed_owner = 1
        current = ancestor
      }
      if (!crossed_owner) print pid, parent[pid], command[pid]
    }
  }
' "$PROCESS_SNAPSHOTS" | /usr/bin/sort -n >"$UNOWNED_SECURITY_DESCENDANTS"
UNOWNED_SECURITY_DESCENDANT_COUNT="$(wc -l <"$UNOWNED_SECURITY_DESCENDANTS" | tr -d ' ')"
OWNER_SECURITY_DESCENDANT_COUNT=$((SECURITY_DESCENDANT_COUNT - UNOWNED_SECURITY_DESCENDANT_COUNT))

# This canary emits only a public OSLog marker. It performs no Keychain query and proves that the bounded
# `log show` window is visible before a zero-event result is accepted.
LOG_CANARY="codexbar-ownership-log-canary-$(/usr/bin/uuidgen)"
"$VERIFIER_HELPER" --log-canary "$LOG_CANARY" &
LOG_CANARY_PID=$!
wait "$LOG_CANARY_PID"

sleep 2
END_LOCAL="$(date '+%Y-%m-%d %H:%M:%S')"
UNIFIED_LOG="$ARTIFACT/unified.log"
ATTRIBUTED_EVENTS="$ARTIFACT/codexbar-attributed-prompt-authorization-events.log"
PREDICATE="((eventMessage CONTAINS[c] \"$LOG_CANARY\") OR ((((processID == $CLI_PID) OR (process == \"security\") OR (process == \"securityd\") OR (process == \"coreauthd\") OR (process == \"authd\") OR (process == \"SecurityAgent\") OR (process == \"authorizationhost\") OR (process == \"CoreServicesUIAgent\") OR (process == \"UserNotificationCenter\")) AND ((eventMessage CONTAINS[c] \"SecItem\") OR (eventMessage CONTAINS[c] \"QueryKeychainUse\") OR (eventMessage CONTAINS[c] \"LAContext\") OR (eventMessage CONTAINS[c] \"ACL\") OR (eventMessage CONTAINS[c] \"Claude Code-credentials\") OR (eventMessage CONTAINS[c] \"keychain prompt\") OR (eventMessage CONTAINS[c] \"authorization\")))))"

/usr/bin/log show \
  --start "$START_LOCAL" \
  --end "$END_LOCAL" \
  --style compact \
  --info \
  --debug \
  --predicate "$PREDICATE" \
  >"$UNIFIED_LOG"

if ! rg -Fq "$LOG_CANARY" "$UNIFIED_LOG"; then
  fail "Unified-log visibility canary was not observable; zero events would not be meaningful."
fi

ATTRIBUTION_PATTERN="CodexBarCLI|\\($CLI_PID\\)|\\[$CLI_PID:|pid[=: ]+$CLI_PID"
while read -r security_pid _; do
  [[ "$security_pid" =~ ^[0-9]+$ ]] || continue
  ATTRIBUTION_PATTERN+="|\\($security_pid\\)|\\[$security_pid:|pid[=: ]+$security_pid"
done <"$UNOWNED_SECURITY_DESCENDANTS"
rg -i "$ATTRIBUTION_PATTERN" "$UNIFIED_LOG" >"$ATTRIBUTED_EVENTS" || true
ATTRIBUTED_EVENT_COUNT="$(wc -l <"$ATTRIBUTED_EVENTS" | tr -d ' ')"

LIVE_PROVIDER="$(/usr/bin/plutil -extract 0.provider raw -expect string "$STDOUT" 2>/dev/null || true)"
LIVE_SOURCE="$(/usr/bin/plutil -extract 0.source raw -expect string "$STDOUT" 2>/dev/null || true)"
LIVE_USAGE_TYPE="$(/usr/bin/plutil -type 0.usage "$STDOUT" 2>/dev/null || true)"
CLAUDE_OWNER_AUTHENTICATED="no"
if [[ "$CLI_STATUS" -eq 0 && "$LIVE_PROVIDER" == "claude" && "$LIVE_USAGE_TYPE" == "dictionary" ]]; then
  CLAUDE_OWNER_AUTHENTICATED="yes"
fi

{
  echo "# Claude credential-ownership live verification"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "candidate: $(git rev-parse HEAD)"
  echo "candidate-worktree: $WORKTREE_STATE"
  echo "source-snapshot-sha256: $SOURCE_SNAPSHOT_SHA256"
  echo "release-built-by-verifier: yes"
  echo "packaged-cli: $CLI"
  echo "packaged-cli-sha256: $CLI_SHA256"
  echo "packaged-app: $APP"
  echo "packaged-app-sha256: $APP_SHA256"
  echo "first-party-release-executables-audited: ${#FIRST_PARTY_BINARIES[@]}"
  report_binary_index=0
  while read -r binary_sha256 binary_relative_path; do
    report_binary_index=$((report_binary_index + 1))
    echo "release-executable-${report_binary_index}-path: $binary_relative_path"
    echo "release-executable-${report_binary_index}-sha256: $binary_sha256"
  done <"$BINARY_HASH_MANIFEST"
  echo "claude-owner-authenticated: $CLAUDE_OWNER_AUTHENTICATED"
  echo "cli-timeout-seconds: $LIVE_TIMEOUT_SECONDS"
  echo "cli-timed-out: $CLI_TIMED_OUT"
  echo "cli-exit: $CLI_STATUS"
  echo "live-provider: $LIVE_PROVIDER"
  echo "live-source: $LIVE_SOURCE"
  echo "live-usage-type: $LIVE_USAGE_TYPE"
  echo "security-descendants: $SECURITY_DESCENDANT_COUNT"
  echo "claude-owner-security-descendants: $OWNER_SECURITY_DESCENDANT_COUNT"
  echo "unowned-security-descendants: $UNOWNED_SECURITY_DESCENDANT_COUNT"
  echo "unified-log-visibility-canary: observed"
  echo "attributed-prompt-authorization-events: $ATTRIBUTED_EVENT_COUNT"
  echo "release-known-foreign-reader-markers: 0"
} | tee "$ARTIFACT/REPORT.md"

if [[ "$CLI_TIMED_OUT" -eq 1 ]]; then
  fail "Live Claude CLI-source fetch exceeded ${LIVE_TIMEOUT_SECONDS}s; its process group was terminated."
fi
if [[ "$CLI_STATUS" -ne 0 ]]; then
  fail "Live Claude CLI-source fetch failed (exit $CLI_STATUS); see $STDERR"
fi
if [[ "$LIVE_PROVIDER" != "claude" || "$LIVE_SOURCE" != "claude" || "$LIVE_USAGE_TYPE" != "dictionary" ]]; then
  fail "Live result was not a successful Claude CLI usage payload; see $STDOUT"
fi
if [[ "$UNOWNED_SECURITY_DESCENDANT_COUNT" -ne 0 ]]; then
  fail "CodexBarCLI launched /usr/bin/security outside the Claude owner subtree; see $UNOWNED_SECURITY_DESCENDANTS"
fi
if [[ "$ATTRIBUTED_EVENT_COUNT" -ne 0 ]]; then
  fail "Live fetch emitted attributable prompt/authorization events; see $ATTRIBUTED_EVENTS"
fi

log "Phase 3 passed: owner path succeeded with no direct security child or attributable authorization event"
log "Report: $ARTIFACT/REPORT.md"

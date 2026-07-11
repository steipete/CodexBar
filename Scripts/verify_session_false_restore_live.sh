#!/usr/bin/env bash
# Live verification for Codex session false-restore OS notification bug.
# Fetches real Codex usage, redacts sensitive fields, replays transient-zero
# scenarios through both celebration (fixed) and session notification (buggy) paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '[verify-session-false-restore] %s\n' "$*"; }

ARTIFACT="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-session-false-restore.XXXXXX")"
chmod 700 "$ARTIFACT"
LIVE_RAW="$ARTIFACT/live-usage.raw.json"
LIVE_REDACTED="$ARTIFACT/live-usage.redacted.json"
UNIT_LOG="$ARTIFACT/unit-repro.log"
LIVE_LOG="$ARTIFACT/live-proof.log"
DOC_PROOF="$ROOT/docs/verify-session-false-restore-proof.md"
CLI="${CODEXBAR_CLI:-/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI}"
SKIP_PACKAGE="${CODEXBAR_SKIP_PACKAGE:-1}"

if [[ ! -x "$CLI" ]]; then
  log "Missing CodexBarCLI at $CLI"
  log "Install CodexBar or set CODEXBAR_CLI, then retry."
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  log "Missing node (required for redaction)."
  exit 2
fi

log "Artifacts: $ARTIFACT"
log "Source commit: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ "$SKIP_PACKAGE" != "1" ]]; then
  log "Phase 0: package release build from this branch"
  env CODEXBAR_SIGNING="${CODEXBAR_SIGNING:-adhoc}" "$ROOT/Scripts/package_app.sh" release \
    2>&1 | tee "$ARTIFACT/package.log"
  CLI="$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI"
fi

log "Phase 1: synthetic unit repro"
{
  swift test --filter CodexSessionQuotaFalseRestoreReproTests
} 2>&1 | tee "$UNIT_LOG"

log "Phase 2: contract test must pass after fix"
if ! swift test --filter 'contract session notification must not post restored on codex transient zero' \
  2>&1 | tee "$ARTIFACT/contract-pass.log"; then
  log "Contract test failed; session false-restore guard is not fixed"
  exit 1
fi
log "Phase 2 passed: contract test passed"

log "Phase 3: live Codex usage fetch via CodexBarCLI"
if ! "$CLI" usage --provider codex --format json --json-only >"$LIVE_RAW" 2>"$ARTIFACT/live-usage.stderr"; then
  log "Live Codex fetch failed. stderr:"
  sed 's/.*/[verify-session-false-restore] &/' "$ARTIFACT/live-usage.stderr" >&2
  exit 1
fi

node - "$LIVE_RAW" "$LIVE_REDACTED" <<'NODE'
const fs = require("fs");
const [inputPath, outputPath] = process.argv.slice(2);
const redact = (value) => String(value ?? "")
  .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<redacted-email>")
  .replace(/sk-[A-Za-z0-9_-]{12,}/g, "sk-<redacted>")
  .replace(/eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+/g, "<redacted-jwt>");
const raw = fs.readFileSync(inputPath, "utf8");
const payload = JSON.parse(raw);
const redacted = JSON.parse(redact(JSON.stringify(payload)));
fs.writeFileSync(outputPath, `${JSON.stringify(redacted, null, 2)}\n`);
NODE

log "Phase 4: live fixture replay through session notification repro harness"
export CODEXBAR_VERIFY_SESSION_FALSE_RESTORE_LIVE_FIXTURE="$LIVE_REDACTED"
if ! swift test --filter 'live proof session notification false restores with real codex session resetsAt' \
  2>&1 | tee "$LIVE_LOG"; then
  log "Live proof harness failed"
  exit 1
fi

for marker in \
  PROOF_LIVE_FETCH \
  PROOF_CELEBRATION_SUPPRESSED_TRANSIENT_ZERO \
  PROOF_SESSION_NOTIFICATION_SUPPRESSED_TRANSIENT_ZERO \
  PROOF_API_FLICKER_SUPPRESSED
do
  if ! grep -q "$marker" "$LIVE_LOG"; then
    log "Missing proof marker: $marker"
    exit 1
  fi
done

log "Phase 5: write docs/verify-session-false-restore-proof.md"
{
  printf '%s\n' \
    '# Verification: Codex session false-restore OS notification bug' \
    '' \
    'Reproduces and verifies the fix for Codex session OS notifications posting `.restored`' \
    'when OAuth briefly returns `usedPercent = 0` while `resetsAt` is unchanged.' \
    '' \
    '## Scope' \
    '' \
    '1. Synthetic unit repro with issue #2054 fixture shape.' \
    '2. Contract test that passes once the bug is fixed.' \
    '3. Real Codex usage fetch through CodexBarCLI (redacted).' \
    '4. Replay of live `sessionResetsAt` through both celebration and session notification paths.' \
    '' \
    '## Command' \
    '' \
    '```bash' \
    './Scripts/verify_session_false_restore_live.sh' \
    '```' \
    '' \
    "## Redacted live proof ($(date -u +%Y-%m-%dT%H:%MZ))" \
    '' \
    '```text'
  grep '\[verify-session-false-restore\]' "$LIVE_LOG" || true
  printf '%s\n' '```' '' '## Redacted live fetch summary' '' '```json'
  node - "$LIVE_REDACTED" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const row = Array.isArray(payload) ? payload[0] : payload;
const usage = row?.usage ?? row;
const session = usage?.primary ?? null;
const weekly = usage?.secondary ?? null;
console.log(JSON.stringify({
  provider: row?.provider ?? "codex",
  source: row?.source ?? "live-cli",
  account: row?.account ?? "<redacted-email>",
  sessionUsedPercent: session?.usedPercent ?? null,
  sessionResetsAt: session?.resetsAt ?? null,
  weeklyUsedPercent: weekly?.usedPercent ?? null,
  weeklyResetsAt: weekly?.resetsAt ?? null,
  loginMethod: usage?.identity?.loginMethod ?? usage?.loginMethod ?? null,
}, null, 2));
NODE
  printf '%s\n' '```' '' '## Unit repro summary' '' '```text'
  grep -E '✔ Test|✘ Test|transition (depleted|restored)' "$UNIT_LOG" "$ARTIFACT/contract-fail.log" 2>/dev/null || true
  printf '%s\n' '```'
} >"$DOC_PROOF"

log "Phase 5 passed: wrote $DOC_PROOF"
log "Live verification complete: session false-restore guard verified with real Codex sessionResetsAt"

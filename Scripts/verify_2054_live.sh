#!/usr/bin/env bash
# Live verification for CodexBar #2054 / PR #2056.
# Fetches real Codex usage, redacts sensitive fields, and replays weekly-reset
# detector scenarios through the fixed UsageStore code path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '[verify-2054] %s\n' "$*"; }

ARTIFACT="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-2054-verify.XXXXXX")"
chmod 700 "$ARTIFACT"
LIVE_RAW="$ARTIFACT/live-usage.raw.json"
LIVE_REDACTED="$ARTIFACT/live-usage.redacted.json"
PROOF_LOG="$ARTIFACT/live-proof.log"
DOC_PROOF="$ROOT/docs/verify-2054-proof.md"
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

if [[ "$SKIP_PACKAGE" != "1" ]]; then
  log "Phase 0: package release build from this branch"
  env CODEXBAR_SIGNING="${CODEXBAR_SIGNING:-adhoc}" "$ROOT/Scripts/package_app.sh" release \
    2>&1 | tee "$ARTIFACT/package.log"
  CLI="$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI"
fi

log "Phase 1: live Codex usage fetch via CodexBarCLI"
if ! "$CLI" usage --provider codex --format json --json-only >"$LIVE_RAW" 2>"$ARTIFACT/live-usage.stderr"; then
  log "Live Codex fetch failed. stderr:"
  sed 's/.*/[verify-2054] &/' "$ARTIFACT/live-usage.stderr" >&2
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

log "Phase 2: focused regression tests"
{
  swift test --filter UsageStorePlanUtilizationIssue2054ReproTests
  swift test --filter 'codex weekly celebration ignores transient zero when reset boundary is unchanged'
  swift test --filter 'codex weekly celebration ignores missing reset boundaries'
} 2>&1 | tee "$ARTIFACT/regression-tests.log"

log "Phase 3: live fixture replay through fixed detector"
export CODEXBAR_VERIFY_2054_LIVE_FIXTURE="$LIVE_REDACTED"
if ! swift test --filter 'issue 2054 live behavior proof from fixture' 2>&1 | tee "$PROOF_LOG"; then
  log "Live proof harness failed"
  exit 1
fi

for marker in \
  PROOF_LIVE_FETCH \
  PROOF_SUPPRESSED_TRANSIENT_ZERO \
  PROOF_SUPPRESSED_NIL_BOUNDARY \
  PROOF_CELEBRATED_REAL_RESET
do
  if ! grep -q "$marker" "$PROOF_LOG"; then
    log "Missing proof marker: $marker"
    exit 1
  fi
done

log "Phase 4: write docs/verify-2054-proof.md"
{
  printf '%s\n' \
    '# Verification: Codex weekly reset confetti boundary guard' \
    '' \
    'Verification artifact for https://github.com/steipete/CodexBar/pull/2056, related to https://github.com/steipete/CodexBar/issues/2054.' \
    '' \
    '## Scope' \
    '' \
    'Demonstrate after-fix Codex weekly confetti behavior with:' \
    '' \
    '1. A real Codex usage fetch through CodexBarCLI (redacted).' \
    '2. Replay of the live weekly `resetsAt` through the fixed weekly reset detector.' \
    '3. Suppression for unchanged and missing weekly boundaries.' \
    '4. Exactly one celebration after a genuine weekly boundary advance.' \
    '' \
    '## Command' \
    '' \
    '```bash' \
    './Scripts/verify_2054_live.sh' \
    '```' \
    '' \
    'Optional: build the packaged app from this branch before fetching:' \
    '' \
    '```bash' \
    'CODEXBAR_SKIP_PACKAGE=0 ./Scripts/verify_2054_live.sh' \
    '```' \
    '' \
    "## Redacted live proof ($(date -u +%Y-%m-%dT%H:%MZ))" \
    '' \
    '```text'
  grep '\[verify-2054-proof\]' "$PROOF_LOG" || true
  printf '%s\n' '```' '' '## Redacted live fetch summary' '' '```json'
  node - "$LIVE_REDACTED" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const row = Array.isArray(payload) ? payload[0] : payload;
const usage = row?.usage ?? row;
const weekly = usage?.secondary ?? null;
const session = usage?.primary ?? null;
console.log(JSON.stringify({
  provider: row?.provider ?? "codex",
  source: row?.source ?? "live-cli",
  account: row?.account ?? "<redacted-email>",
  weeklyUsedPercent: weekly?.usedPercent ?? null,
  weeklyResetsAt: weekly?.resetsAt ?? null,
  sessionUsedPercent: session?.usedPercent ?? null,
  sessionResetsAt: session?.resetsAt ?? null,
  loginMethod: usage?.identity?.loginMethod ?? usage?.loginMethod ?? null,
}, null, 2));
NODE
  printf '%s\n' '```'
} >"$DOC_PROOF"

log "Phase 4 passed: wrote $DOC_PROOF"
log "Live proof complete"

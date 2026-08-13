#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PROOF_ROOT=$(mktemp -d /private/tmp/codexbar-lifetime-proof.XXXXXX)
chmod 700 "$PROOF_ROOT"
mkdir -p "$PROOF_ROOT/home" "$PROOF_ROOT/tmp" "$PROOF_ROOT/codex-home/sessions/2026/01/30"
mkdir -p "$PROOF_ROOT/codex-home/sessions/2026/03/01"

RUN_ID=$(uuidgen)
cat > "$PROOF_ROOT/.codexbar-lifetime-proof.json" <<JSON
{"schemaVersion":1,"runID":"$RUN_ID"}
JSON

write_session() {
  local target="$1"
  local timestamp="$2"
  local tokens="$3"
  cat > "$target" <<JSONL
{"type":"session_meta","timestamp":"$timestamp","payload":{"id":"lifetime-$tokens","cwd":"/private/tmp/codexbar-lifetime-proof-project"}}
{"type":"turn_context","timestamp":"$timestamp","payload":{"model":"openai/gpt-5.4"}}
{"type":"event_msg","timestamp":"$timestamp","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":$tokens,"cached_input_tokens":0,"output_tokens":0},"model":"openai/gpt-5.4"}}}
JSONL
}

write_session "$PROOF_ROOT/codex-home/sessions/2026/01/30/record.jsonl" "2026-01-30T12:00:00Z" 100000
write_session "$PROOF_ROOT/codex-home/sessions/2026/03/01/reload.jsonl" "2026-03-01T12:00:00Z" 150000

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  CODEXBAR_SIGNING=adhoc \
  ./Scripts/package_app.sh debug

APP_BINARY="$ROOT/CodexBar.app/Contents/MacOS/CodexBar"
run_phase() {
  local phase="$1"
  env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$PROOF_ROOT/home" \
    CFFIXED_USER_HOME="$PROOF_ROOT/home" \
    TMPDIR="$PROOF_ROOT/tmp" \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    CODEXBAR_LIFETIME_RUNTIME_PROOF_ROOT="$PROOF_ROOT" \
    CODEXBAR_LIFETIME_RUNTIME_PROOF_PHASE="$phase" \
    "$APP_BINARY"
}

assert_ledger_permissions() {
  local permissions
  permissions=$(/usr/bin/stat -f '%Lp' "$PROOF_ROOT/spend-history.json")
  if [[ "$permissions" != "600" ]]; then
    echo "ERROR: proof ledger permissions are $permissions, expected 600" >&2
    exit 1
  fi
}

assert_manifest_permissions() {
  local manifest="$1"
  local permissions
  local schema_version
  schema_version=$(/usr/bin/plutil -extract schemaVersion raw -o - "$manifest")
  if [[ "$schema_version" != "2" ]]; then
    echo "ERROR: proof manifest schemaVersion is $schema_version, expected 2" >&2
    exit 1
  fi
  permissions=$(/usr/bin/plutil -extract ledgerPermissions raw -o - "$manifest")
  if [[ "$permissions" != "0600" ]]; then
    echo "ERROR: proof manifest ledgerPermissions is $permissions, expected 0600" >&2
    exit 1
  fi
}

run_phase record
assert_ledger_permissions
run_phase reload
assert_ledger_permissions

test -s "$PROOF_ROOT/output/record-manifest.json"
test -s "$PROOF_ROOT/output/reload-manifest.json"
test -s "$PROOF_ROOT/output/all-time-dashboard.png"
test -s "$PROOF_ROOT/output/all-time-share-stats.png"
test "$(find "$PROOF_ROOT/output" -name '*.png' -type f | wc -l | tr -d ' ')" = 2
assert_manifest_permissions "$PROOF_ROOT/output/record-manifest.json"
assert_manifest_permissions "$PROOF_ROOT/output/reload-manifest.json"

if rg -i '@|/Users/|/home/|akshay|example\.com' "$PROOF_ROOT/output"/*.json; then
  echo "ERROR: proof manifest privacy check failed" >&2
  exit 1
fi

echo "Packaged lifetime proof passed. Artifacts retained at: $PROOF_ROOT/output"

#!/usr/bin/env bash
set -euo pipefail

# Run the #4672 reproducer: one non-empty Codex session file must not crash `cost --provider codex`.
bin="${1:?Usage: check-linux-cli-codex-cost-smoke.sh <codexbar-cli>}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

codex_home="$work_dir/codex"
fake_home="$work_dir/home"
# Local-time partition, like the CLI day keys, so the file stays inside the rolling 30-day scan window.
session_dir="$codex_home/sessions/$(date +%Y/%m/%d)"
mkdir -p "$session_dir" "$fake_home"
printf '{}\n' > "$session_dir/rollout-test.jsonl"

status=0
env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
  CODEXBAR_CONFIG="$work_dir/config.json" CODEX_HOME="$codex_home" HOME="$fake_home" \
  "$bin" cost --provider codex --json > "$work_dir/stdout.json" 2> "$work_dir/stderr.txt" || status=$?
cat "$work_dir/stderr.txt" >&2
if [[ "$status" -ne 0 ]]; then
  echo "error: CodexBarCLI cost --provider codex exited with $status (139 is SIGSEGV, see #4672)" >&2
  exit 1
fi
if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$work_dir/stdout.json"; then
  echo 'error: CodexBarCLI cost --provider codex did not print valid JSON' >&2
  cat "$work_dir/stdout.json" >&2
  exit 1
fi
echo 'Codex cost smoke test passed.'

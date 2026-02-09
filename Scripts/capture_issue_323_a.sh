#!/usr/bin/env bash
set -euo pipefail

# Captures observability for issue #323(A): Factory browser session invalidation after CodexBar usage fetch.
#
# This script intentionally does NOT print or persist any cookie/token values.
#
# Output bundle:
#   /tmp/codexbar-issue-323A-<timestamp>/
#     context.txt
#     config.json
#     oslog.txt
#     cli-stderr.txt
#     usage.json
#     CodexBar.log (if present)

ts="$(date +%Y%m%d-%H%M%S)"
out="/tmp/codexbar-issue-323A-$ts"
mkdir -p "$out"

echo "Writing bundle to: $out"

{
  echo "timestamp: $ts"
  echo "pwd: $(pwd)"
  echo "macOS: $(sw_vers 2>/dev/null || true)"
  echo "uname: $(uname -a 2>/dev/null || true)"
  echo "swift: $(swift --version 2>/dev/null || true)"
  echo "git: $(git rev-parse --short HEAD 2>/dev/null || true) ($(git branch --show-current 2>/dev/null || true))"
} >"$out/context.txt"

# Enable file logging + verbose level for the app (if it is running). Safe to set even if not running.
defaults write com.steipete.codexbar debugFileLoggingEnabled -bool YES || true
defaults write com.steipete.codexbar debugLogLevel -string verbose || true

# Bound how long we wait for the probe (e.g. if a browser/keychain prompt is blocking).
timeout_seconds="${CODEXBAR_CAPTURE_TIMEOUT_SECONDS:-90}"

# If enabled, intentionally tries to reproduce #323(A) by exercising risky Factory auth flows.
# This can log you out in Chrome.
#
# Modes:
# 0: normal single run
# 1: force browser-cookie auth and include token-like cookies (very aggressive)
# 2: run normal auth flow, but keep going after first success and also try unsafe cookie auth (closer to the suspected bug)
repro_mode="${CODEXBAR_FACTORY_REPRO_MODE:-0}"
repro_attempts="${CODEXBAR_FACTORY_REPRO_ATTEMPTS:-5}"

# Minimal CLI config to force a Factory fetch without touching the user's ~/.codexbar/config.json.
cat >"$out/config.json" <<'JSON'
{
  "version": 1,
  "providers": [
    {
      "id": "factory",
      "enabled": true,
      "source": "auto",
      "cookieSource": "auto"
    }
  ]
}
JSON

# Start OSLog capture for CodexBar.
log stream --style syslog --level debug --predicate 'subsystem == "com.steipete.codexbar"' >"$out/oslog.txt" 2>/dev/null &
log_pid="$!"

cli_cmd=()
# Prefer the bundled CLI (it matches the currently packaged app build), else fall back to `swift run`.
bundled_cli="./CodexBar.app/Contents/Helpers/CodexBarCLI"
if [[ -x "$bundled_cli" ]]; then
  cli_cmd+=("$bundled_cli")
else
  cli_cmd+=(swift run CodexBarCLI)
fi

set +e
cli_exit=0

if [[ "$repro_mode" == "1" ]]; then
  {
    echo "REPRO MODE enabled (may log you out)"
    echo "attempts: $repro_attempts"
    echo "mode: 1 (force cookie auth)"
  } >>"$out/context.txt"

  # Force risky path.
  export CODEXBAR_FACTORY_FORCE_BROWSER_COOKIE_AUTH=1
  export CODEXBAR_FACTORY_UNSAFE_COOKIE_AUTH=1
  export CODEXBAR_FACTORY_CHROME_ONLY=1

  for i in $(seq 1 "$repro_attempts"); do
    CODEXBAR_CONFIG_PATH="$out/config.json" \
      perl -e '$SIG{ALRM}=sub{exit 124}; alarm $ARGV[0]; exec @ARGV[1..$#ARGV]' "$timeout_seconds" \
      "${cli_cmd[@]}" usage \
      --provider factory \
      --source auto \
      --format json \
      --pretty \
      --no-color \
      --verbose \
      --log-level trace \
      >"$out/usage-$i.json" 2>>"$out/cli-stderr.txt"
    code="$?"
    if [[ "$code" != "0" ]]; then
      cli_exit="$code"
      break
    fi
    sleep 1
  done
elif [[ "$repro_mode" == "2" ]]; then
  {
    echo "REPRO MODE enabled (may log you out)"
    echo "attempts: $repro_attempts"
    echo "mode: 2 (keep going after success + unsafe cookie auth)"
  } >>"$out/context.txt"

  export CODEXBAR_FACTORY_DEBUG_KEEP_GOING_AFTER_SUCCESS=1
  export CODEXBAR_FACTORY_UNSAFE_COOKIE_AUTH=1
  export CODEXBAR_FACTORY_CHROME_ONLY=1

  for i in $(seq 1 "$repro_attempts"); do
    CODEXBAR_CONFIG_PATH="$out/config.json" \
      perl -e '$SIG{ALRM}=sub{exit 124}; alarm $ARGV[0]; exec @ARGV[1..$#ARGV]' "$timeout_seconds" \
      "${cli_cmd[@]}" usage \
      --provider factory \
      --source auto \
      --format json \
      --pretty \
      --no-color \
      --verbose \
      --log-level trace \
      >"$out/usage-$i.json" 2>>"$out/cli-stderr.txt"
    code="$?"
    if [[ "$code" != "0" ]]; then
      cli_exit="$code"
      break
    fi
    sleep 1
  done
else
  CODEXBAR_CONFIG_PATH="$out/config.json" \
    perl -e '$SIG{ALRM}=sub{exit 124}; alarm $ARGV[0]; exec @ARGV[1..$#ARGV]' "$timeout_seconds" \
    "${cli_cmd[@]}" usage \
    --provider factory \
    --source auto \
    --format json \
    --pretty \
    --no-color \
    --verbose \
    --log-level trace \
    >"$out/usage.json" 2>"$out/cli-stderr.txt"
  cli_exit="$?"
fi
set -e

# Stop log stream (best-effort).
kill "$log_pid" 2>/dev/null || true
wait "$log_pid" 2>/dev/null || true

# Snapshot the file log (if enabled and present).
file_log="$HOME/Library/Logs/CodexBar/CodexBar.log"
if [[ -f "$file_log" ]]; then
  cp "$file_log" "$out/CodexBar.log" || true
fi

echo "CLI exit: $cli_exit" >>"$out/context.txt"
echo "Done. Bundle: $out"

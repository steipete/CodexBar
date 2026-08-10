#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/date" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${MOCK_STATE_DIR}/date-count"
count=0
if [[ -f "$counter_file" ]]; then
  read -r count < "$counter_file"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
printf '%s\n' $((1000 + count * 2))
MOCK

cat > "$mock_bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${MOCK_STATE_DIR}/sleeps"
MOCK

cat > "$mock_bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "ls-remote" ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
  exit 0
fi
echo "unexpected git invocation: $*" >&2
exit 2
MOCK

cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
headers_file=""
body_file=""
url=""
while (($# > 0)); do
  case "$1" in
    --dump-header)
      headers_file="$2"
      shift 2
      ;;
    --output|-o)
      body_file="$2"
      shift 2
      ;;
    --write-out|--header|--connect-timeout|--max-time)
      shift 2
      ;;
    --silent|--show-error|--location|-fsSL)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

write_api_response() {
  local code="$1"
  local body="$2"
  local remaining="${3:-4999}"
  local reset="${4:-2000}"
  printf 'HTTP/2 %s\r\nx-ratelimit-remaining: %s\r\nx-ratelimit-reset: %s\r\n\r\n' \
    "$code" "$remaining" "$reset" > "$headers_file"
  printf '%s\n' "$body" > "$body_file"
  printf '%s' "$code"
}

if [[ "$url" == *'/actions/workflows/update-formula.yml/runs?'* ]]; then
  count_file="${MOCK_STATE_DIR}/list-count"
  count=0
  if [[ -f "$count_file" ]]; then
    read -r count < "$count_file"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"

  if [[ "$MOCK_SCENARIO" == "rate-limit" && "$count" == "1" ]]; then
    write_api_response 403 '{"message":"API rate limit exceeded"}' 0 1020
  elif [[ "$MOCK_SCENARIO" == "missing" ]]; then
    write_api_response 200 '{"workflow_runs":[]}'
  else
    write_api_response 200 \
      '{"workflow_runs":[{"id":999,"display_title":"Update codexbar for v0.49.0 (prefix-codexbar-v0.49.0-31322422801-suffix)"},{"id":222,"display_title":"Update codexbar for v0.49.0 (codexbar-v0.49.0-31322422801)"}]}'
  fi
elif [[ "$url" == *'/actions/runs/222' ]]; then
  if [[ "$MOCK_SCENARIO" == "failure" ]]; then
    write_api_response 200 \
      '{"id":222,"display_title":"Update codexbar for v0.49.0 (codexbar-v0.49.0-31322422801)","status":"completed","conclusion":"failure"}'
  else
    write_api_response 200 \
      '{"id":222,"display_title":"Update codexbar for v0.49.0 (codexbar-v0.49.0-31322422801)","status":"completed","conclusion":"success"}'
  fi
elif [[ "$url" == *'/Formula/codexbar.rb' ]]; then
  cp "${MOCK_FIXTURE_DIR}/Formula.rb" "$body_file"
elif [[ "$url" == *'/Casks/codexbar.rb' ]]; then
  if [[ "$MOCK_SCENARIO" == "content-mismatch" ]]; then
    cp "${MOCK_FIXTURE_DIR}/Cask-old.rb" "$body_file"
  else
    cp "${MOCK_FIXTURE_DIR}/Cask.rb" "$body_file"
  fi
else
  echo "unexpected curl URL: $url" >&2
  exit 2
fi
MOCK

chmod +x "$mock_bin/date" "$mock_bin/sleep" "$mock_bin/git" "$mock_bin/curl"

fixture_dir="$tmp_dir/fixtures"
mkdir -p "$fixture_dir"
cat > "$fixture_dir/Formula.rb" <<'RUBY'
class Codexbar < Formula
  version "0.49.0"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-macos-arm64.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-macos-x86_64.tar.gz"
  sha256 "2222222222222222222222222222222222222222222222222222222222222222"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-linux-aarch64.tar.gz"
  sha256 "3333333333333333333333333333333333333333333333333333333333333333"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-linux-x86_64.tar.gz"
  sha256 "4444444444444444444444444444444444444444444444444444444444444444"
end
RUBY
cat > "$fixture_dir/Cask.rb" <<'RUBY'
cask "codexbar" do
  version "0.49.0"
  sha256 "5555555555555555555555555555555555555555555555555555555555555555"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBar-macos-universal-#{version}.zip"
end
RUBY
cat > "$fixture_dir/Cask-old.rb" <<'RUBY'
cask "codexbar" do
  version "0.48.1"
  sha256 "5555555555555555555555555555555555555555555555555555555555555555"
  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBar-macos-universal-#{version}.zip"
end
RUBY

run_monitor() {
  local scenario="$1"
  local timeout_seconds="${2:-1000}"
  local state_dir="$tmp_dir/state-${scenario}"
  local output_file="$tmp_dir/${scenario}.log"
  mkdir -p "$state_dir"
  PATH="$mock_bin:/usr/bin:/bin" \
    MOCK_SCENARIO="$scenario" \
    MOCK_STATE_DIR="$state_dir" \
    MOCK_FIXTURE_DIR="$fixture_dir" \
    GH_TOKEN=test-token \
    REQUEST_ID=codexbar-v0.49.0-31322422801 \
    RELEASE_TAG=v0.49.0 \
    TAP_WAIT_TIMEOUT_SECONDS="$timeout_seconds" \
    TAP_POLL_SECONDS=1 \
    TAP_CONTENT_ATTEMPTS=2 \
    GITHUB_API_URL=https://api.example.test \
    GITHUB_SERVER_URL=https://github.example.test \
    GITHUB_RAW_URL=https://raw.example.test \
    "$ROOT_DIR/Scripts/wait_for_homebrew_tap_update.sh" > "$output_file" 2>&1
}

run_monitor success
grep -Fq 'Monitoring exact tap run id=222' "$tmp_dir/success.log"
grep -Fq 'status=completed conclusion=success' "$tmp_dir/success.log"
grep -Fq 'formula and cask contain v0.49.0' "$tmp_dir/success.log"
if grep -Fq 'id=999' "$tmp_dir/success.log"; then
  echo "substring-matching unrelated run was accepted" >&2
  exit 1
fi

if run_monitor failure; then
  echo "failed tap run unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'conclusion=failure' "$tmp_dir/failure.log"
grep -Fq 'Exact tap run failed' "$tmp_dir/failure.log"

if run_monitor missing 5; then
  echo "missing tap run unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'waiting for the exact tap workflow run' "$tmp_dir/missing.log"

run_monitor rate-limit
grep -Fq 'GitHub API quota exhausted; reset=1020' "$tmp_dir/rate-limit.log"
grep -Fxq '21' "$tmp_dir/state-rate-limit/sleeps"

if run_monitor content-mismatch 20; then
  echo "mismatched tap content unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'formula/cask content proof failed for v0.49.0' "$tmp_dir/content-mismatch.log"

echo "Homebrew tap wait fixture OK"

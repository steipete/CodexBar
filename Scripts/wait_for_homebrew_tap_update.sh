#!/usr/bin/env bash

set -euo pipefail

tap_repository="${TAP_REPOSITORY:-steipete/homebrew-tap}"
tap_workflow="${TAP_WORKFLOW:-update-formula.yml}"
tap_branch="${TAP_BRANCH:-main}"
tap_formula="${TAP_FORMULA:-codexbar}"
tap_cask="${TAP_CASK:-codexbar}"
wait_timeout_seconds="${TAP_WAIT_TIMEOUT_SECONDS:-3900}"
poll_seconds="${TAP_POLL_SECONDS:-30}"
content_attempts="${TAP_CONTENT_ATTEMPTS:-6}"
api_url="${GITHUB_API_URL:-https://api.github.com}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
raw_url="${GITHUB_RAW_URL:-https://raw.githubusercontent.com}"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REQUEST_ID:?REQUEST_ID is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"

if [[ ! "$tap_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid tap repository: $tap_repository" >&2
  exit 2
fi
if [[ ! "$tap_workflow" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid tap workflow: $tap_workflow" >&2
  exit 2
fi
if [[ ! "$tap_branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid tap branch: $tap_branch" >&2
  exit 2
fi
if [[ ! "$tap_formula" =~ ^[A-Za-z0-9_.-]+$ || ! "$tap_cask" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid tap formula or cask name." >&2
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid request ID: $REQUEST_ID" >&2
  exit 2
fi
if [[ ! "$RELEASE_TAG" =~ ^v[0-9A-Za-z._-]+$ ]]; then
  echo "Invalid release tag: $RELEASE_TAG" >&2
  exit 2
fi
for value in "$wait_timeout_seconds" "$poll_seconds" "$content_attempts"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Wait settings must be positive integers." >&2
    exit 2
  fi
done
for tool in curl git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 2
  fi
done

expected_title="Update ${tap_formula} for ${RELEASE_TAG} (${REQUEST_ID})"
started_epoch="$(date +%s)"
deadline_epoch=$((started_epoch + wait_timeout_seconds))
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

header_value() {
  local header_name="$1"
  local headers_file="$2"
  tr -d '\r' < "$headers_file" \
    | awk -F ': *' -v expected="$header_name" '
        tolower($1) == tolower(expected) { value = $2 }
        END { print value }
      '
}

sleep_with_deadline() {
  local delay_seconds="$1"
  local reason="$2"
  local now_epoch remaining_seconds

  now_epoch="$(date +%s)"
  remaining_seconds=$((deadline_epoch - now_epoch))
  if ((remaining_seconds <= 0 || delay_seconds >= remaining_seconds)); then
    echo "Timed out ${reason}; the ${wait_timeout_seconds}s deadline was reached." >&2
    return 1
  fi
  sleep "$delay_seconds"
}

api_get() {
  local endpoint="$1"
  local headers_file="$tmp_dir/api-headers"
  local body_file="$tmp_dir/api-body"
  local curl_exit http_code message remaining reset_epoch retry_after now_epoch delay_seconds

  while true; do
    curl_exit=0
    http_code="$(
      curl --silent --show-error --location \
        --connect-timeout 15 \
        --max-time 60 \
        --dump-header "$headers_file" \
        --output "$body_file" \
        --write-out '%{http_code}' \
        --header 'Accept: application/vnd.github+json' \
        --header "Authorization: Bearer ${GH_TOKEN}" \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        "${api_url}/repos/${tap_repository}/${endpoint}"
    )" || curl_exit=$?

    if ((curl_exit != 0)); then
      echo "GitHub API request failed with curl exit ${curl_exit}; retrying." >&2
      sleep_with_deadline "$poll_seconds" "waiting for the GitHub API" || return 1
      continue
    fi

    if [[ "$http_code" == "200" ]]; then
      cat "$body_file"
      return 0
    fi

    message="$(jq -r '.message // ""' "$body_file" 2>/dev/null || true)"
    remaining="$(header_value 'x-ratelimit-remaining' "$headers_file")"
    reset_epoch="$(header_value 'x-ratelimit-reset' "$headers_file")"
    retry_after="$(header_value 'retry-after' "$headers_file")"

    if [[ "$http_code" == "429" ]] \
      || [[ "$http_code" == "403" && "$remaining" == "0" ]] \
      || [[ "$http_code" == "403" && "$retry_after" =~ ^[0-9]+$ ]] \
      || [[ "$http_code" == "403" && "$message" =~ [Rr]ate.?limit|[Aa]buse ]]; then
      now_epoch="$(date +%s)"
      if [[ "$remaining" == "0" && "$reset_epoch" =~ ^[0-9]+$ ]]; then
        delay_seconds=$((reset_epoch - now_epoch + 5))
        if ((delay_seconds < 1)); then
          delay_seconds=1
        fi
        echo "GitHub API quota exhausted; reset=${reset_epoch}, sleeping ${delay_seconds}s." >&2
      elif [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        delay_seconds=$((retry_after + 1))
        echo "GitHub API secondary limit; Retry-After=${retry_after}, sleeping ${delay_seconds}s." >&2
      else
        delay_seconds=60
        echo "GitHub API rate limited without a reset hint; sleeping ${delay_seconds}s." >&2
      fi
      sleep_with_deadline "$delay_seconds" "waiting for the GitHub API rate limit to reset" || return 1
      continue
    fi

    echo "GitHub API request failed: HTTP ${http_code}${message:+: ${message}}" >&2
    return 1
  done
}

discover_run_id() {
  local payload match_count run_id

  while true; do
    payload="$(api_get "actions/workflows/${tap_workflow}/runs?event=workflow_dispatch&per_page=100")" || return 1
    match_count="$(
      jq -r --arg expected "$expected_title" \
        '[.workflow_runs[]? | select(.display_title == $expected)] | length' <<< "$payload"
    )"
    run_id="$(
      jq -r --arg expected "$expected_title" \
        '[.workflow_runs[]? | select(.display_title == $expected)] | max_by(.id) | .id // empty' <<< "$payload"
    )"
    if [[ "$run_id" =~ ^[0-9]+$ ]]; then
      if ((match_count > 1)); then
        echo "Found ${match_count} exact tap runs for the request; monitoring newest id=${run_id}." >&2
      fi
      printf '%s\n' "$run_id"
      return 0
    fi

    echo "Exact tap run has not appeared yet: ${expected_title}" >&2
    sleep_with_deadline "$poll_seconds" "waiting for the exact tap workflow run" || return 1
  done
}

verify_tap_contents() {
  local version="${RELEASE_TAG#v}"
  local remote_url="${server_url}/${tap_repository}.git"
  local head_sha formula_file="$tmp_dir/formula.rb" cask_file="$tmp_dir/cask.rb"
  local attempt formula_sha_count cask_sha_count asset content_matches

  for ((attempt = 1; attempt <= content_attempts; attempt++)); do
    head_sha="$(git ls-remote --exit-code "$remote_url" "refs/heads/${tap_branch}" 2>/dev/null | awk 'NR == 1 { print $1 }')" || true
    if [[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]] \
      && curl -fsSL --connect-timeout 15 --max-time 60 \
        "${raw_url}/${tap_repository}/${head_sha}/Formula/${tap_formula}.rb" -o "$formula_file" \
      && curl -fsSL --connect-timeout 15 --max-time 60 \
        "${raw_url}/${tap_repository}/${head_sha}/Casks/${tap_cask}.rb" -o "$cask_file"
    then
      if awk -v expected="$version" '$1 == "version" && $2 == "\"" expected "\"" { found = 1 } END { exit !found }' \
        "$formula_file" \
        && awk -v expected="$version" '$1 == "version" && $2 == "\"" expected "\"" { found = 1 } END { exit !found }' \
          "$cask_file"
      then
        content_matches=true
        for asset in \
          macos-arm64 \
          macos-x86_64 \
          linux-aarch64 \
          linux-x86_64
        do
          if ! grep -Fq \
            "releases/download/v#{version}/CodexBarCLI-v#{version}-${asset}.tar.gz" \
            "$formula_file"
          then
            content_matches=false
          fi
        done
        if ! grep -Fq \
          'releases/download/v#{version}/CodexBar-macos-universal-#{version}.zip' \
          "$cask_file"
        then
          content_matches=false
        fi
        formula_sha_count="$(grep -Ec '^[[:space:]]*sha256 "[0-9a-f]{64}"' "$formula_file" || true)"
        cask_sha_count="$(grep -Ec '^[[:space:]]*sha256 "[0-9a-f]{64}"' "$cask_file" || true)"
        if [[ "$content_matches" == "true" && "$formula_sha_count" == "4" && "$cask_sha_count" == "1" ]]; then
          echo "Verified ${tap_repository}@${head_sha}: formula and cask contain ${RELEASE_TAG} with all expected assets."
          return 0
        fi
      fi
    fi

    echo "Tap content proof attempt ${attempt}/${content_attempts} did not match ${RELEASE_TAG}." >&2
    if ((attempt < content_attempts)); then
      sleep_with_deadline "$poll_seconds" "waiting for tap content proof" || return 1
    fi
  done

  echo "Exact tap run succeeded, but formula/cask content proof failed for ${RELEASE_TAG}." >&2
  return 1
}

run_id="$(discover_run_id)" || {
  echo "Timed out or failed while locating the exact tap run: ${expected_title}" >&2
  exit 1
}
run_url="${server_url}/${tap_repository}/actions/runs/${run_id}"
echo "Monitoring exact tap run id=${run_id}: ${run_url}"

last_state=""
while true; do
  payload="$(api_get "actions/runs/${run_id}")" || exit 1
  observed_id="$(jq -r '.id // empty' <<< "$payload")"
  observed_title="$(jq -r '.display_title // empty' <<< "$payload")"
  run_state="$(jq -r '.status // "unknown"' <<< "$payload")"
  run_conclusion="$(jq -r '.conclusion // "pending"' <<< "$payload")"

  if [[ "$observed_id" != "$run_id" || "$observed_title" != "$expected_title" ]]; then
    echo "Tap run identity changed while monitoring id=${run_id}." >&2
    exit 1
  fi

  current_state="status=${run_state} conclusion=${run_conclusion}"
  if [[ "$current_state" != "$last_state" ]]; then
    echo "Tap run id=${run_id} ${current_state}"
    last_state="$current_state"
  fi

  if [[ "$run_state" == "completed" ]]; then
    if [[ "$run_conclusion" != "success" ]]; then
      echo "Exact tap run failed: id=${run_id} conclusion=${run_conclusion} url=${run_url}" >&2
      exit 1
    fi
    verify_tap_contents
    exit 0
  fi

  sleep_with_deadline "$poll_seconds" "waiting for tap run id=${run_id} to complete" || exit 1
done

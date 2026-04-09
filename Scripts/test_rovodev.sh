#!/usr/bin/env bash
# Test the Rovo Dev usage fetcher end-to-end.
#
# Usage:
#   ./Scripts/test_rovodev.sh              # build + run (full app, adhoc signed)
#   ./Scripts/test_rovodev.sh --fetch-only # print raw API response without launching the app
#
# The --fetch-only mode reads ~/.config/acli/global_auth_config.yaml, imports
# browser cookies for your Atlassian site, and prints the usage JSON.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FETCH_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --fetch-only|-f) FETCH_ONLY=1 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--fetch-only]"
      exit 0
      ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CONFIG_FILE="${HOME}/.config/acli/global_auth_config.yaml"

check_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    fail "Atlassian CLI config not found: ${CONFIG_FILE}
Run 'acli' to set up your profile first."
  fi
  local site cloud_id
  site="$(grep 'site:' "${CONFIG_FILE}" | head -1 | awk -F': ' '{print $2}' | tr -d '[:space:]')"
  cloud_id="$(grep 'cloud_id:' "${CONFIG_FILE}" | head -1 | awk -F': ' '{print $2}' | tr -d '[:space:]')"
  if [[ -z "${site}" || -z "${cloud_id}" ]]; then
    fail "Could not parse site/cloud_id from ${CONFIG_FILE}"
  fi
  echo "${site}:${cloud_id}"
}

fetch_usage() {
  local site="$1"
  local cloud_id="$2"
  local api_url="https://${site}/gateway/api/rovodev/v3/credits/entitlements/entitlement-allowance"

  log "Fetching Rovo Dev usage from ${api_url}"

  # Pull browser cookies for the Atlassian domain.
  # The easiest cross-browser method on macOS is to read Chrome's cookie DB directly,
  # but that requires unlocking Keychain. We use a simpler curl with --cookie-jar approach
  # by leveraging the fact that 'cookies' in Safari are accessible without decryption.
  #
  # Preferred: use the app's built-in debug probe. We trigger that below.
  # Fallback shown here calls the API directly with cookies from the system.

  log "NOTE: For full cookie import use the app's Debug pane → Rovo Dev → 'Run Probe'."
  log "Calling API directly (may 401 without a valid browser session cookie)..."

  local body
  body="$(printf '{"cloudId":"%s","entitlementId":"unknown","productKey":"unknown"}' "${cloud_id}")"

  local response
  if ! response="$(curl -sf \
    --max-time 15 \
    -X POST "${api_url}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Origin: https://${site}" \
    -H "Referer: https://${site}/rovodev/your-usage" \
    -b "${HOME}/Library/Cookies/Cookies.binarycookies" \
    --data "${body}" 2>&1)"; then
    log "WARN: curl failed (likely no cookies). Trying without cookie file..."
    response="$(curl -sf \
      --max-time 15 \
      -X POST "${api_url}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "Origin: https://${site}" \
      -H "Referer: https://${site}/rovodev/your-usage" \
      --data "${body}" 2>&1 || echo '{"error":"request failed"}')"
  fi

  echo ""
  log "Raw API response:"
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"

  # Parse key fields
  local current_usage credit_cap
  current_usage="$(echo "${response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('currentUsage','?'))" 2>/dev/null || echo "?")"
  credit_cap="$(echo "${response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('creditCap','?'))" 2>/dev/null || echo "?")"

  echo ""
  log "Summary:"
  echo "  Current usage : ${current_usage}"
  echo "  Credit cap    : ${credit_cap}"
  if [[ "${current_usage}" != "?" && "${credit_cap}" != "?" && "${credit_cap}" != "0" ]]; then
    local pct
    pct="$(python3 -c "print(f'{${current_usage}/${credit_cap}*100:.1f}%')" 2>/dev/null || echo "?")"
    echo "  Used          : ${pct}"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
log "Rovo Dev Provider Test"
echo ""

log "Checking ACLI config at ${CONFIG_FILE}..."
IFS=':' read -r site cloud_id <<< "$(check_config)"
log "Site     : ${site}"
log "Cloud ID : ${cloud_id}"
echo ""

if [[ "${FETCH_ONLY}" == "1" ]]; then
  fetch_usage "${site}" "${cloud_id}"
  echo ""
  log "Done. To test with full browser cookie import, run the app and open:"
  echo "  Preferences → Providers → Rovo Dev → Enable"
  echo "  Debug pane → Probe Logs → Rovo Dev"
  exit 0
fi

# Full build + launch
log "Building and launching CodexBar with Rovo Dev provider..."
echo "  The app will appear in the menu bar."
echo "  Go to Preferences → Providers → Rovo Dev to enable it."
echo ""

exec "${ROOT_DIR}/Scripts/compile_and_run.sh" "$@"

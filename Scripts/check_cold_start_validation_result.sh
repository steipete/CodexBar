#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_ROOT="${CODEXBAR_COLD_START_ARTIFACT_DIR:-${HOME}/.codex/artifacts/CodexBar}"
EXPECTED_APP_PATH="${CODEXBAR_EXPECTED_APP_PATH:-}"
RUN_DIR="${1:-}"
RUN_DIR_PROVIDED=false
LAUNCHD_SUMMARY_PATH=""
LAUNCHD_VALIDATED_ARTIFACT_DIR=""
LAUNCHD_CHECKER_EXIT_CODE=""

usage() {
  cat <<EOF
Usage:
  $0 [cold-start-artifact-dir]

When no directory is provided, checks the newest cold-start-* directory under:
  ${ARTIFACT_ROOT}

Environment:
  CODEXBAR_EXPECTED_APP_PATH  Optional app bundle path that run-metadata.txt must match.
  CODEXBAR_EXPECTED_APP_SHA256  Optional app executable SHA-256 that app-bundle-metadata.txt must match.
  CODEXBAR_EXPECTED_VALIDATOR_SHA256  Optional validator script SHA-256 that app-bundle-metadata.txt must match.
  CODEXBAR_EXPECTED_CHECKER_SHA256  Optional checker script SHA-256 that app-bundle-metadata.txt must match.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

latest_run_dir() {
  find "${ARTIFACT_ROOT}" -maxdepth 1 -type d -name 'cold-start-*' -print | sort | tail -n 1
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "Missing required artifact file: ${path}"
}

metadata_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2) }' "${file}" | tail -n 1
}

maybe_require_launchd_summary() {
  local run_dir="$1"
  local artifact_app_sha256="$2"
  local summary_path="${ARTIFACT_ROOT}/launchd/last-run-summary.txt"
  [[ "${RUN_DIR_PROVIDED}" == "false" && -f "${summary_path}" ]] || return 0

  LAUNCHD_SUMMARY_PATH="${summary_path}"
  LAUNCHD_VALIDATED_ARTIFACT_DIR="$(metadata_value validated_artifact_dir "${summary_path}")"
  LAUNCHD_CHECKER_EXIT_CODE="$(metadata_value checker_exit_code "${summary_path}")"

  [[ "$(metadata_value exit_code "${summary_path}")" == "0" ]] ||
    fail "LaunchAgent summary did not report exit_code=0: ${summary_path}"
  [[ "$(metadata_value latest_artifact_dir "${summary_path}")" == "${run_dir}" ]] ||
    fail "LaunchAgent summary latest_artifact_dir does not match checked artifact"
  [[ "${LAUNCHD_VALIDATED_ARTIFACT_DIR}" == "${run_dir}" ]] ||
    fail "LaunchAgent summary validated_artifact_dir does not match checked artifact"
  [[ "${LAUNCHD_CHECKER_EXIT_CODE}" == "0" ]] ||
    fail "LaunchAgent summary did not report checker_exit_code=0: ${summary_path}"
  if [[ -n "${EXPECTED_APP_PATH}" ]]; then
    [[ "$(metadata_value app_path "${summary_path}")" == "${EXPECTED_APP_PATH}" ]] ||
      fail "LaunchAgent summary app_path does not match CODEXBAR_EXPECTED_APP_PATH"
  fi
  local summary_expected_sha
  summary_expected_sha="$(metadata_value expected_app_sha256 "${summary_path}")"
  [[ -n "${summary_expected_sha}" ]] ||
    fail "LaunchAgent summary is missing expected_app_sha256"
  [[ "${summary_expected_sha}" == "${artifact_app_sha256}" ]] ||
    fail "LaunchAgent summary expected_app_sha256 does not match artifact app_binary_sha256"
  if [[ -n "${CODEXBAR_EXPECTED_VALIDATOR_SHA256:-}" ]]; then
    [[ "$(metadata_value expected_validator_sha256 "${summary_path}")" == "${CODEXBAR_EXPECTED_VALIDATOR_SHA256}" ]] ||
      fail "LaunchAgent summary expected_validator_sha256 does not match CODEXBAR_EXPECTED_VALIDATOR_SHA256"
  fi
  if [[ -n "${CODEXBAR_EXPECTED_CHECKER_SHA256:-}" ]]; then
    [[ "$(metadata_value expected_checker_sha256 "${summary_path}")" == "${CODEXBAR_EXPECTED_CHECKER_SHA256}" ]] ||
      fail "LaunchAgent summary expected_checker_sha256 does not match CODEXBAR_EXPECTED_CHECKER_SHA256"
  fi
}

assert_contains() {
  local path="$1"
  local text="$2"
  grep -F "${text}" "${path}" >/dev/null || fail "${path} is missing: ${text}"
}

assert_metadata_number_at_least() {
  local file="$1"
  local key="$2"
  local minimum="$3"
  local value

  value="$(metadata_value "${key}" "${file}")"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${file} is missing numeric ${key}"
  [[ "${value}" -ge "${minimum}" ]] || fail "${file} ${key}=${value}, expected at least ${minimum}"
}

assert_metadata_present() {
  local file="$1"
  local key="$2"
  local value

  value="$(metadata_value "${key}" "${file}")"
  [[ -n "${value}" ]] || fail "${file} is missing ${key}"
}

assert_metadata_equals() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local value

  value="$(metadata_value "${key}" "${file}")"
  [[ "${value}" == "${expected}" ]] || fail "${file} ${key}=${value}, expected ${expected}"
}

if [[ "${RUN_DIR}" == "-h" || "${RUN_DIR}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(latest_run_dir)"
else
  RUN_DIR_PROVIDED=true
fi

[[ -n "${RUN_DIR}" ]] || fail "No cold-start artifacts found under ${ARTIFACT_ROOT}"
[[ -d "${RUN_DIR}" ]] || fail "Artifact directory not found: ${RUN_DIR}"

boot_metadata="${RUN_DIR}/boot-session-metadata.txt"
app_bundle_metadata="${RUN_DIR}/app-bundle-metadata.txt"
login_context="${RUN_DIR}/login-context.txt"
run_metadata="${RUN_DIR}/run-metadata.txt"
immediate_status="${RUN_DIR}/immediate-parent-menu-status.txt"
immediate_parent_ax="${RUN_DIR}/immediate-parent-menu-ax.txt"
settled_parent_ax="${RUN_DIR}/settled-parent-menu-ax.txt"
cost_submenu_ax="${RUN_DIR}/settled-cost-submenu-ax.txt"
visual_readiness="${RUN_DIR}/visual-readiness.txt"

require_file "${boot_metadata}"
require_file "${app_bundle_metadata}"
require_file "${login_context}"
require_file "${run_metadata}"
require_file "${immediate_status}"
require_file "${immediate_parent_ax}"
require_file "${settled_parent_ax}"
require_file "${cost_submenu_ax}"
require_file "${visual_readiness}"

[[ "$(metadata_value post_boot_first_launch_candidate "${boot_metadata}")" == "true" ]] ||
  fail "Artifact is not valid first-after-boot proof: post_boot_first_launch_candidate is not true"
[[ "$(metadata_value existing_codexbar_process_count "${boot_metadata}")" == "0" ]] ||
  fail "Artifact is not valid first-after-boot proof: CodexBar was already running before validation"
[[ "$(metadata_value running_codexbar_process_count "${login_context}")" == "0" ]] ||
  fail "Login context is not valid first-launch proof: CodexBar was already running before validation"
[[ "$(metadata_value post_boot_first_launch_candidate "${run_metadata}")" == "true" ]] ||
  fail "Run metadata does not preserve post_boot_first_launch_candidate=true"

artifact_app_executable="$(metadata_value app_executable "${app_bundle_metadata}")"
run_process_path="$(metadata_value process_path "${run_metadata}")"
[[ -n "${artifact_app_executable}" ]] ||
  fail "App bundle metadata is missing app_executable"
[[ -n "${run_process_path}" ]] ||
  fail "Run metadata is missing process_path"
[[ "${run_process_path}" == "${artifact_app_executable}" ]] ||
  fail "Run metadata process_path does not match app bundle metadata app_executable"

if [[ -n "${EXPECTED_APP_PATH}" ]]; then
  [[ "$(metadata_value app_path "${run_metadata}")" == "${EXPECTED_APP_PATH}" ]] ||
    fail "Run metadata app_path does not match CODEXBAR_EXPECTED_APP_PATH"
  [[ "$(metadata_value app_path "${app_bundle_metadata}")" == "${EXPECTED_APP_PATH}" ]] ||
    fail "App bundle metadata app_path does not match CODEXBAR_EXPECTED_APP_PATH"
  [[ "${artifact_app_executable}" == "${EXPECTED_APP_PATH}/Contents/MacOS/CodexBar" ]] ||
    fail "App bundle metadata app_executable does not match CODEXBAR_EXPECTED_APP_PATH"
fi

app_binary_sha256="$(metadata_value app_binary_sha256 "${app_bundle_metadata}")"
[[ -n "${app_binary_sha256}" ]] ||
  fail "App bundle metadata is missing app_binary_sha256"
validator_script_sha256="$(metadata_value validator_script_sha256 "${app_bundle_metadata}")"
[[ -n "${validator_script_sha256}" ]] ||
  fail "App bundle metadata is missing validator_script_sha256"
checker_script_sha256="$(metadata_value checker_script_sha256 "${app_bundle_metadata}")"
[[ -n "${checker_script_sha256}" ]] ||
  fail "App bundle metadata is missing checker_script_sha256"
maybe_require_launchd_summary "${RUN_DIR}" "${app_binary_sha256}"
if [[ -n "${CODEXBAR_EXPECTED_APP_SHA256:-}" ]]; then
  [[ "${app_binary_sha256}" == "${CODEXBAR_EXPECTED_APP_SHA256}" ]] ||
    fail "App bundle metadata app_binary_sha256 does not match CODEXBAR_EXPECTED_APP_SHA256"
fi
if [[ -n "${CODEXBAR_EXPECTED_VALIDATOR_SHA256:-}" ]]; then
  [[ "${validator_script_sha256}" == "${CODEXBAR_EXPECTED_VALIDATOR_SHA256}" ]] ||
    fail "App bundle metadata validator_script_sha256 does not match CODEXBAR_EXPECTED_VALIDATOR_SHA256"
fi
if [[ -n "${CODEXBAR_EXPECTED_CHECKER_SHA256:-}" ]]; then
  [[ "${checker_script_sha256}" == "${CODEXBAR_EXPECTED_CHECKER_SHA256}" ]] ||
    fail "App bundle metadata checker_script_sha256 does not match CODEXBAR_EXPECTED_CHECKER_SHA256"
fi

if [[ "$(metadata_value codexbar_login_item_present "${login_context}")" == "true" ]]; then
  login_item_app_sha256="$(metadata_value login_item_app_sha256 "${login_context}")"
  [[ -n "${login_item_app_sha256}" ]] ||
    fail "Login context says CodexBar Login Item is present but login_item_app_sha256 is missing"
  [[ "${login_item_app_sha256}" == "${app_binary_sha256}" ]] ||
    fail "CodexBar Login Item app binary does not match artifact app_binary_sha256"
fi

[[ "$(tr -d '[:space:]' <"${immediate_status}")" == "complete" ]] ||
  fail "Immediate first-open parent menu was not complete"

assert_contains "${immediate_parent_ax}" "Buy Credits..."
assert_contains "${immediate_parent_ax}" "Cost | submenu=true"
assert_contains "${immediate_parent_ax}" "Usage Dashboard"
assert_contains "${immediate_parent_ax}" "Status Page"
assert_contains "${immediate_parent_ax}" "Refresh"

assert_contains "${settled_parent_ax}" "Buy Credits..."
assert_contains "${settled_parent_ax}" "Cost | submenu=true"
assert_contains "${settled_parent_ax}" "Usage Dashboard"
assert_contains "${settled_parent_ax}" "Status Page"
assert_contains "${settled_parent_ax}" "Refresh"
assert_contains "${cost_submenu_ax}" "Cost | submenu=true"
assert_metadata_present "${visual_readiness}" python_executable
assert_metadata_present "${visual_readiness}" python_version
if [[ -z "$(metadata_value pillow_version "${visual_readiness}")" ]]; then
  assert_metadata_present "${visual_readiness}" image_decoder
fi
assert_metadata_number_at_least "${visual_readiness}" immediate_parent_width 1
assert_metadata_number_at_least "${visual_readiness}" immediate_parent_height 1
assert_metadata_number_at_least "${visual_readiness}" settled_parent_width 1
assert_metadata_number_at_least "${visual_readiness}" settled_parent_height 1
assert_metadata_number_at_least "${visual_readiness}" cost_submenu_width 1
assert_metadata_number_at_least "${visual_readiness}" cost_submenu_height 1
assert_metadata_equals "${visual_readiness}" settled_parent_bounds_found true
assert_metadata_number_at_least "${visual_readiness}" cost_submenu_item_count 1

cat <<EOF
OK: cold-start validation proves first-after-boot menu readiness.
artifact=${RUN_DIR}
app_path=$(metadata_value app_path "${run_metadata}")
app_binary_sha256=${app_binary_sha256}
validator_script_sha256=${validator_script_sha256}
checker_script_sha256=${checker_script_sha256}
visual_python_executable=$(metadata_value python_executable "${visual_readiness}")
visual_python_version=$(metadata_value python_version "${visual_readiness}")
visual_pillow_version=$(metadata_value pillow_version "${visual_readiness}")
visual_image_decoder=$(metadata_value image_decoder "${visual_readiness}")
immediate_parent_bounds_found=$(metadata_value immediate_parent_bounds_found "${visual_readiness}")
settled_parent_bounds_found=$(metadata_value settled_parent_bounds_found "${visual_readiness}")
cost_submenu_bounds_found=$(metadata_value cost_submenu_bounds_found "${visual_readiness}")
immediate_parent_size=$(metadata_value immediate_parent_width "${visual_readiness}")x$(metadata_value immediate_parent_height "${visual_readiness}")
settled_parent_size=$(metadata_value settled_parent_width "${visual_readiness}")x$(metadata_value settled_parent_height "${visual_readiness}")
cost_submenu_size=$(metadata_value cost_submenu_width "${visual_readiness}")x$(metadata_value cost_submenu_height "${visual_readiness}")
immediate_parent_gold_pixels=$(metadata_value immediate_parent_gold_pixels "${visual_readiness}")
settled_parent_gold_pixels=$(metadata_value settled_parent_gold_pixels "${visual_readiness}")
cost_submenu_aqua_pixels=$(metadata_value cost_submenu_aqua_pixels "${visual_readiness}")
cost_submenu_item_count=$(metadata_value cost_submenu_item_count "${visual_readiness}")
boot_time_utc=$(metadata_value boot_time_utc "${boot_metadata}")
metadata_written_at_utc=$(metadata_value metadata_written_at_utc "${boot_metadata}")
uptime_seconds=$(metadata_value uptime_seconds "${boot_metadata}")
EOF

if [[ -n "${LAUNCHD_SUMMARY_PATH}" ]]; then
  cat <<EOF
launchd_summary=${LAUNCHD_SUMMARY_PATH}
launchd_validated_artifact_dir=${LAUNCHD_VALIDATED_ARTIFACT_DIR}
launchd_checker_exit_code=${LAUNCHD_CHECKER_EXIT_CODE}
EOF
fi

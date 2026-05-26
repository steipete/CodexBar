#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${CODEXBAR_APP_PATH:-${ROOT}/.build/package/CodexBar.app}"
LOGIN_ITEM_APP_PATH="${CODEXBAR_LOGIN_ITEM_APP_PATH:-/Applications/CodexBar.app}"
ARTIFACT_ROOT="${CODEXBAR_COLD_START_ARTIFACT_DIR:-${HOME}/.codex/artifacts/CodexBar}"
LABEL="${CODEXBAR_COLD_START_LAUNCHD_LABEL:-com.codexbar.cold-start-validation}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${ARTIFACT_ROOT}/launchd"
RUNNER_PATH="${LOG_DIR}/run-next-boot-validation.sh"
SUMMARY_PATH="${LOG_DIR}/last-run-summary.txt"
LOGIN_ITEM_SNAPSHOT_PATH="${LOG_DIR}/codexbar-login-item-snapshot.env"
PROCESS_PATTERN="CodexBar.app/Contents/MacOS/CodexBar"
POST_BOOT_MAX_UPTIME_SECONDS="${CODEXBAR_POST_BOOT_MAX_UPTIME_SECONDS:-900}"

usage() {
  cat <<EOF
Usage:
  $0 install
  $0 uninstall
  $0 status
  $0 preflight
  $0 check-result
  $0 snapshot-login-item
  $0 disable-login-item
  $0 restore-login-item

Environment:
  CODEXBAR_APP_PATH                  App bundle to validate. Default: ${ROOT}/.build/package/CodexBar.app
  CODEXBAR_LOGIN_ITEM_APP_PATH       Normal login item app bundle to compare. Default: /Applications/CodexBar.app
  CODEXBAR_COLD_START_ARTIFACT_DIR   Artifact root. Default: ${HOME}/.codex/artifacts/CodexBar
  CODEXBAR_POST_BOOT_MAX_UPTIME_SECONDS  First-after-boot window. Default inherited by validator: 900
EOF
}

app_binary_sha256() {
  shasum -a 256 "${APP_PATH}/Contents/MacOS/CodexBar" | awk '{ print $1 }'
}

script_sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

bundle_binary_sha256() {
  local bundle_path="$1"
  shasum -a 256 "${bundle_path}/Contents/MacOS/CodexBar" | awk '{ print $1 }'
}

runner_expected_app_sha256() {
  [[ -f "${RUNNER_PATH}" ]] || return 0
  runner_expected_value EXPECTED_APP_SHA256
}

runner_expected_validator_sha256() {
  [[ -f "${RUNNER_PATH}" ]] || return 0
  runner_expected_value EXPECTED_VALIDATOR_SHA256
}

runner_expected_checker_sha256() {
  [[ -f "${RUNNER_PATH}" ]] || return 0
  runner_expected_value EXPECTED_CHECKER_SHA256
}

runner_expected_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {
    value = substr($0, length($1) + 2)
    gsub(/^"/, "", value)
    gsub(/"$/, "", value)
    print value
  }' "${RUNNER_PATH}" | tail -n 1
}

runner_contains_final_checker() {
  [[ -f "${RUNNER_PATH}" ]] || return 1
  grep -F 'Scripts/check_cold_start_validation_result.sh' "${RUNNER_PATH}" >/dev/null &&
    grep -F 'CODEXBAR_EXPECTED_APP_PATH="${APP_PATH}"' "${RUNNER_PATH}" >/dev/null &&
    grep -F 'CODEXBAR_EXPECTED_APP_SHA256="${EXPECTED_APP_SHA256}"' "${RUNNER_PATH}" >/dev/null &&
    grep -F 'CODEXBAR_EXPECTED_VALIDATOR_SHA256="${EXPECTED_VALIDATOR_SHA256}"' "${RUNNER_PATH}" >/dev/null &&
    grep -F 'CODEXBAR_EXPECTED_CHECKER_SHA256="${EXPECTED_CHECKER_SHA256}"' "${RUNNER_PATH}" >/dev/null
}

fail_preflight() {
  echo "ERROR: $*" >&2
  return 1
}

login_items() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    get the name of every login item
end tell
APPLESCRIPT
}

normalized_login_items() {
  login_items | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

codexbar_login_item_present() {
  normalized_login_items |
    awk 'BEGIN { found = 0 } tolower($0) == "codexbar" { found = 1 } END { print found ? "true" : "false" }'
}

codexbar_login_item_path() {
  login_item_snapshot | awk -F= '$1 == "path" { print substr($0, length($1) + 2); exit }'
}

quote_env_value() {
  printf "%q" "$1"
}

login_item_snapshot() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    set matchingItems to every login item whose name is "CodexBar"
    if (count of matchingItems) is 0 then
        return "present=false"
    end if
    set itemRef to item 1 of matchingItems
    set itemPath to ""
    set itemHidden to false
    try
        set itemPath to path of itemRef
    end try
    try
        set itemHidden to hidden of itemRef
    end try
    return "present=true" & linefeed & "name=CodexBar" & linefeed & "path=" & itemPath & linefeed & "hidden=" & (itemHidden as text)
end tell
APPLESCRIPT
}

save_login_item_snapshot() {
  mkdir -p "${LOG_DIR}"
  local snapshot
  local present="false"
  local item_path=""
  local hidden="false"
  snapshot="$(login_item_snapshot)"
  while IFS= read -r line; do
    case "${line}" in
      present=*) present="${line#present=}" ;;
      path=*) item_path="${line#path=}" ;;
      hidden=*) hidden="${line#hidden=}" ;;
    esac
  done <<<"${snapshot}"

  {
    echo "present=$(quote_env_value "${present}")"
    echo "name=CodexBar"
    echo "path=$(quote_env_value "${item_path}")"
    echo "hidden=$(quote_env_value "${hidden}")"
    echo "saved_at_utc=$(quote_env_value "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
  } >"${LOGIN_ITEM_SNAPSHOT_PATH}"

  echo "Saved CodexBar Login Item snapshot: ${LOGIN_ITEM_SNAPSHOT_PATH}"
  echo "login_item_present=${present}"
  if [[ -n "${item_path}" ]]; then
    echo "login_item_path=${item_path}"
  fi
  echo "login_item_hidden=${hidden}"
}

disable_login_item_for_validation() {
  save_login_item_snapshot
  if [[ "$(codexbar_login_item_present)" != "true" ]]; then
    echo "CodexBar Login Item is already absent."
    return 0
  fi
  osascript <<'APPLESCRIPT'
tell application "System Events"
    delete every login item whose name is "CodexBar"
end tell
APPLESCRIPT
  echo "Disabled CodexBar Login Item for uncontested cold-start validation."
}

restore_login_item_snapshot() {
  if [[ ! -f "${LOGIN_ITEM_SNAPSHOT_PATH}" ]]; then
    echo "ERROR: Login Item snapshot not found: ${LOGIN_ITEM_SNAPSHOT_PATH}" >&2
    return 1
  fi

  local present=""
  local item_path=""
  local hidden="false"
  # shellcheck disable=SC1090
  source "${LOGIN_ITEM_SNAPSHOT_PATH}"
  present="${present:-false}"
  item_path="${path:-}"
  hidden="${hidden:-false}"

  if [[ "${present}" != "true" ]]; then
    echo "Snapshot recorded no CodexBar Login Item; nothing to restore."
    return 0
  fi
  if [[ -z "${item_path}" ]]; then
    echo "ERROR: Snapshot is missing the Login Item path." >&2
    return 1
  fi
  if [[ ! -e "${item_path}" ]]; then
    echo "ERROR: Snapshot Login Item path no longer exists: ${item_path}" >&2
    return 1
  fi
  if [[ "$(codexbar_login_item_present)" == "true" ]]; then
    echo "CodexBar Login Item is already present."
    return 0
  fi

  LOGIN_ITEM_RESTORE_PATH="${item_path}" LOGIN_ITEM_RESTORE_HIDDEN="${hidden}" osascript <<'APPLESCRIPT'
set restorePath to system attribute "LOGIN_ITEM_RESTORE_PATH"
set restoreHidden to (system attribute "LOGIN_ITEM_RESTORE_HIDDEN") is "true"
tell application "System Events"
    make login item at end with properties {path:restorePath, hidden:restoreHidden}
end tell
APPLESCRIPT
  echo "Restored CodexBar Login Item from snapshot."
  echo "login_item_path=${item_path}"
  echo "login_item_hidden=${hidden}"
}

running_codexbar_processes() {
  ps -axo pid=,comm=,args= | awk '
    {
      pid=$1
      comm=$2
      $1=""
      $2=""
      sub(/^[[:space:]]+/, "")
      split(comm, parts, "/")
      commExecutable=parts[length(parts)]
      split($0, argvParts, /[[:space:]]+/)
      split(argvParts[1], argvPathParts, "/")
      argvExecutable=argvPathParts[length(argvPathParts)]
      if (commExecutable == "CodexBar" || argvExecutable == "CodexBar") {
        print pid " " $0
      }
    }
  '
}

count_running_codexbar_processes() {
  running_codexbar_processes | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

current_boot_epoch() {
  sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'
}

epoch_to_utc_iso() {
  TZ=UTC date -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

now_epoch() {
  date +%s
}

status_latest_artifact_dir() {
  find "${ARTIFACT_ROOT}" -maxdepth 1 -type d -name 'cold-start-*' -print 2>/dev/null | sort | tail -n 1
}

artifact_metadata_value() {
  local key="$1"
  local file="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2) }' "${file}" | tail -n 1
}

resolve_visual_python() {
  local candidate
  for candidate in \
    "${CODEXBAR_PYTHON_BIN:-}" \
    "$(command -v python3 2>/dev/null || true)" \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    if "${candidate}" <<'PY' >/dev/null 2>&1
from PIL import __version__
PY
    then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

python_visual_readiness_metadata() {
  local python_bin="$1"
  "${python_bin}" <<'PY' 2>/dev/null
import sys
from PIL import __version__ as pillow_version

print(f"python_executable={sys.executable}")
print(f"python_version={sys.version.split()[0]}")
print(f"pillow_version={pillow_version}")
PY
}

python_visual_readiness_available() {
  local python_bin="$1"
  python_visual_readiness_metadata "${python_bin}" >/dev/null
}

ensure_paths() {
  local python_bin
  [[ -d "${APP_PATH}" ]] || {
    echo "ERROR: App bundle not found: ${APP_PATH}" >&2
    exit 1
  }
  [[ -x "${ROOT}/Scripts/validate_cold_start_menu.sh" ]] || {
    echo "ERROR: Validator is not executable: ${ROOT}/Scripts/validate_cold_start_menu.sh" >&2
    exit 1
  }
  [[ -x "${ROOT}/Scripts/check_cold_start_validation_result.sh" ]] || {
    echo "ERROR: Result checker is not executable: ${ROOT}/Scripts/check_cold_start_validation_result.sh" >&2
    exit 1
  }
  [[ -x "${APP_PATH}/Contents/MacOS/CodexBar" ]] || {
    echo "ERROR: App executable not found: ${APP_PATH}/Contents/MacOS/CodexBar" >&2
    exit 1
  }
  python_bin="$(resolve_visual_python)" || {
    echo "ERROR: Python/Pillow is required for visual-readiness screenshot analysis." >&2
    exit 1
  }
  python_visual_readiness_available "${python_bin}" || {
    echo "ERROR: Python/Pillow is required for visual-readiness screenshot analysis." >&2
    exit 1
  }
  mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"
}

install_agent() {
  ensure_paths
  local expected_app_sha256
  local expected_checker_sha256
  local expected_validator_sha256
  local python_bin
  expected_app_sha256="$(app_binary_sha256)"
  expected_validator_sha256="$(script_sha256 "${ROOT}/Scripts/validate_cold_start_menu.sh")"
  expected_checker_sha256="$(script_sha256 "${ROOT}/Scripts/check_cold_start_validation_result.sh")"
  python_bin="$(resolve_visual_python)"
  rm -f "${SUMMARY_PATH}" "${LOG_DIR}/launchd.stdout.log" "${LOG_DIR}/launchd.stderr.log"

  cat >"${RUNNER_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LABEL="${LABEL}"
PLIST_PATH="${PLIST_PATH}"
ROOT="${ROOT}"
APP_PATH="${APP_PATH}"
LOGIN_ITEM_APP_PATH="${LOGIN_ITEM_APP_PATH}"
ARTIFACT_ROOT="${ARTIFACT_ROOT}"
LOG_DIR="${LOG_DIR}"
SUMMARY_PATH="${SUMMARY_PATH}"
PROCESS_PATTERN="${PROCESS_PATTERN}"
EXPECTED_APP_SHA256="${expected_app_sha256}"
EXPECTED_VALIDATOR_SHA256="${expected_validator_sha256}"
EXPECTED_CHECKER_SHA256="${expected_checker_sha256}"
PYTHON_BIN="${python_bin}"
STARTED_AT="\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
VALIDATED_ARTIFACT_DIR=""
CHECKER_EXIT_CODE=""
LOGIN_ITEM_PRESENT_AT_RUNNER_START=""
LOGIN_ITEM_APP_PATH_AT_RUNNER_START=""
LOGIN_ITEM_APP_SHA256_AT_RUNNER_START=""
RUNNING_CODEXBAR_PROCESS_COUNT_AT_RUNNER_START=""
RUNNING_CODEXBAR_PROCESSES_AT_RUNNER_START=""

latest_artifact_dir() {
  find "\${ARTIFACT_ROOT}" -maxdepth 1 -type d -name 'cold-start-*' -print 2>/dev/null | sort | tail -n 1
}

bundle_binary_sha256() {
  local bundle_path="\$1"
  shasum -a 256 "\${bundle_path}/Contents/MacOS/CodexBar" | awk '{ print \$1 }'
}

login_items() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    get the name of every login item
end tell
APPLESCRIPT
}

normalized_login_items() {
  login_items | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//'
}

codexbar_login_item_present() {
  normalized_login_items |
    awk 'BEGIN { found = 0 } tolower(\$0) == "codexbar" { found = 1 } END { print found ? "true" : "false" }'
}

login_item_snapshot() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    set matchingItems to every login item whose name is "CodexBar"
    if (count of matchingItems) is 0 then
        return "present=false"
    end if
    set itemRef to item 1 of matchingItems
    set itemPath to ""
    set itemHidden to false
    try
        set itemPath to path of itemRef
    end try
    try
        set itemHidden to hidden of itemRef
    end try
    return "present=true" & linefeed & "name=CodexBar" & linefeed & "path=" & itemPath & linefeed & "hidden=" & (itemHidden as text)
end tell
APPLESCRIPT
}

codexbar_login_item_path() {
  login_item_snapshot | awk -F= '\$1 == "path" { print substr(\$0, length(\$1) + 2); exit }'
}

running_codexbar_processes() {
  ps -axo pid=,comm=,args= | awk '
    {
      pid=\$1
      comm=\$2
      \$1=""
      \$2=""
      sub(/^[[:space:]]+/, "")
      split(comm, parts, "/")
      commExecutable=parts[length(parts)]
      split(\$0, argvParts, /[[:space:]]+/)
      split(argvParts[1], argvPathParts, "/")
      argvExecutable=argvPathParts[length(argvPathParts)]
      if (commExecutable == "CodexBar" || argvExecutable == "CodexBar") {
        print pid " " \$0
      }
    }
  '
}

count_running_codexbar_processes() {
  running_codexbar_processes | sed '/^[[:space:]]*\$/d' | wc -l | tr -d ' '
}

write_summary() {
  local exit_code="\$1"
  local ended_at
  ended_at="\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "\${LOG_DIR}"
  {
    echo "started_at_utc=\${STARTED_AT}"
    echo "ended_at_utc=\${ended_at}"
    echo "exit_code=\${exit_code}"
    echo "root=\${ROOT}"
    echo "app_path=\${APP_PATH}"
    echo "expected_app_sha256=\${EXPECTED_APP_SHA256}"
    echo "expected_validator_sha256=\${EXPECTED_VALIDATOR_SHA256}"
    echo "expected_checker_sha256=\${EXPECTED_CHECKER_SHA256}"
    echo "login_item_app_path=\${LOGIN_ITEM_APP_PATH_AT_RUNNER_START:-\${LOGIN_ITEM_APP_PATH}}"
    echo "login_item_present_at_runner_start=\${LOGIN_ITEM_PRESENT_AT_RUNNER_START}"
    echo "login_item_app_sha256_at_runner_start=\${LOGIN_ITEM_APP_SHA256_AT_RUNNER_START}"
    echo "running_codexbar_process_count_at_runner_start=\${RUNNING_CODEXBAR_PROCESS_COUNT_AT_RUNNER_START}"
    if [[ -n "\${RUNNING_CODEXBAR_PROCESSES_AT_RUNNER_START}" ]]; then
      printf '%s\n' "\${RUNNING_CODEXBAR_PROCESSES_AT_RUNNER_START}" |
        sed 's/^/running_codexbar_process_at_runner_start=/'
    fi
    echo "artifact_root=\${ARTIFACT_ROOT}"
    echo "latest_artifact_dir=\$(latest_artifact_dir)"
    echo "validated_artifact_dir=\${VALIDATED_ARTIFACT_DIR}"
    echo "checker_exit_code=\${CHECKER_EXIT_CODE}"
  } >"\${SUMMARY_PATH}"
}

guard_clean_login_context() {
  LOGIN_ITEM_PRESENT_AT_RUNNER_START="\$(codexbar_login_item_present)"
  RUNNING_CODEXBAR_PROCESS_COUNT_AT_RUNNER_START="\$(count_running_codexbar_processes)"

  if [[ "\${LOGIN_ITEM_PRESENT_AT_RUNNER_START}" == "true" ]]; then
    LOGIN_ITEM_APP_PATH_AT_RUNNER_START="\$(codexbar_login_item_path)"
    if [[ -z "\${LOGIN_ITEM_APP_PATH_AT_RUNNER_START}" ]]; then
      LOGIN_ITEM_APP_PATH_AT_RUNNER_START="\${LOGIN_ITEM_APP_PATH}"
    fi
    if [[ ! -x "\${LOGIN_ITEM_APP_PATH_AT_RUNNER_START}/Contents/MacOS/CodexBar" ]]; then
      echo "ERROR: CodexBar Login Item is present, but executable is missing: \${LOGIN_ITEM_APP_PATH_AT_RUNNER_START}/Contents/MacOS/CodexBar" >&2
      exit 1
    fi
    LOGIN_ITEM_APP_SHA256_AT_RUNNER_START="\$(bundle_binary_sha256 "\${LOGIN_ITEM_APP_PATH_AT_RUNNER_START}")"
    echo "ERROR: CodexBar Login Item is present; refusing to collect contested first-launch proof." >&2
    exit 1
  fi

  if [[ "\${RUNNING_CODEXBAR_PROCESS_COUNT_AT_RUNNER_START}" != "0" ]]; then
    RUNNING_CODEXBAR_PROCESSES_AT_RUNNER_START="\$(running_codexbar_processes)"
    echo "ERROR: CodexBar is already running at runner start; refusing to collect invalid first-launch proof." >&2
    exit 1
  fi
}

cleanup() {
  launchctl bootout "gui/\$(id -u)" "\${PLIST_PATH}" >/dev/null 2>&1 || true
  rm -f "\${PLIST_PATH}"
}
on_exit() {
  local exit_code="\$?"
  write_summary "\${exit_code}" || true
  cleanup
  exit "\${exit_code}"
}
trap on_exit EXIT

mkdir -p "\${LOG_DIR}"
{
  echo "started_at_utc=\${STARTED_AT}"
  echo "root=\${ROOT}"
  echo "app_path=\${APP_PATH}"
  echo "expected_app_sha256=\${EXPECTED_APP_SHA256}"
  echo "expected_validator_sha256=\${EXPECTED_VALIDATOR_SHA256}"
  echo "expected_checker_sha256=\${EXPECTED_CHECKER_SHA256}"
  echo "login_item_app_path=\${LOGIN_ITEM_APP_PATH}"
  echo "login_item_present_at_runner_start="
  echo "login_item_app_sha256_at_runner_start="
  echo "running_codexbar_process_count_at_runner_start="
  echo "artifact_root=\${ARTIFACT_ROOT}"
  echo "validated_artifact_dir="
  echo "checker_exit_code="
} >"\${SUMMARY_PATH}"

guard_clean_login_context

cd "\${ROOT}"
CODEXBAR_APP_PATH="\${APP_PATH}" \\
CODEXBAR_COLD_START_ARTIFACT_DIR="\${ARTIFACT_ROOT}" \\
CODEXBAR_PYTHON_BIN="\${PYTHON_BIN}" \\
"\${ROOT}/Scripts/validate_cold_start_menu.sh"

LATEST_ARTIFACT_DIR="\$(latest_artifact_dir)"
if [[ -z "\${LATEST_ARTIFACT_DIR}" ]]; then
  echo "ERROR: Validator did not produce a cold-start artifact directory." >&2
  exit 1
fi
VALIDATED_ARTIFACT_DIR="\${LATEST_ARTIFACT_DIR}"

set +e
CODEXBAR_EXPECTED_APP_PATH="\${APP_PATH}" \\
CODEXBAR_EXPECTED_APP_SHA256="\${EXPECTED_APP_SHA256}" \\
CODEXBAR_EXPECTED_VALIDATOR_SHA256="\${EXPECTED_VALIDATOR_SHA256}" \\
CODEXBAR_EXPECTED_CHECKER_SHA256="\${EXPECTED_CHECKER_SHA256}" \\
"\${ROOT}/Scripts/check_cold_start_validation_result.sh" "\${LATEST_ARTIFACT_DIR}"
CHECKER_EXIT_CODE="\$?"
set -e
if [[ "\${CHECKER_EXIT_CODE}" != "0" ]]; then
  exit "\${CHECKER_EXIT_CODE}"
fi
EOF
  chmod +x "${RUNNER_PATH}"

  cat >"${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.stderr.log</string>
</dict>
</plist>
EOF

  plutil -lint "${PLIST_PATH}" >/dev/null
  echo "Installed one-shot LaunchAgent: ${PLIST_PATH}"
  echo "It will run at next login, then unload and remove itself."
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
  rm -f "${PLIST_PATH}" "${RUNNER_PATH}"
  echo "Removed LaunchAgent and runner for ${LABEL}."
}

show_status() {
  local boot_epoch=""
  local latest_artifact_dir=""
  local latest_boot_metadata=""
  local latest_boot_time=""
  local latest_candidate=""
  local current_uptime_seconds=""
  local summary_validated_artifact=""
  local summary_checker_exit_code=""
  local summary_exit_code=""
  local proof_state="post_boot_run_pending"

  boot_epoch="$(current_boot_epoch)"
  current_uptime_seconds=$(( $(now_epoch) - boot_epoch ))
  echo "current_boot_epoch=${boot_epoch}"
  echo "current_boot_time_utc=$(epoch_to_utc_iso "${boot_epoch}")"
  echo "current_uptime_seconds=${current_uptime_seconds}"
  echo "post_boot_max_uptime_seconds=${POST_BOOT_MAX_UPTIME_SECONDS}"
  if [[ "${current_uptime_seconds}" -le "${POST_BOOT_MAX_UPTIME_SECONDS}" ]]; then
    echo "current_post_boot_window_open=true"
  else
    echo "current_post_boot_window_open=false"
    echo "WARNING: This boot session is outside the first-after-boot validation window."
    echo "Reboot before the next login if you need first-after-boot proof instead of a logout/login proof."
  fi
  echo "launchd_summary_path=${SUMMARY_PATH}"
  echo "login_item_snapshot_path=${LOGIN_ITEM_SNAPSHOT_PATH}"
  if [[ -f "${SUMMARY_PATH}" ]]; then
    echo "launchd_summary_present=true"
    summary_exit_code="$(artifact_metadata_value exit_code "${SUMMARY_PATH}")"
    summary_validated_artifact="$(artifact_metadata_value validated_artifact_dir "${SUMMARY_PATH}")"
    summary_checker_exit_code="$(artifact_metadata_value checker_exit_code "${SUMMARY_PATH}")"
    echo "launchd_summary_exit_code=${summary_exit_code}"
    echo "launchd_summary_validated_artifact_dir=${summary_validated_artifact}"
    echo "launchd_summary_checker_exit_code=${summary_checker_exit_code}"
    if [[ "${summary_exit_code}" == "0" && "${summary_checker_exit_code}" == "0" && -n "${summary_validated_artifact}" ]]; then
      proof_state="launchd_summary_passed"
    else
      proof_state="launchd_summary_failed_or_incomplete"
    fi
  else
    echo "launchd_summary_present=false"
    if [[ "${current_uptime_seconds}" -gt "${POST_BOOT_MAX_UPTIME_SECONDS}" ]]; then
      proof_state="post_boot_window_expired_reboot_required"
    fi
  fi
  latest_artifact_dir="$(status_latest_artifact_dir)"
  echo "latest_artifact_dir=${latest_artifact_dir}"
  if [[ -n "${latest_artifact_dir}" ]]; then
    latest_boot_metadata="${latest_artifact_dir}/boot-session-metadata.txt"
    if [[ -f "${latest_boot_metadata}" ]]; then
      echo "latest_artifact_has_boot_metadata=true"
    else
      echo "latest_artifact_has_boot_metadata=false"
    fi
    latest_boot_time="$(artifact_metadata_value boot_time_utc "${latest_boot_metadata}")"
    latest_candidate="$(artifact_metadata_value post_boot_first_launch_candidate "${latest_boot_metadata}")"
    echo "latest_artifact_boot_time_utc=${latest_boot_time}"
    echo "latest_artifact_first_launch_candidate=${latest_candidate}"
    if [[ -n "${latest_boot_time}" && "${latest_boot_time}" != "$(epoch_to_utc_iso "${boot_epoch}")" ]]; then
      echo "latest_artifact_matches_current_boot=false"
    elif [[ -n "${latest_boot_time}" ]]; then
      echo "latest_artifact_matches_current_boot=true"
    fi
  fi

	  if [[ -f "${PLIST_PATH}" ]]; then
	    local current_app_sha256=""
	    local login_item_app_sha256=""
	    local login_item_app_path=""
	    local login_item_names=""
	    local login_item_present=""
    local installed_expected_sha256=""
    local current_checker_sha256=""
    local current_validator_sha256=""
    local installed_expected_checker_sha256=""
    local installed_expected_validator_sha256=""
    local running_count=""
    local setup_invalid=false

    echo "installed ${PLIST_PATH}"
    plutil -lint "${PLIST_PATH}"
	    login_item_names="$(normalized_login_items | paste -sd ',' -)"
	    echo "login_items=${login_item_names}"
	    login_item_present="$(codexbar_login_item_present)"
	    echo "codexbar_login_item_present=${login_item_present}"
	    if [[ "${login_item_present}" == "true" ]]; then
	      login_item_app_path="$(codexbar_login_item_path)"
	      if [[ -z "${login_item_app_path}" ]]; then
	        login_item_app_path="${LOGIN_ITEM_APP_PATH}"
	      fi
	      echo "WARNING: A normal CodexBar Login Item may launch before the cold-start validator."
	      echo "Disable that login item before rebooting if you need uncontested first-launch proof."
	      setup_invalid=true
	      echo "login_item_app_path=${login_item_app_path}"
	      if [[ -x "${login_item_app_path}/Contents/MacOS/CodexBar" ]]; then
	        login_item_app_sha256="$(bundle_binary_sha256 "${login_item_app_path}")"
	        echo "login_item_app_sha256=${login_item_app_sha256}"
	      else
	        echo "WARNING: Login item comparison app executable is missing: ${login_item_app_path}/Contents/MacOS/CodexBar"
	      fi
	    else
	      echo "login_item_app_path=${LOGIN_ITEM_APP_PATH}"
	    fi
    if [[ -f "${RUNNER_PATH}" ]]; then
      echo "runner ${RUNNER_PATH}"
      if runner_contains_final_checker; then
        echo "runner_final_checker_present=true"
      else
        echo "runner_final_checker_present=false"
        echo "WARNING: LaunchAgent runner is stale; run '$0 install' again before rebooting."
        setup_invalid=true
      fi
    else
      echo "WARNING: LaunchAgent plist exists but runner is missing: ${RUNNER_PATH}"
      echo "Run '$0 install' again before rebooting."
      setup_invalid=true
    fi
    if [[ -x "${APP_PATH}/Contents/MacOS/CodexBar" ]]; then
      current_app_sha256="$(app_binary_sha256)"
      echo "current_app_sha256=${current_app_sha256}"
      installed_expected_sha256="$(runner_expected_app_sha256)"
      if [[ -n "${installed_expected_sha256}" ]]; then
        echo "installed_expected_app_sha256=${installed_expected_sha256}"
        if [[ "${installed_expected_sha256}" != "${current_app_sha256}" ]]; then
          echo "WARNING: installed LaunchAgent expected hash does not match current app binary."
          echo "Run '$0 install' again before rebooting if the package changed."
          setup_invalid=true
        fi
      else
        echo "WARNING: installed runner is missing expected app hash."
        echo "Run '$0 install' again before rebooting."
        setup_invalid=true
      fi
      current_validator_sha256="$(script_sha256 "${ROOT}/Scripts/validate_cold_start_menu.sh")"
      current_checker_sha256="$(script_sha256 "${ROOT}/Scripts/check_cold_start_validation_result.sh")"
      echo "current_validator_sha256=${current_validator_sha256}"
      echo "current_checker_sha256=${current_checker_sha256}"
      installed_expected_validator_sha256="$(runner_expected_validator_sha256)"
      installed_expected_checker_sha256="$(runner_expected_checker_sha256)"
      echo "installed_expected_validator_sha256=${installed_expected_validator_sha256}"
      echo "installed_expected_checker_sha256=${installed_expected_checker_sha256}"
      if [[ "${installed_expected_validator_sha256}" != "${current_validator_sha256}" ||
        "${installed_expected_checker_sha256}" != "${current_checker_sha256}" ]]; then
        echo "WARNING: installed LaunchAgent expected validation script hash does not match current scripts."
        echo "Run '$0 install' again before rebooting if the validation scripts changed."
        setup_invalid=true
      fi
    else
      echo "WARNING: App executable missing: ${APP_PATH}/Contents/MacOS/CodexBar"
      setup_invalid=true
    fi
    if [[ "${login_item_present}" == "true" && -n "${current_app_sha256}" && -n "${login_item_app_sha256:-}" &&
      "${login_item_app_sha256}" != "${current_app_sha256}" ]]; then
      echo "WARNING: Normal Login Item app binary differs from the validation target."
      echo "A next-login race would validate the wrong installed app unless the Login Item is disabled or updated."
      setup_invalid=true
    fi
    running_count="$(count_running_codexbar_processes)"
    echo "running_codexbar_process_count=${running_count}"
    if [[ "${running_count}" != "0" ]]; then
      running_codexbar_processes | sed 's/^/running_codexbar_process=/'
      echo "WARNING: CodexBar is already running; this invalidates immediate first-launch proof until the next clean boot/login."
      setup_invalid=true
    fi
    if [[ "${setup_invalid}" == "true" && (
      "${proof_state}" == "post_boot_run_pending" ||
        "${proof_state}" == "post_boot_window_expired_reboot_required"
    ) ]]; then
      proof_state="setup_incomplete"
    fi
  else
    echo "not installed"
    if [[ "${proof_state}" == "post_boot_run_pending" ||
      "${proof_state}" == "post_boot_window_expired_reboot_required" ]]; then
      proof_state="setup_incomplete"
    fi
  fi
  echo "proof_state=${proof_state}"
  if [[ -f "${LOG_DIR}/launchd.stdout.log" || -f "${LOG_DIR}/launchd.stderr.log" ]]; then
    echo "logs ${LOG_DIR}"
  fi
  if [[ -f "${SUMMARY_PATH}" ]]; then
    echo "summary ${SUMMARY_PATH}"
    cat "${SUMMARY_PATH}"
  fi
}

preflight() {
  local current_app_sha256=""
  local login_item_app_sha256=""
  local login_item_app_path=""
  local login_item_present=""
  local installed_expected_sha256=""
  local current_checker_sha256=""
  local current_validator_sha256=""
  local installed_expected_checker_sha256=""
  local installed_expected_validator_sha256=""
  local python_bin=""
  local visual_readiness_python_metadata=""
  local running_count=""
  local failures=0

  ensure_paths

  if [[ ! -f "${PLIST_PATH}" ]]; then
    fail_preflight "LaunchAgent is not installed: ${PLIST_PATH}" || failures=$((failures + 1))
  elif ! plutil -lint "${PLIST_PATH}" >/dev/null; then
    fail_preflight "LaunchAgent plist is invalid: ${PLIST_PATH}" || failures=$((failures + 1))
  fi

  if [[ ! -f "${RUNNER_PATH}" ]]; then
    fail_preflight "LaunchAgent runner is missing: ${RUNNER_PATH}" || failures=$((failures + 1))
  elif ! runner_contains_final_checker; then
    fail_preflight "LaunchAgent runner is stale; reinstall to include final artifact checker" || failures=$((failures + 1))
  fi

  current_app_sha256="$(app_binary_sha256)"
  python_bin="$(resolve_visual_python || true)"
  if [[ -z "${python_bin}" ]]; then
    fail_preflight "Python/Pillow visual-readiness dependency is unavailable" || failures=$((failures + 1))
  fi
  visual_readiness_python_metadata="$(python_visual_readiness_metadata "${python_bin}" || true)"
  if [[ -z "${visual_readiness_python_metadata}" ]]; then
    fail_preflight "Python/Pillow visual-readiness dependency is unavailable" || failures=$((failures + 1))
  fi
  installed_expected_sha256="$(runner_expected_app_sha256)"
  if [[ -z "${installed_expected_sha256}" ]]; then
    fail_preflight "Installed runner is missing EXPECTED_APP_SHA256" || failures=$((failures + 1))
  elif [[ "${installed_expected_sha256}" != "${current_app_sha256}" ]]; then
    fail_preflight "Installed expected app hash does not match current validation target" || failures=$((failures + 1))
  fi

  current_validator_sha256="$(script_sha256 "${ROOT}/Scripts/validate_cold_start_menu.sh")"
  current_checker_sha256="$(script_sha256 "${ROOT}/Scripts/check_cold_start_validation_result.sh")"
  installed_expected_validator_sha256="$(runner_expected_validator_sha256)"
  installed_expected_checker_sha256="$(runner_expected_checker_sha256)"
  if [[ -z "${installed_expected_validator_sha256}" || -z "${installed_expected_checker_sha256}" ]]; then
    fail_preflight "Installed runner is missing validation script hashes" || failures=$((failures + 1))
  elif [[ "${installed_expected_validator_sha256}" != "${current_validator_sha256}" ||
    "${installed_expected_checker_sha256}" != "${current_checker_sha256}" ]]; then
    fail_preflight "Installed expected validation script hash does not match current scripts" || failures=$((failures + 1))
  fi

  login_item_present="$(codexbar_login_item_present)"
  if [[ "${login_item_present}" == "true" ]]; then
    login_item_app_path="$(codexbar_login_item_path)"
    if [[ -z "${login_item_app_path}" ]]; then
      login_item_app_path="${LOGIN_ITEM_APP_PATH}"
    fi
    fail_preflight "CodexBar Login Item is present; uncontested first-launch proof requires it to be disabled" || failures=$((failures + 1))
    if [[ ! -x "${login_item_app_path}/Contents/MacOS/CodexBar" ]]; then
      fail_preflight "CodexBar Login Item is present, but comparison app executable is missing: ${login_item_app_path}/Contents/MacOS/CodexBar" || failures=$((failures + 1))
    else
      login_item_app_sha256="$(bundle_binary_sha256 "${login_item_app_path}")"
      if [[ "${login_item_app_sha256}" != "${current_app_sha256}" ]]; then
        fail_preflight "CodexBar Login Item app binary differs from the validation target" || failures=$((failures + 1))
      fi
    fi
  else
    login_item_app_path="${LOGIN_ITEM_APP_PATH}"
  fi

  running_count="$(count_running_codexbar_processes)"
  if [[ "${running_count}" != "0" ]]; then
    fail_preflight "CodexBar is already running; first-launch proof requires no preexisting process" || failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    cat >&2 <<EOF
Preflight failed for next-boot cold-start validation.
app_path=${APP_PATH}
current_app_sha256=${current_app_sha256}
installed_expected_app_sha256=${installed_expected_sha256}
current_validator_sha256=${current_validator_sha256}
installed_expected_validator_sha256=${installed_expected_validator_sha256}
current_checker_sha256=${current_checker_sha256}
installed_expected_checker_sha256=${installed_expected_checker_sha256}
${visual_readiness_python_metadata}
codexbar_login_item_present=${login_item_present}
login_item_app_path=${login_item_app_path}
login_item_app_sha256=${login_item_app_sha256}
running_codexbar_process_count=${running_count}
EOF
    running_codexbar_processes | sed 's/^/running_codexbar_process=/' >&2
    return 1
  fi

  cat <<EOF
OK: next-boot cold-start validation preflight passed.
app_path=${APP_PATH}
current_app_sha256=${current_app_sha256}
installed_expected_app_sha256=${installed_expected_sha256}
current_validator_sha256=${current_validator_sha256}
installed_expected_validator_sha256=${installed_expected_validator_sha256}
current_checker_sha256=${current_checker_sha256}
installed_expected_checker_sha256=${installed_expected_checker_sha256}
${visual_readiness_python_metadata}
codexbar_login_item_present=${login_item_present}
login_item_app_path=${login_item_app_path}
login_item_app_sha256=${login_item_app_sha256}
running_codexbar_process_count=${running_count}
EOF
}

check_result() {
  ensure_paths
  local expected_app_sha256
  local expected_checker_sha256
  local expected_validator_sha256
  local validated_artifact_dir
  local app_bundle_metadata
  if [[ ! -f "${SUMMARY_PATH}" ]]; then
    echo "ERROR: LaunchAgent summary is missing: ${SUMMARY_PATH}" >&2
    echo "The one-shot cold-start validator has not run in this boot session yet." >&2
    echo "Reboot, log in, then run '$0 check-result' again." >&2
    return 1
  fi
  validated_artifact_dir="$(artifact_metadata_value validated_artifact_dir "${SUMMARY_PATH}")"
  if [[ -z "${validated_artifact_dir}" ]]; then
    echo "ERROR: LaunchAgent summary does not name a validated artifact directory: ${SUMMARY_PATH}" >&2
    cat "${SUMMARY_PATH}" >&2
    return 1
  fi
  app_bundle_metadata="${validated_artifact_dir}/app-bundle-metadata.txt"
  expected_app_sha256="$(artifact_metadata_value app_binary_sha256 "${app_bundle_metadata}")"
  expected_validator_sha256="$(artifact_metadata_value validator_script_sha256 "${app_bundle_metadata}")"
  expected_checker_sha256="$(artifact_metadata_value checker_script_sha256 "${app_bundle_metadata}")"
  CODEXBAR_COLD_START_ARTIFACT_DIR="${ARTIFACT_ROOT}" \
  CODEXBAR_EXPECTED_APP_PATH="${APP_PATH}" \
  CODEXBAR_EXPECTED_APP_SHA256="${expected_app_sha256}" \
  CODEXBAR_EXPECTED_VALIDATOR_SHA256="${expected_validator_sha256}" \
  CODEXBAR_EXPECTED_CHECKER_SHA256="${expected_checker_sha256}" \
    "${ROOT}/Scripts/check_cold_start_validation_result.sh" "${validated_artifact_dir}"
}

case "${1:-}" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  status)
    show_status
    ;;
  preflight)
    preflight
    ;;
  check-result)
    check_result
    ;;
  snapshot-login-item)
    save_login_item_snapshot
    ;;
  disable-login-item)
    disable_login_item_for_validation
    ;;
  restore-login-item)
    restore_login_item_snapshot
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

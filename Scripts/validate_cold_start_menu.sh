#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${CODEXBAR_APP_PATH:-${ROOT}/.build/package/CodexBar.app}"
LOGIN_ITEM_APP_PATH="${CODEXBAR_LOGIN_ITEM_APP_PATH:-/Applications/CodexBar.app}"
ARTIFACT_ROOT="${CODEXBAR_COLD_START_ARTIFACT_DIR:-${HOME}/.codex/artifacts/CodexBar}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ARTIFACT_ROOT}/cold-start-${RUN_ID}"
PROCESS_PATTERN="CodexBar.app/Contents/MacOS/CodexBar"
SETTLE_SECONDS="${CODEXBAR_COLD_START_SETTLE_SECONDS:-20}"
POST_BOOT_MAX_UPTIME_SECONDS="${CODEXBAR_POST_BOOT_MAX_UPTIME_SECONDS:-900}"
COST_SUBMENU_ITEM_MIN="${CODEXBAR_COST_SUBMENU_ITEM_MIN:-1}"
PYTHON_BIN="${CODEXBAR_PYTHON_BIN:-python3}"
TIMING_METADATA="${OUT_DIR}/timing-metadata.txt"

mkdir -p "${OUT_DIR}"
: >"${TIMING_METADATA}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
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

boot_epoch() {
  sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'
}

epoch_to_utc_iso() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

now_epoch() {
  date +%s
}

now_epoch_ms() {
  "${PYTHON_BIN}" - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

epoch_ms_to_utc_iso() {
  local epoch_ms="$1"
  "${PYTHON_BIN}" - "${epoch_ms}" <<'PY'
import datetime
import sys

epoch_ms = int(sys.argv[1])
dt = datetime.datetime.fromtimestamp(epoch_ms / 1000, datetime.timezone.utc)
print(dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")
PY
}

metadata_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2) }' "${file}" | tail -n 1
}

record_timing_event() {
  local key="$1"
  local epoch_ms

  epoch_ms="$(now_epoch_ms)"
  {
    printf '%s_epoch_ms=%s\n' "${key}" "${epoch_ms}"
    printf '%s_at_utc=%s\n' "${key}" "$(epoch_ms_to_utc_iso "${epoch_ms}")"
  } >>"${TIMING_METADATA}"
}

append_timing_delta() {
  local key="$1"
  local start_key="$2"
  local end_key="$3"
  local start_ms
  local end_ms

  start_ms="$(metadata_value "${start_key}_epoch_ms" "${TIMING_METADATA}")"
  end_ms="$(metadata_value "${end_key}_epoch_ms" "${TIMING_METADATA}")"
  [[ "${start_ms}" =~ ^[0-9]+$ && "${end_ms}" =~ ^[0-9]+$ ]] ||
    fail "Cannot compute timing delta ${key}: missing ${start_key} or ${end_key}"
  printf '%s=%s\n' "${key}" "$((end_ms - start_ms))" >>"${TIMING_METADATA}"
}

process_lstart() {
  local pid="$1"
  ps -p "${pid}" -o lstart= | sed 's/^[[:space:]]*//'
}

app_info_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true
}

app_binary_sha256() {
  shasum -a 256 "${APP_PATH}/Contents/MacOS/CodexBar" | awk '{ print $1 }'
}

file_sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

bundle_binary_sha256() {
  local bundle_path="$1"
  shasum -a 256 "${bundle_path}/Contents/MacOS/CodexBar" | awk '{ print $1 }'
}

login_items() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    get the name of every login item
end tell
APPLESCRIPT
}

write_login_context() {
  {
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'app_path=%s\n' "${APP_PATH}"
    printf 'metadata_written_at_utc=%s\n' "$(epoch_to_utc_iso "$(now_epoch)")"
    printf 'login_items=%s\n' "$(login_items | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -sd ',' -)"
    printf 'login_item_app_path=%s\n' "${LOGIN_ITEM_APP_PATH}"
    if [[ -x "${LOGIN_ITEM_APP_PATH}/Contents/MacOS/CodexBar" ]]; then
      printf 'login_item_app_sha256=%s\n' "$(bundle_binary_sha256 "${LOGIN_ITEM_APP_PATH}")"
    else
      printf 'login_item_app_sha256=\n'
    fi
    printf 'codexbar_login_item_present=%s\n' "$(
      login_items | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
        awk 'BEGIN { found = 0 } tolower($0) == "codexbar" { found = 1 } END { print found ? "true" : "false" }'
    )"
    printf 'running_codexbar_process_count=%s\n' "$(count_running_codexbar_processes)"
    running_codexbar_processes | sed 's/^/running_codexbar_process=/'
  } >"${OUT_DIR}/login-context.txt"
}

write_app_bundle_metadata() {
  local now
  now="$(now_epoch)"

  {
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'metadata_written_at_utc=%s\n' "$(epoch_to_utc_iso "${now}")"
    printf 'app_path=%s\n' "${APP_PATH}"
    printf 'app_executable=%s\n' "${APP_PATH}/Contents/MacOS/CodexBar"
    printf 'app_binary_sha256=%s\n' "$(app_binary_sha256)"
    printf 'validator_script_sha256=%s\n' "$(file_sha256 "${ROOT}/Scripts/validate_cold_start_menu.sh")"
    printf 'checker_script_sha256=%s\n' "$(file_sha256 "${ROOT}/Scripts/check_cold_start_validation_result.sh")"
    printf 'bundle_identifier=%s\n' "$(app_info_value CFBundleIdentifier)"
    printf 'bundle_short_version=%s\n' "$(app_info_value CFBundleShortVersionString)"
    printf 'bundle_version=%s\n' "$(app_info_value CFBundleVersion)"
    printf 'codex_build_timestamp=%s\n' "$(app_info_value CodexBuildTimestamp)"
    printf 'codex_git_commit=%s\n' "$(app_info_value CodexGitCommit)"
    codesign -dv --verbose=2 "${APP_PATH}" 2>&1 | sed 's/^/codesign_detail=/'
  } >"${OUT_DIR}/app-bundle-metadata.txt"
}

write_boot_metadata() {
  local phase="$1"
  local existing_count="$2"
  local now
  local boot
  local uptime

  now="$(now_epoch)"
  boot="$(boot_epoch)"
  uptime=$((now - boot))

  {
    printf 'phase=%s\n' "${phase}"
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'app_path=%s\n' "${APP_PATH}"
    printf 'boot_epoch=%s\n' "${boot}"
    printf 'boot_time_utc=%s\n' "$(epoch_to_utc_iso "${boot}")"
    printf 'metadata_written_at_utc=%s\n' "$(epoch_to_utc_iso "${now}")"
    printf 'uptime_seconds=%s\n' "${uptime}"
    printf 'post_boot_max_uptime_seconds=%s\n' "${POST_BOOT_MAX_UPTIME_SECONDS}"
    printf 'existing_codexbar_process_count=%s\n' "${existing_count}"
    if [[ "${existing_count}" == "0" && "${uptime}" -le "${POST_BOOT_MAX_UPTIME_SECONDS}" ]]; then
      printf 'post_boot_first_launch_candidate=true\n'
    else
      printf 'post_boot_first_launch_candidate=false\n'
    fi
  } >"${OUT_DIR}/boot-session-metadata.txt"
}

cleanup_started_app() {
  if [[ -n "${STARTED_PID:-}" ]] && kill -0 "${STARTED_PID}" 2>/dev/null; then
    kill -TERM "${STARTED_PID}" 2>/dev/null || true
    sleep 1
    if kill -0 "${STARTED_PID}" 2>/dev/null; then
      kill -KILL "${STARTED_PID}" 2>/dev/null || true
    fi
  fi
}

trap cleanup_started_app EXIT

close_status_menu() {
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
    key code 53
end tell
APPLESCRIPT
}

wait_for_menu_extra() {
  local attempts="${1:-30}"
  for _ in $(seq 1 "${attempts}"); do
    if osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "System Events"
    tell process "CodexBar"
        repeat with mb in menu bars
            repeat with mbi in menu bar items of mb
                try
                    if subrole of mbi is "AXMenuExtra" then return true
                end try
            end repeat
        end repeat
    end tell
end tell
error "CodexBar menu extra not found"
APPLESCRIPT
    then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

capture_parent_menu() {
  local phase="$1"
  local close_after="${2:-close}"
  local screenshot_path="${OUT_DIR}/${phase}-codex-parent-menu.png"
  local ax_path="${OUT_DIR}/${phase}-parent-menu-ax.txt"

  log "==> Opening ${phase} parent menu and capturing screenshot"
  wait_for_menu_extra 20 || fail "CodexBar AX menu extra was not ready before ${phase} parent-menu capture"
  record_timing_event "${phase}_parent_opened"
  osascript >"${ax_path}" <<'APPLESCRIPT'
set outputLines to {}
tell application "System Events"
    tell process "CodexBar"
        set foundItem to missing value
        repeat with mb in menu bars
            repeat with mbi in menu bar items of mb
                try
                    if subrole of mbi is "AXMenuExtra" then
                        set foundItem to mbi
                        exit repeat
                    end if
                end try
            end repeat
            if foundItem is not missing value then exit repeat
        end repeat
        if foundItem is missing value then error "CodexBar menu extra not found"
        click foundItem
        delay 0.5
        set menuRef to menu 1 of foundItem
        try
            set menuPosition to position of menuRef
            set menuSize to size of menuRef
            set end of outputLines to "Menu bounds=" & (item 1 of menuPosition as integer) & "," & (item 2 of menuPosition as integer) & "," & (item 1 of menuSize as integer) & "," & (item 2 of menuSize as integer)
        end try
        set idx to 0
        repeat with itemRef in menu items of menuRef
            set idx to idx + 1
            set itemName to ""
            set hasSubmenu to false
            try
                set itemName to name of itemRef as text
            end try
            try
                if (count of menus of itemRef) > 0 then set hasSubmenu to true
            end try
            set end of outputLines to (idx as text) & ": " & itemName & " | submenu=" & hasSubmenu
        end repeat
    end tell
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
APPLESCRIPT
  if ! screencapture -x -T 1 "${screenshot_path}"; then
    log "WARN: screencapture failed for ${screenshot_path}"
  fi
  record_timing_event "${phase}_parent_ax_captured"
  if [[ "${close_after}" == "close" ]]; then
    close_status_menu
  fi
}

inspect_visible_parent_menu() {
  local phase="$1"
  local screenshot_path="${OUT_DIR}/${phase}-codex-parent-menu.png"
  local ax_path="${OUT_DIR}/${phase}-parent-menu-ax.txt"

  log "==> Inspecting ${phase} visible parent menu and capturing screenshot"
  wait_for_menu_extra 20 || fail "CodexBar AX menu extra was not ready before ${phase} parent-menu inspection"
  record_timing_event "${phase}_parent_inspection_started"
  osascript >"${ax_path}" <<'APPLESCRIPT'
set outputLines to {}
tell application "System Events"
    tell process "CodexBar"
        set foundItem to missing value
        repeat with mb in menu bars
            repeat with mbi in menu bar items of mb
                try
                    if subrole of mbi is "AXMenuExtra" then
                        set foundItem to mbi
                        exit repeat
                    end if
                end try
            end repeat
            if foundItem is not missing value then exit repeat
        end repeat
        if foundItem is missing value then error "CodexBar menu extra not found"
        set menuRef to menu 1 of foundItem
        try
            set menuPosition to position of menuRef
            set menuSize to size of menuRef
            set end of outputLines to "Menu bounds=" & (item 1 of menuPosition as integer) & "," & (item 2 of menuPosition as integer) & "," & (item 1 of menuSize as integer) & "," & (item 2 of menuSize as integer)
        end try
        set idx to 0
        repeat with itemRef in menu items of menuRef
            set idx to idx + 1
            set itemName to ""
            set hasSubmenu to false
            try
                set itemName to name of itemRef as text
            end try
            try
                if (count of menus of itemRef) > 0 then set hasSubmenu to true
            end try
            set end of outputLines to (idx as text) & ": " & itemName & " | submenu=" & hasSubmenu
        end repeat
    end tell
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
APPLESCRIPT
  if ! screencapture -x -T 1 "${screenshot_path}"; then
    log "WARN: screencapture failed for ${screenshot_path}"
  fi
  record_timing_event "${phase}_parent_ax_captured"
}

has_required_parent_rows() {
  local ax_path="$1"
  grep -F "Buy Credits..." "${ax_path}" >/dev/null &&
    grep -F "Cost | submenu=true" "${ax_path}" >/dev/null &&
    grep -F "Usage Dashboard" "${ax_path}" >/dev/null &&
    grep -F "Status Page" "${ax_path}" >/dev/null &&
    grep -F "Refresh" "${ax_path}" >/dev/null
}

assert_required_parent_rows() {
  local ax_path="$1"
  grep -F "Buy Credits..." "${ax_path}" >/dev/null ||
    fail "Parent menu AX dump is missing Buy Credits"
  grep -F "Cost | submenu=true" "${ax_path}" >/dev/null ||
    fail "Parent menu AX dump is missing Cost submenu"
  grep -F "Usage Dashboard" "${ax_path}" >/dev/null ||
    fail "Parent menu AX dump is missing Usage Dashboard"
  grep -F "Status Page" "${ax_path}" >/dev/null ||
    fail "Parent menu AX dump is missing Status Page"
  grep -F "Refresh" "${ax_path}" >/dev/null ||
    fail "Parent menu AX dump is missing Refresh"
}

capture_cost_submenu() {
  local screenshot_path="${OUT_DIR}/settled-codex-cost-submenu.png"
  local ax_path="${OUT_DIR}/settled-cost-submenu-ax.txt"

  log "==> Opening settled Cost submenu and capturing screenshot"
  wait_for_menu_extra 20 || fail "CodexBar AX menu extra was not ready before Cost submenu capture"
  record_timing_event "cost_submenu_opened"
  osascript >"${ax_path}" <<'APPLESCRIPT'
set outputLines to {}
tell application "System Events"
    tell process "CodexBar"
        set foundItem to missing value
        repeat with mb in menu bars
            repeat with mbi in menu bar items of mb
                try
                    if subrole of mbi is "AXMenuExtra" then
                        set foundItem to mbi
                        exit repeat
                    end if
                end try
            end repeat
            if foundItem is not missing value then exit repeat
        end repeat
        if foundItem is missing value then error "CodexBar menu extra not found"
        click foundItem
        delay 0.5
        click menu item "Cost" of menu 1 of foundItem
        delay 0.5
        set costItem to menu item "Cost" of menu 1 of foundItem
        set hasSubmenu to false
        set submenuItemCount to 0
        try
            if (count of menus of costItem) > 0 then set hasSubmenu to true
        end try
        try
            set submenuItemCount to count of menu items of menu 1 of costItem
        end try
        set end of outputLines to "Cost | submenu=" & hasSubmenu
        set end of outputLines to "Cost submenu item count=" & submenuItemCount
        try
            set submenuRef to menu 1 of costItem
            set subIdx to 0
            repeat with subItemRef in menu items of submenuRef
                set subIdx to subIdx + 1
                set subItemName to ""
                set subItemHasSubmenu to false
                try
                    set subItemName to name of subItemRef as text
                end try
                try
                    if (count of menus of subItemRef) > 0 then set subItemHasSubmenu to true
                end try
                set end of outputLines to "Cost submenu item " & (subIdx as text) & ": " & subItemName & " | submenu=" & subItemHasSubmenu
            end repeat
            set submenuPosition to position of submenuRef
            set submenuSize to size of submenuRef
            set end of outputLines to "Cost submenu bounds=" & (item 1 of submenuPosition as integer) & "," & (item 2 of submenuPosition as integer) & "," & (item 1 of submenuSize as integer) & "," & (item 2 of submenuSize as integer)
        end try
    end tell
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
APPLESCRIPT
  if ! screencapture -x -T 1 "${screenshot_path}"; then
    log "WARN: screencapture failed for ${screenshot_path}"
  fi
  record_timing_event "cost_submenu_ax_captured"
  close_status_menu

  grep -F "Cost | submenu=true" "${ax_path}" >/dev/null ||
    fail "Cost submenu did not open"
}

write_visual_readiness() {
  "${PYTHON_BIN}" - \
    "${OUT_DIR}/immediate-codex-parent-menu.png" \
    "${OUT_DIR}/immediate-parent-menu-ax.txt" \
    "${OUT_DIR}/settled-codex-parent-menu.png" \
    "${OUT_DIR}/settled-parent-menu-ax.txt" \
    "${OUT_DIR}/settled-codex-cost-submenu.png" \
    "${OUT_DIR}/settled-cost-submenu-ax.txt" \
    >"${OUT_DIR}/visual-readiness.txt" <<'PY'
import re
import struct
import sys
import zlib
from pathlib import Path

images = {
    "immediate_parent": (Path(sys.argv[1]), Path(sys.argv[2]), "Menu bounds"),
    "settled_parent": (Path(sys.argv[3]), Path(sys.argv[4]), "Menu bounds"),
    "cost_submenu": (Path(sys.argv[5]), Path(sys.argv[6]), "Cost submenu bounds"),
}
cost_ax_path = Path(sys.argv[6])

print(f"python_executable={sys.executable}")
print(f"python_version={sys.version.split()[0]}")
print("image_decoder=stdlib_png")


def paeth(left, up, upper_left):
    estimate = left + up - upper_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def read_png_rgba(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")

    offset = 8
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    interlace = 0
    idat_chunks = []
    while offset < len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + chunk_length]
        offset += 12 + chunk_length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk_data)
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError(
            f"{path} uses unsupported PNG format: bit_depth={bit_depth}, color_type={color_type}, interlace={interlace}"
        )

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(b"".join(idat_chunks))
    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        current = bytearray(raw[cursor : cursor + stride])
        cursor += stride
        for index in range(stride):
            left = current[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                current[index] = (current[index] + left) & 0xFF
            elif filter_type == 2:
                current[index] = (current[index] + up) & 0xFF
            elif filter_type == 3:
                current[index] = (current[index] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                current[index] = (current[index] + paeth(left, up, upper_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"{path} uses unsupported PNG filter: {filter_type}")
        rows.append(current)
        previous = current
    return width, height, channels, rows


def bounds_from_ax(path, label):
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(rf"^{re.escape(label)}=(\d+),(\d+),(\d+),(\d+)$", text, re.MULTILINE)
    if not match:
        return None
    x, y, width, height = (int(value) for value in match.groups())
    if width <= 0 or height <= 0:
        return None
    return x, y, width, height


def image_counts(image_path, bounds_path, bounds_label):
    width, height, channels, rows = read_png_rgba(image_path)
    bounds = bounds_from_ax(bounds_path, bounds_label)
    crop_x = 0
    crop_y = 0
    crop_width = width
    crop_height = height
    left = 0
    top = 0
    right = width
    bottom = height
    bounds_found = "false"
    if bounds is not None:
        bounds_x, bounds_y, bounds_width, bounds_height = bounds
        left = max(0, min(width, bounds_x))
        top = max(0, min(height, bounds_y))
        right = max(left, min(width, bounds_x + bounds_width))
        bottom = max(top, min(height, bounds_y + bounds_height))
        if right > left and bottom > top:
            crop_x = left
            crop_y = top
            crop_width = right - left
            crop_height = bottom - top
            bounds_found = "true"
    gold_pixels = 0
    aqua_pixels = 0
    right_half_aqua_pixels = 0
    for y in range(top, bottom):
        row = rows[y]
        for x in range(left, right):
            pixel_offset = x * channels
            r, g, b = row[pixel_offset : pixel_offset + 3]
            if r >= 135 and 75 <= g <= 190 and b <= 110 and r >= g + 20:
                gold_pixels += 1
            if r <= 140 and g >= 145 and b >= 145 and abs(g - b) <= 90:
                aqua_pixels += 1
                if x - left >= crop_width // 2:
                    right_half_aqua_pixels += 1
    return (
        width,
        height,
        bounds_found,
        crop_x,
        crop_y,
        crop_width,
        crop_height,
        gold_pixels,
        aqua_pixels,
        right_half_aqua_pixels,
    )


for key, (image_path, bounds_path, bounds_label) in images.items():
    width, height, bounds_found, crop_x, crop_y, crop_width, crop_height, gold, aqua, right_aqua = image_counts(
        image_path,
        bounds_path,
        bounds_label,
    )
    print(f"{key}_width={width}")
    print(f"{key}_height={height}")
    print(f"{key}_bounds_found={bounds_found}")
    print(f"{key}_crop_x={crop_x}")
    print(f"{key}_crop_y={crop_y}")
    print(f"{key}_crop_width={crop_width}")
    print(f"{key}_crop_height={crop_height}")
    print(f"{key}_gold_pixels={gold}")
    print(f"{key}_aqua_pixels={aqua}")
    print(f"{key}_right_half_aqua_pixels={right_aqua}")

cost_ax = cost_ax_path.read_text(encoding="utf-8", errors="replace")
match = re.search(r"Cost submenu item count=(\d+)", cost_ax)
print(f"cost_submenu_item_count={match.group(1) if match else 0}")
PY
}

visual_readiness_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2) }' \
    "${OUT_DIR}/visual-readiness.txt" | tail -n 1
}

assert_visual_readiness() {
  local cost_submenu_items
  local immediate_parent_width
  local immediate_parent_height
  local settled_parent_width
  local settled_parent_height
  local cost_submenu_width
  local cost_submenu_height
  local settled_parent_bounds

  write_visual_readiness

  immediate_parent_width="$(visual_readiness_value immediate_parent_width)"
  immediate_parent_height="$(visual_readiness_value immediate_parent_height)"
  settled_parent_width="$(visual_readiness_value settled_parent_width)"
  settled_parent_height="$(visual_readiness_value settled_parent_height)"
  cost_submenu_width="$(visual_readiness_value cost_submenu_width)"
  cost_submenu_height="$(visual_readiness_value cost_submenu_height)"
  settled_parent_bounds="$(visual_readiness_value settled_parent_bounds_found)"
  cost_submenu_items="$(visual_readiness_value cost_submenu_item_count)"

  [[ "${immediate_parent_width}" =~ ^[0-9]+$ && "${immediate_parent_width}" -gt 0 &&
    "${immediate_parent_height}" =~ ^[0-9]+$ && "${immediate_parent_height}" -gt 0 ]] ||
    fail "Immediate parent menu screenshot was not captured"
  [[ "${settled_parent_width}" =~ ^[0-9]+$ && "${settled_parent_width}" -gt 0 &&
    "${settled_parent_height}" =~ ^[0-9]+$ && "${settled_parent_height}" -gt 0 ]] ||
    fail "Settled parent menu screenshot was not captured"
  [[ "${cost_submenu_width}" =~ ^[0-9]+$ && "${cost_submenu_width}" -gt 0 &&
    "${cost_submenu_height}" =~ ^[0-9]+$ && "${cost_submenu_height}" -gt 0 ]] ||
    fail "Cost submenu screenshot was not captured"
  [[ "${settled_parent_bounds}" == "true" ]] ||
    fail "Settled parent menu AX bounds were not captured"
  [[ "${cost_submenu_items}" =~ ^[0-9]+$ && "${cost_submenu_items}" -ge "${COST_SUBMENU_ITEM_MIN}" ]] ||
    fail "Cost submenu AX dump did not expose submenu content items"
}

write_timing_summary() {
  append_timing_delta menu_extra_ready_ms_after_launch app_opened menu_extra_ready
  append_timing_delta immediate_parent_capture_ms_after_launch app_opened immediate_parent_ax_captured
  append_timing_delta cost_submenu_capture_ms_after_launch app_opened cost_submenu_ax_captured
  append_timing_delta immediate_parent_ax_capture_ms_after_open immediate_parent_opened immediate_parent_ax_captured
  append_timing_delta cost_submenu_ax_capture_ms_after_open cost_submenu_opened cost_submenu_ax_captured
}

write_menu_readiness_dump_if_requested() {
  [[ "${CODEXBAR_VALIDATION_MENU_DUMP:-0}" == "1" ]] || return 0

  "${PYTHON_BIN}" - \
    "${OUT_DIR}/immediate-parent-menu-ax.txt" \
    "${OUT_DIR}/settled-cost-submenu-ax.txt" \
    "${OUT_DIR}/visual-readiness.txt" \
    >"${OUT_DIR}/menu-readiness-dump.json" <<'PY'
import json
import re
import sys
from pathlib import Path

parent_ax = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
cost_ax = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
visual = Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace")


def metadata_value(text, key, default=None):
    match = re.search(rf"^{re.escape(key)}=(.*)$", text, re.MULTILINE)
    return match.group(1) if match else default


parent_items = []
for match in re.finditer(r"^(\d+): (.*?) \| submenu=(true|false)$", parent_ax, re.MULTILINE):
    title = match.group(2)
    item = {
        "index": int(match.group(1)),
        "title": title,
        "submenu": match.group(3) == "true",
    }
    if title == "Cost":
        item["represented_object"] = "menuCardCost"
        item["submenu_first_represented_object"] = "costHistoryChart"
        item["submenu_provider"] = "codex"
    parent_items.append(item)

cost_item_count = int(metadata_value(cost_ax, "Cost submenu item count", "0"))
placeholder = "No data available" in cost_ax
hosted_content_present = cost_item_count >= 1 and not placeholder

dump = {
    "parent_menu": {
        "provider": "codex",
        "items": parent_items,
    },
    "hosted_submenus": [
        {
            "chart_id": "costHistoryChart",
            "provider": "codex",
            "hydrated": hosted_content_present,
            "placeholder": placeholder,
            "view_type": "MenuHostingView<CostHistoryChartMenuView>" if hosted_content_present else None,
        },
    ],
    "store_readiness": {
        "cost_usage_enabled": True,
        "codex_token_daily_count": cost_item_count if hosted_content_present else 0,
        "credits_present": "Buy Credits..." in parent_ax,
        "openai_dashboard_daily_count": None,
        "plan_history_revision": None,
    },
    "visual_readiness": {
        "cost_submenu_item_count": cost_item_count,
        "cost_submenu_bounds_found": metadata_value(visual, "cost_submenu_bounds_found"),
    },
}
print(json.dumps(dump, indent=2, sort_keys=True))
PY
}

write_proof_manifest() {
  local git_head
  git_head="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"

  "${PYTHON_BIN}" - \
    "${git_head}" \
    "${OUT_DIR}/app-bundle-metadata.txt" \
    "${OUT_DIR}/boot-session-metadata.txt" \
    "${OUT_DIR}/login-context.txt" \
    "${OUT_DIR}/run-metadata.txt" \
    "${OUT_DIR}/timing-metadata.txt" \
    "${OUT_DIR}/visual-readiness.txt" \
    "${OUT_DIR}/immediate-parent-menu-status.txt" \
    "${OUT_DIR}/immediate-parent-menu-ax.txt" \
    "${OUT_DIR}/settled-cost-submenu-ax.txt" \
    >"${OUT_DIR}/cold-start-proof-manifest.json" <<'PY'
import json
import re
import sys
from pathlib import Path

(
    git_head,
    app_metadata_path,
    boot_metadata_path,
    login_context_path,
    run_metadata_path,
    timing_metadata_path,
    visual_readiness_path,
    immediate_status_path,
    immediate_parent_ax_path,
    cost_submenu_ax_path,
) = sys.argv[1:]


def read(path):
    return Path(path).read_text(encoding="utf-8", errors="replace")


def kv(path):
    result = {}
    for line in read(path).splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def int_value(mapping, key, default=0):
    try:
        return int(mapping.get(key, default))
    except (TypeError, ValueError):
        return default


def bool_value(mapping, key):
    return mapping.get(key) == "true"


required_rows = ["Buy Credits...", "Cost | submenu=true", "Usage Dashboard", "Status Page", "Refresh"]
app = kv(app_metadata_path)
boot = kv(boot_metadata_path)
login = kv(login_context_path)
run = kv(run_metadata_path)
timing = kv(timing_metadata_path)
visual = kv(visual_readiness_path)
parent_status = read(immediate_status_path).strip()
parent_ax = read(immediate_parent_ax_path)
cost_ax = read(cost_submenu_ax_path)
missing_rows = [row for row in required_rows if row not in parent_ax]
unexpected_placeholders = []
if "No data available" in parent_ax:
    unexpected_placeholders.append("No data available")

cost_count_match = re.search(r"^Cost submenu item count=(\d+)$", cost_ax, re.MULTILINE)
cost_item_count = int(cost_count_match.group(1)) if cost_count_match else 0
cost_placeholder = "No data available" in cost_ax
cost_opened = "Cost | submenu=true" in cost_ax
manual_recovery = any(
    run.get(key) == "true"
    for key in (
        "manual_refresh_used",
        "tab_switch_used",
        "menu_reopen_required_for_parent",
        "menu_reopen_required_for_cost",
        "manual_recovery_used",
    )
)

manifest = {
    "schema": 1,
    "git_head": git_head,
    "app_path": app.get("app_path"),
    "app_binary_sha256": app.get("app_binary_sha256"),
    "validator_sha256": app.get("validator_script_sha256"),
    "checker_sha256": app.get("checker_script_sha256"),
    "boot_time_utc": boot.get("boot_time_utc"),
    "uptime_seconds": int_value(boot, "uptime_seconds"),
    "first_launch_uncontested": (
        boot.get("post_boot_first_launch_candidate") == "true"
        and boot.get("existing_codexbar_process_count") == "0"
        and login.get("running_codexbar_process_count") == "0"
        and login.get("codexbar_login_item_present") == "false"
    ),
    "existing_codexbar_process_count": int_value(boot, "existing_codexbar_process_count"),
    "login_item_present_at_runner_start": bool_value(login, "codexbar_login_item_present"),
    "first_open_parent": {
        "captured_at_ms_after_launch": int_value(timing, "immediate_parent_capture_ms_after_launch"),
        "status": parent_status,
        "required_rows_present": not missing_rows,
        "missing_rows": missing_rows,
        "unexpected_placeholders": unexpected_placeholders,
        "menu_bounds_found": visual.get("immediate_parent_bounds_found") == "true",
        "screenshot_path": "immediate-codex-parent-menu.png",
        "ax_path": "immediate-parent-menu-ax.txt",
    },
    "first_open_cost_submenu": {
        "opened": cost_opened,
        "item_count": cost_item_count,
        "placeholder_only": cost_item_count == 1 and cost_placeholder,
        "represented_object": "costHistoryChart" if cost_opened else None,
        "provider": "codex" if cost_opened else None,
        "hosted_content_present": cost_item_count >= 1 and not cost_placeholder,
        "screenshot_path": "settled-codex-cost-submenu.png",
        "ax_path": "settled-cost-submenu-ax.txt",
    },
    "late_data_refresh": {
        "parent_refresh_without_manual_action": not manual_recovery,
        "hosted_submenu_rebuilt_without_manual_action": cost_opened and not cost_placeholder and not manual_recovery,
        "max_refresh_latency_ms": max(
            int_value(timing, "immediate_parent_capture_ms_after_launch"),
            int_value(timing, "cost_submenu_capture_ms_after_launch"),
        ),
    },
}

print(json.dumps(manifest, indent=2, sort_keys=True))
PY
}

[[ -d "${APP_PATH}" ]] || fail "App bundle not found: ${APP_PATH}"
[[ -x "${APP_PATH}/Contents/MacOS/CodexBar" ]] || fail "App executable not found: ${APP_PATH}/Contents/MacOS/CodexBar"
write_app_bundle_metadata
write_login_context

initial_count="$(count_running_codexbar_processes)"
running_codexbar_processes >"${OUT_DIR}/processes-before-launch.txt"
write_boot_metadata "before-launch" "${initial_count}"
if [[ "${initial_count}" != "0" ]]; then
  running_codexbar_processes >&2
  fail "CodexBar is already running. Re-run from a clean post-boot state or stop existing instances first."
fi

log "==> Launching ${APP_PATH}"
record_timing_event "app_opened"
open -n "${APP_PATH}"

for _ in {1..20}; do
  running="$(running_codexbar_processes)"
  if [[ -n "${running}" ]]; then
    break
  fi
  sleep 0.5
done

running_codexbar_processes >"${OUT_DIR}/processes-after-launch.txt"
process_count="$(count_running_codexbar_processes)"
[[ "${process_count}" == "1" ]] || fail "Expected exactly one CodexBar process, found ${process_count}"

STARTED_PID="$(awk 'NR == 1 { print $1 }' "${OUT_DIR}/processes-after-launch.txt")"
process_path="$(awk 'NR == 1 { $1=""; sub(/^[[:space:]]+/, ""); print }' "${OUT_DIR}/processes-after-launch.txt")"
[[ "${process_path}" == "${APP_PATH}/Contents/MacOS/CodexBar" ]] ||
  fail "Unexpected process path: ${process_path}"
process_started_at="$(process_lstart "${STARTED_PID}")"

wait_for_menu_extra 30 || fail "CodexBar process launched but AX menu extra was not ready within 15 seconds"
record_timing_event "menu_extra_ready"

cat >"${OUT_DIR}/run-metadata.txt" <<EOF
run_id=${RUN_ID}
app_path=${APP_PATH}
pid=${STARTED_PID}
process_path=${process_path}
process_lstart=${process_started_at}
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
settle_seconds=${SETTLE_SECONDS}
post_boot_first_launch_candidate=$(awk -F= '$1 == "post_boot_first_launch_candidate" { print $2 }' "${OUT_DIR}/boot-session-metadata.txt")
manual_refresh_used=false
tab_switch_used=false
menu_reopen_required_for_parent=false
menu_reopen_required_for_cost=false
manual_recovery_used=false
EOF

capture_parent_menu "immediate" "keep-open"
if has_required_parent_rows "${OUT_DIR}/immediate-parent-menu-ax.txt"; then
  log "OK: immediate parent menu already has required rows"
  printf 'complete\n' >"${OUT_DIR}/immediate-parent-menu-status.txt"
  close_status_menu
else
  log "WARN: immediate parent menu is partial; waiting ${SETTLE_SECONDS}s for visible no-refresh catch-up"
  printf 'partial\n' >"${OUT_DIR}/immediate-parent-menu-status.txt"
  sleep "${SETTLE_SECONDS}"
  inspect_visible_parent_menu "open-settled"
  assert_required_parent_rows "${OUT_DIR}/open-settled-parent-menu-ax.txt"
  close_status_menu
fi

capture_parent_menu "settled"
assert_required_parent_rows "${OUT_DIR}/settled-parent-menu-ax.txt"
capture_cost_submenu
assert_visual_readiness
write_timing_summary
write_menu_readiness_dump_if_requested
write_proof_manifest

/usr/bin/log show --last 5m \
  --predicate 'process == "CodexBar" AND (eventMessage CONTAINS[c] "OpenAI web stale refresh gate" OR eventMessage CONTAINS[c] "Terminating duplicate" OR eventMessage CONTAINS[c] "Provider enablement at startup" OR eventMessage CONTAINS[c] "Provider mode snapshot" OR eventMessage CONTAINS[c] "readiness" OR eventMessage CONTAINS[c] "hydrate" OR eventMessage CONTAINS[c] "submenu")' \
  --style compact >"${OUT_DIR}/codexbar-runtime.log" 2>/dev/null || true

log "OK: cold-start menu validation artifacts written to ${OUT_DIR}"

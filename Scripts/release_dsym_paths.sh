#!/usr/bin/env bash

codexbar_dsym_dwarf_path() {
  local dsym_path="$1"
  local app_name="$2"
  local dwarf_path="${dsym_path}/Contents/Resources/DWARF/${app_name}"

  if [[ ! -f "$dwarf_path" ]]; then
    echo "Missing fresh dSYM for ${app_name} at: ${dwarf_path}" >&2
    return 1
  fi

  printf '%s\n' "$dwarf_path"
}

codexbar_require_dsym_dwarf_for_arch() {
  local dsym_path="$1"
  local app_name="$2"
  local arch="$3"
  local dwarf_path

  if ! dwarf_path=$(codexbar_dsym_dwarf_path "$dsym_path" "$app_name"); then
    return 1
  fi

  if ! lipo -archs "$dwarf_path" | tr ' ' '\n' | grep -qx "$arch"; then
    echo "dSYM at ${dwarf_path} does not contain required architecture: ${arch}" >&2
    return 1
  fi

  printf '%s\n' "$dwarf_path"
}

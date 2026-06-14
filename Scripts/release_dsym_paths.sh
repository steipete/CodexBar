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

codexbar_dwarf_uuid_for_arch() {
  local path="$1"
  local arch="$2"
  local uuid

  uuid=$(dwarfdump --uuid "$path" | awk -v arch="(${arch})" '$1 == "UUID:" && $3 == arch { print $2; exit }')
  if [[ -z "$uuid" ]]; then
    echo "Missing UUID for ${arch} in: ${path}" >&2
    return 1
  fi

  printf '%s\n' "$uuid"
}

codexbar_verify_dsym_matches_binary() {
  local app_binary="$1"
  local dsym_dwarf="$2"
  shift 2
  local arch app_uuid dsym_uuid

  if [[ ! -f "$app_binary" ]]; then
    echo "Missing app binary for dSYM UUID verification: ${app_binary}" >&2
    return 1
  fi
  if [[ ! -f "$dsym_dwarf" ]]; then
    echo "Missing dSYM DWARF file for UUID verification: ${dsym_dwarf}" >&2
    return 1
  fi

  for arch in "$@"; do
    if ! app_uuid=$(codexbar_dwarf_uuid_for_arch "$app_binary" "$arch"); then
      return 1
    fi
    if ! dsym_uuid=$(codexbar_dwarf_uuid_for_arch "$dsym_dwarf" "$arch"); then
      return 1
    fi
    if [[ "$app_uuid" != "$dsym_uuid" ]]; then
      echo "dSYM UUID mismatch for ${arch}: app=${app_uuid}, dSYM=${dsym_uuid}" >&2
      return 1
    fi
  done
}

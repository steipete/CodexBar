#!/usr/bin/env bash

codexbar_swiftpm_bin_path() {
  local conf="$1"
  shift
  local command=(swift build --show-bin-path -c "$conf")
  local arch
  for arch in "$@"; do
    command+=(--arch "$arch")
  done

  local path
  if ! path=$("${command[@]}"); then
    echo "ERROR: SwiftPM failed to report the ${conf} product directory for: $*" >&2
    return 1
  fi
  if [[ -z "$path" ]]; then
    echo "ERROR: SwiftPM reported an empty ${conf} product directory for: $*" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

codexbar_require_product_file() {
  local bin_dir="$1"
  local name="$2"
  local arch_label="$3"
  local product="$bin_dir/$name"
  if [[ ! -f "$product" ]]; then
    echo "ERROR: Missing ${name} for ${arch_label} at SwiftPM-reported path: ${product}" >&2
    return 1
  fi
  printf '%s\n' "$product"
}

codexbar_require_product_directory() {
  local bin_dir="$1"
  local name="$2"
  local context="$3"
  local product="$bin_dir/$name"
  if [[ ! -d "$product" ]]; then
    echo "ERROR: Missing ${name} for ${context} at SwiftPM-reported path: ${product}" >&2
    return 1
  fi
  printf '%s\n' "$product"
}

codexbar_resolve_staged_or_reported_file() {
  local stage_root="$1"
  local bin_dir="$2"
  local name="$3"
  local arch="$4"
  local staged="$stage_root/$arch/$name"
  if [[ -f "$staged" ]]; then
    printf '%s\n' "$staged"
    return
  fi
  codexbar_require_product_file "$bin_dir" "$name" "$arch"
}

codexbar_resolve_dsym_path() {
  local stage_root="$1"
  local bin_dir="$2"
  local app_name="$3"
  local arch="$4"
  local staged="$stage_root/$arch/${app_name}.dSYM"
  if [[ -d "$staged" ]]; then
    printf '%s\n' "$staged"
    return
  fi
  codexbar_require_product_directory "$bin_dir" "${app_name}.dSYM" "$arch"
}

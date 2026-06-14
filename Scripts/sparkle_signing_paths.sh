#!/usr/bin/env bash

codexbar_resolve_sparkle_version_child() {
  local versions_dir="$1"
  local candidate="$2"
  local label="$3"
  local versions_root resolved

  versions_root=$(cd "$versions_dir" && pwd -P)
  if ! resolved=$(cd "$candidate" 2>/dev/null && pwd -P); then
    echo "ERROR: Sparkle ${label} does not resolve: ${candidate}" >&2
    return 1
  fi
  if [[ "$(dirname "$resolved")" != "$versions_root" ]]; then
    echo "ERROR: Sparkle ${label} resolves outside the framework versions directory: ${candidate}" >&2
    return 1
  fi

  printf '%s\n' "$resolved"
}

codexbar_sparkle_version_dir() {
  local sparkle="$1"
  local versions_dir="${sparkle}/Versions"

  if [[ -L "$sparkle" ]]; then
    echo "ERROR: Sparkle framework root must not be a symlink: ${sparkle}" >&2
    return 1
  fi
  if [[ -L "$versions_dir" ]]; then
    echo "ERROR: Sparkle versions directory must not be a symlink: ${versions_dir}" >&2
    return 1
  fi
  if [[ ! -d "$versions_dir" ]]; then
    echo "ERROR: Missing Sparkle versions directory: ${versions_dir}" >&2
    return 1
  fi

  if [[ -e "$versions_dir/Current" || -L "$versions_dir/Current" ]]; then
    local current
    if ! current=$(codexbar_resolve_sparkle_version_child "$versions_dir" "$versions_dir/Current" "Versions/Current"); then
      return 1
    fi
    printf '%s\n' "$current"
    return
  fi

  local version_dirs=()
  local candidate
  shopt -s nullglob
  for candidate in "$versions_dir"/*; do
    if [[ -d "$candidate" ]]; then
      version_dirs+=("$candidate")
    fi
  done
  shopt -u nullglob

  case "${#version_dirs[@]}" in
    0)
      echo "ERROR: Sparkle framework has no version directory under: ${versions_dir}" >&2
      return 1
      ;;
    1)
      local resolved
      if ! resolved=$(codexbar_resolve_sparkle_version_child \
        "$versions_dir" "${version_dirs[0]}" "version directory"); then
        return 1
      fi
      printf '%s\n' "$resolved"
      ;;
    *)
      echo "ERROR: Sparkle framework has multiple version directories and no Versions/Current symlink: ${versions_dir}" >&2
      return 1
      ;;
  esac
}

codexbar_require_sparkle_signing_target() {
  local path="$1"
  local label="$2"
  local trusted_root="$3"
  local resolved trusted_root_resolved

  if [[ -L "$path" ]]; then
    echo "ERROR: Sparkle signing target must not be a symlink (${label}): ${path}" >&2
    return 1
  fi

  if [[ ! -e "$path" ]]; then
    echo "ERROR: Missing Sparkle signing target (${label}): ${path}" >&2
    return 1
  fi

  if ! trusted_root_resolved=$(cd "$trusted_root" 2>/dev/null && pwd -P); then
    echo "ERROR: Sparkle signing root does not resolve (${label}): ${trusted_root}" >&2
    return 1
  fi
  if [[ -d "$path" ]]; then
    resolved=$(cd "$path" && pwd -P)
  else
    resolved="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  fi
  if [[ "$resolved" != "$trusted_root_resolved" &&
    "${resolved#"$trusted_root_resolved"/}" == "$resolved" ]]; then
    echo "ERROR: Sparkle signing target resolves outside its trusted root (${label}): ${path}" >&2
    return 1
  fi

  printf '%s\n' "$resolved"
}

codexbar_sparkle_signing_targets() {
  local sparkle="$1"
  local version_dir
  if ! version_dir=$(codexbar_sparkle_version_dir "$sparkle"); then
    return 1
  fi

  codexbar_require_sparkle_signing_target "$sparkle" "framework root" "$sparkle" || return 1
  codexbar_require_sparkle_signing_target "$version_dir/Sparkle" "framework binary" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target "$version_dir/Autoupdate" "autoupdate tool" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target "$version_dir/Updater.app" "updater app" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target \
    "$version_dir/Updater.app/Contents/MacOS/Updater" "updater executable" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target \
    "$version_dir/XPCServices/Downloader.xpc" "downloader xpc" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "downloader executable" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target \
    "$version_dir/XPCServices/Installer.xpc" "installer xpc" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "installer executable" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target "$version_dir" "framework version" "$version_dir" || return 1
  codexbar_require_sparkle_signing_target "$sparkle" "framework root" "$sparkle" || return 1
}

#!/usr/bin/env bash

set -euo pipefail

changed_paths_file="${1:-}"

if [[ -z "$changed_paths_file" || ! -f "$changed_paths_file" ]]; then
  printf 'Usage: %s <changed-paths-file>\n' "$(basename "$0")" >&2
  exit 2
fi

linux_musl_build=false
linux_musl_build_reason=""
path_count=0

require_linux_musl_build() {
  local path="$1"
  local reason="$2"

  linux_musl_build=true
  if [[ -z "$linux_musl_build_reason" ]]; then
    linux_musl_build_reason="${path}: ${reason}"
  fi
}

classify_path() {
  local path="$1"
  [[ -z "$path" ]] && return

  path_count=$((path_count + 1))

  case "$path" in
    Package.swift)
      require_linux_musl_build "$path" "changes the Swift package manifest"
      ;;
    Sources/*.swift)
      require_linux_musl_build "$path" "changes Swift source code"
      ;;
  esac
}

invalid_row=false
while IFS=$'\t' read -r status first_path second_path extra_path \
  || [[ -n "${status:-}${first_path:-}${second_path:-}${extra_path:-}" ]]
do
  [[ -z "${status}${first_path:-}${second_path:-}${extra_path:-}" ]] && continue

  case "$status" in
    R*|C*)
      if ! [[ "$status" =~ ^[RC][0-9]{1,3}$ ]] \
        || ((10#${status:1} > 100)) \
        || [[ -z "${first_path:-}" || -z "${second_path:-}" || -n "${extra_path:-}" ]]
      then
        invalid_row=true
        break
      fi
      classify_path "$first_path"
      classify_path "$second_path"
      ;;
    A|D|M|T|U|X|B)
      if [[ -z "${first_path:-}" || -n "${second_path:-}" || -n "${extra_path:-}" ]]; then
        invalid_row=true
        break
      fi
      classify_path "$first_path"
      ;;
    *)
      invalid_row=true
      break
      ;;
  esac
done < "$changed_paths_file"

if [[ "$invalid_row" == true ]]; then
  printf 'Invalid git name-status row; refusing to skip the Linux musl build.\n' >&2
  exit 2
fi

if [[ "$path_count" -eq 0 ]]; then
  require_linux_musl_build '<empty diff>' 'no changed paths were reported'
fi

if [[ "$linux_musl_build" == true ]]; then
  summary_reason="$linux_musl_build_reason"
else
  summary_reason="no Swift source or Package.swift changes"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'linux-musl-build=%s\n' "$linux_musl_build" >> "$GITHUB_OUTPUT"
  printf 'linux-musl-build-reason=%s\n' "$summary_reason" >> "$GITHUB_OUTPUT"
fi

if [[ "$linux_musl_build" == true ]]; then
  printf 'Linux musl build required for this change set: %s.\n' "$linux_musl_build_reason"
else
  printf 'Skipping Linux musl build: %s.\n' "$summary_reason"
fi

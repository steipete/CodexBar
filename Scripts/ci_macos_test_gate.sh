#!/usr/bin/env bash

set -euo pipefail

changed_paths_file="${1:-}"

if [[ -z "$changed_paths_file" || ! -f "$changed_paths_file" ]]; then
  printf 'Usage: %s <changed-paths-file>\n' "$(basename "$0")" >&2
  exit 2
fi

macos_tests=false
macos_tests_reason=""
path_count=0

require_macos_tests() {
  local path="$1"
  local reason="$2"

  macos_tests=true
  if [[ -z "$macos_tests_reason" ]]; then
    macos_tests_reason="${path}: ${reason}"
  fi
}

classify_path() {
  local path="$1"
  [[ -z "$path" ]] && return

  path_count=$((path_count + 1))

  case "$path" in
    AGENTS.md|docs/configuration.md)
      require_macos_tests "$path" "changes contributor or runtime configuration contracts"
      ;;
    *.md)
      ;;
    docs/.nojekyll|docs/CNAME|docs/index.html|docs/llms.txt|docs/site-locales.mjs|docs/site.css|docs/site.js|docs/social.html|docs/social.png)
      ;;
    docs/*.png|docs/*.jpg|docs/*.jpeg|docs/*.webp|docs/*.ico|docs/*.svg)
      ;;
    *)
      require_macos_tests "$path" "not covered by portable docs/site checks"
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
  printf 'Invalid git name-status row; refusing to skip macOS tests.\n' >&2
  exit 2
fi

if [[ "$path_count" -eq 0 ]]; then
  require_macos_tests '<empty diff>' 'no changed paths were reported'
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'macos-tests=%s\n' "$macos_tests" >> "$GITHUB_OUTPUT"
fi

if [[ "$macos_tests" == true ]]; then
  printf 'macOS Swift tests required for this change set: %s.\n' "$macos_tests_reason"
else
  printf 'Skipping macOS Swift tests for docs/site-only changes covered by portable checks.\n'
fi

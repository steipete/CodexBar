#!/usr/bin/env bash

set -euo pipefail

changed_paths_file="${1:-}"

if [[ -z "$changed_paths_file" || ! -f "$changed_paths_file" ]]; then
  printf 'Usage: %s <changed-paths-file>\n' "$(basename "$0")" >&2
  exit 2
fi

macos_tests=false
path_count=0

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  path_count=$((path_count + 1))

  case "$path" in
    *.md|docs/*)
      ;;
    *)
      macos_tests=true
      ;;
  esac
done < "$changed_paths_file"

if [[ "$path_count" -eq 0 ]]; then
  macos_tests=true
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'macos-tests=%s\n' "$macos_tests" >> "$GITHUB_OUTPUT"
fi

if [[ "$macos_tests" == true ]]; then
  printf 'macOS Swift tests required for this change set.\n'
else
  printf 'Skipping macOS Swift tests for docs/Markdown-only changes.\n'
fi

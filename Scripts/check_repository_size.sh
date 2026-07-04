#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_BYTES=$((2 * 1024 * 1024))
failures=0
tracked_files=0

cd "$ROOT_DIR"

while IFS= read -r -d '' path; do
  tracked_files=$((tracked_files + 1))

  case "$path" in
    *.app | *.app/* | *.dSYM | *.dSYM/* | *.xcarchive/* | *.xcresult/* | *.ipa | *.zip | *.delta | *.dmg | \
      *.pkg | *.tar.gz | *.tgz)
      printf 'ERROR: generated artifact is tracked: %s\n' "$path" >&2
      failures=$((failures + 1))
      ;;
  esac

  [[ -f "$path" && ! -L "$path" ]] || continue

  size=$(wc -c < "$path")
  if ((size > MAX_BYTES)); then
    printf 'ERROR: tracked file exceeds %d bytes: %s (%d bytes)\n' "$MAX_BYTES" "$path" "$size" >&2
    failures=$((failures + 1))
  fi
done < <(git ls-files -z)

if ((failures > 0)); then
  printf 'Repository size check failed with %d violation(s).\n' "$failures" >&2
  printf 'Publish build/release artifacts outside Git and optimize required source assets.\n' >&2
  exit 1
fi

printf 'repository size OK: %d tracked files, maximum %d bytes each\n' "$tracked_files" "$MAX_BYTES"

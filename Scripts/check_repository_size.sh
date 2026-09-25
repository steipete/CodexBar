#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_BYTES=$((2 * 1024 * 1024))
# Audited size of pristine QuickJS-NG v0.17.0; do not trim vendored upstream source to fit the default.
QUICKJS_MAX_BYTES=2148068
failures=0
tracked_files=0
declare -a blob_paths=()
declare -a blob_ids=()

cd "$ROOT_DIR"

while IFS= read -r -d '' entry; do
  metadata=${entry%%$'\t'*}
  path=${entry#*$'\t'}
  read -r mode object stage <<<"$metadata"
  [[ "$stage" == "0" ]] || continue
  tracked_files=$((tracked_files + 1))

  case "$path" in
    *.app | *.app/* | *.dSYM | *.dSYM/* | *.xcarchive/* | *.xcresult/* | *.ipa | *.zip | *.delta | *.dmg | \
      *.pkg | *.tar.gz | *.tgz)
      printf 'ERROR: generated artifact is tracked: %s\n' "$path" >&2
      failures=$((failures + 1))
      ;;
  esac

  # Submodule entries name commits rather than file blobs.
  [[ "$mode" == "160000" ]] && continue
  blob_paths+=("$path")
  blob_ids+=("$object")
done < <(git ls-files --stage -z)

if ((${#blob_ids[@]} > 0)); then
  index=0
  while read -r object type size; do
    path=${blob_paths[$index]}
    if [[ "$type" != "blob" ]]; then
      printf 'ERROR: tracked index entry is not a readable blob: %q (%s)\n' "$path" "$object" >&2
      failures=$((failures + 1))
      index=$((index + 1))
      continue
    fi
    max_bytes=$MAX_BYTES
    if [[ "$path" == "Sources/CQuickJS/quickjs.c" ]]; then
      max_bytes=$QUICKJS_MAX_BYTES
    fi
    if ((size > max_bytes)); then
      printf 'ERROR: tracked file exceeds %d bytes: %q (%d bytes)\n' "$max_bytes" "$path" "$size" >&2
      failures=$((failures + 1))
    fi
    index=$((index + 1))
  done < <(printf '%s\n' "${blob_ids[@]}" | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize)')
fi

if ((failures > 0)); then
  printf 'Repository size check failed with %d violation(s).\n' "$failures" >&2
  printf 'Publish build/release artifacts outside Git and optimize required source assets.\n' >&2
  exit 1
fi

printf 'repository size OK: %d tracked files, default maximum %d bytes, QuickJS maximum %d bytes\n' \
  "$tracked_files" "$MAX_BYTES" "$QUICKJS_MAX_BYTES"

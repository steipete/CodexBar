#!/usr/bin/env bash
set -euo pipefail

# Inspect the shipped glibc executable, not the build host's installed libraries.
deps="$(readelf -d "${1:?Usage: check-linux-cli-linkage.sh <glibc-cli>}")"
needed="$(printf '%s\n' "$deps" | grep '(NEEDED)' || true)"
if [[ -z "$needed" ]]; then
  echo 'error: no NEEDED entries; cannot verify Linux CLI linkage' >&2
  exit 1
fi
printf '%s\n' "$needed"
if [[ "$needed" == *libxml2* ]]; then
  echo 'error: Linux CLI links libxml2; keep FoundationXML under os(macOS) (#4652)' >&2
  exit 1
fi

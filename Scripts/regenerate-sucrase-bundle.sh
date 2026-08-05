#!/usr/bin/env bash
# Reproducibly regenerates Sources/CodexBarCore/Resources/Plugins/sucrase-3.35.1.min.js
# from the official npm artifact. The vendored bundle MUST match EXPECTED_SHA256;
# review of the minified blob is by reproduction, not by reading.
set -euo pipefail

SUCRASE_VERSION="3.35.1"
ESBUILD_VERSION="0.25.8"
EXPECTED_SHA256="4d997e15b72cbc9ccf6e743c30c6eb48bf4533f6709852367b40766be5eba70b"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${ROOT_DIR}/Sources/CodexBarCore/Resources/Plugins/sucrase-${SUCRASE_VERSION}.min.js"
MODE="${1:-check}"

WORK_DIR="$(mktemp -d /tmp/codexbar-sucrase-regen.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

npm init -y >/dev/null 2>&1
npm install --ignore-scripts --no-audit --no-fund "sucrase@${SUCRASE_VERSION}" >/dev/null
npx --yes "esbuild@${ESBUILD_VERSION}" node_modules/sucrase/dist/index.js \
  --bundle --minify --platform=browser --format=iife --global-name=sucrase \
  --banner:js="/*! Sucrase v${SUCRASE_VERSION} | MIT License | Copyright (c) 2012-present various contributors | https://github.com/alangpierce/sucrase */" \
  --outfile="${WORK_DIR}/sucrase.min.js" >/dev/null 2>&1

ACTUAL_SHA256="$(shasum -a 256 "${WORK_DIR}/sucrase.min.js" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "error: reproduced bundle hash ${ACTUAL_SHA256} does not match expected ${EXPECTED_SHA256}" >&2
  echo "If the version or esbuild pin changed intentionally, update EXPECTED_SHA256." >&2
  exit 1
fi

case "$MODE" in
  check | --check)
    VENDORED_SHA256="$(shasum -a 256 "$OUTPUT_FILE" | awk '{print $1}')"
    if [[ "$VENDORED_SHA256" != "$EXPECTED_SHA256" ]]; then
      echo "error: vendored bundle ${VENDORED_SHA256} does not match reproducible build ${EXPECTED_SHA256}" >&2
      exit 1
    fi
    echo "ok: vendored sucrase bundle matches reproducible build (${EXPECTED_SHA256})"
    ;;
  write | --write)
    cp "${WORK_DIR}/sucrase.min.js" "$OUTPUT_FILE"
    echo "wrote ${OUTPUT_FILE} (${EXPECTED_SHA256})"
    ;;
  *)
    echo "Usage: $0 [check|write]" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="${ROOT_DIR}/Sources/CodexBarCore/Resources/Plugins"
SUCRASE_FILE="${PLUGIN_DIR}/sucrase-3.35.1.min.js"
OXFMT="${ROOT_DIR}/.build/lint-tools/bin/oxfmt"
MODE="${1:-write}"

case "$MODE" in
  write | --write)
    CHECK_ONLY=0
    ;;
  check | --check)
    CHECK_ONLY=1
    ;;
  *)
    echo "Usage: $0 [write|--write|check|--check]" >&2
    exit 2
    ;;
esac

count=0
"${ROOT_DIR}/Scripts/install_lint_tools.sh" oxfmt >/dev/null
for source in "${PLUGIN_DIR}"/*.ts; do
  [[ -f "$source" ]] || continue
  [[ "$source" == *.d.ts ]] && continue
  output="${source%.ts}.js"
  expected_dir="$(mktemp -d)"
  expected="${expected_dir}/$(basename "$output")"
  node "${ROOT_DIR}/Scripts/transpile-plugin-ts.mjs" "$source" "$SUCRASE_FILE" >"$expected"
  "$OXFMT" --config "${ROOT_DIR}/.oxfmtrc.json" --write "$expected" >/dev/null
  count=$((count + 1))

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if ! cmp -s "$expected" "$output"; then
      echo "error: ${output#${ROOT_DIR}/} is stale. Run Scripts/regenerate-plugin-js.sh and commit the result." >&2
      if [[ -f "$output" ]]; then
        diff -u "$output" "$expected" >&2 || true
      else
        diff -u /dev/null "$expected" >&2 || true
      fi
      rm -rf "$expected_dir"
      exit 1
    fi
    rm -rf "$expected_dir"
  else
    mv "$expected" "$output"
    rm -rf "$expected_dir"
    echo "Updated ${output#${ROOT_DIR}/}"
  fi
done

if [[ "$count" -eq 0 ]]; then
  echo "error: no bundled TypeScript plugins found in ${PLUGIN_DIR#${ROOT_DIR}/}" >&2
  exit 1
fi
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "Bundled plugin JavaScript is current (${count} TypeScript source file(s))"
fi

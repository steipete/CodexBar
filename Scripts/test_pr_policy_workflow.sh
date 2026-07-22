#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/pr-policy.yml"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

python3 - "$WORKFLOW" "$TEMP_DIR/pr-policy.js" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text().splitlines()
script_start = next(index for index, line in enumerate(workflow) if line == "          script: |") + 1
script_lines = []
for line in workflow[script_start:]:
    if line and not line.startswith("            "):
        break
    script_lines.append(line[12:] if line else "")

if not script_lines:
    raise SystemExit("PR policy script was not found")

pathlib.Path(sys.argv[2]).write_text("\n".join(script_lines) + "\n")
PY

run_policy() {
  local body="$1"
  node - "$TEMP_DIR/pr-policy.js" "$body" <<'JS'
const fs = require("fs")
const [scriptPath, body] = process.argv.slice(2)
const failures = []
const context = {
  payload: {
    pull_request: {
      title: "chore(governance): add contributor baseline",
      body,
    },
  },
}
const core = { setFailed(message) { failures.push(message) } }
eval(fs.readFileSync(scriptPath, "utf8"))
if (failures.length > 0) {
  console.error(failures.join("\n"))
  process.exit(1)
}
JS
}

valid_body=$'## Summary\n\nConcrete change.\n\n## Why\n\nReason.\n\n## Linked issue or maintainer sign-off\n\nSign-off requested.\n\n## Validation\n\n`make check`\n\n## UI proof\n\nNot applicable.\n\n## Provider and privacy impact\n\nNone.\n\n## Checklist\n\n- [x] Focused.'
run_policy "$valid_body"

invalid_body=${valid_body/Concrete change./}
if run_policy "$invalid_body" >/dev/null 2>&1; then
  echo "PR policy accepted an empty Summary section" >&2
  exit 1
fi

echo "PR policy workflow tests passed."

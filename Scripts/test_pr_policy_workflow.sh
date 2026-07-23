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
  local author="$1"
  local title="$2"
  local body="$3"
  node - "$TEMP_DIR/pr-policy.js" "$author" "$title" "$body" <<'JS'
const fs = require("fs")
const [scriptPath, author, title, body] = process.argv.slice(2)
const failures = []
const context = {
  payload: {
    pull_request: {
      title,
      body,
      user: { login: author },
    },
  },
}
const core = {
  info() {},
  setFailed(message) { failures.push(message) },
}
eval(fs.readFileSync(scriptPath, "utf8"))
if (failures.length > 0) {
  console.error(failures.join("\n"))
  process.exit(1)
}
JS
}

valid_body=$'## Summary\n\nConcrete change.\n\n## Why\n\nReason.\n\n## Linked issue or maintainer sign-off\n\nFixes #123.\n\n## Validation\n\n`make check`\n\n## UI proof\n\nNot applicable.\n\n## Provider and privacy impact\n\nNone.\n\n## Checklist\n\n- [x] Focused.'
run_policy "octocat" "chore(governance): add contributor baseline" "$valid_body"
run_policy "octocat" "Fix a tricky regression" "$valid_body"
run_policy "dependabot[bot]" "Bump actions/checkout from 6 to 7" ""

invalid_body=${valid_body/Concrete change./}
if run_policy "octocat" "chore(governance): add contributor baseline" "$invalid_body" >/dev/null 2>&1; then
  echo "PR policy accepted an empty Summary section" >&2
  exit 1
fi

invalid_linked=${valid_body/Fixes \#123/Related context only.}
if run_policy "octocat" "chore(governance): add contributor baseline" "$invalid_linked" >/dev/null 2>&1; then
  echo "PR policy accepted an unexplained issue relationship" >&2
  exit 1
fi

placeholder_body=$'## Summary\n\n<!-- Describe the change. -->\n\n## Why\n\n<!-- Explain the reason. -->\n\n## Linked issue or maintainer sign-off\n\n<!-- Use Fixes #123. -->\n\n## Validation\n\n<!-- List checks. -->\n\n## UI proof\n\n<!-- Include proof. -->\n\n## Provider and privacy impact\n\n<!-- State None when appropriate. -->\n\n## Checklist\n\n- [ ] Focused.'
if run_policy "octocat" "chore(governance): add contributor baseline" "$placeholder_body" >/dev/null 2>&1; then
  echo "PR policy accepted template guidance instead of contributor content" >&2
  exit 1
fi

echo "PR policy workflow tests passed."

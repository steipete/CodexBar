#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/release-cli.yml"

python3 - "$WORKFLOW" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text()

if not re.search(r"(?ms)^permissions:\n  contents: read\n", workflow):
    raise SystemExit("release workflow must default to read-only repository contents")


def job(name: str) -> str:
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)", workflow)
    if match is None:
        raise SystemExit(f"missing {name} job")
    return match.group("body")


build = job("build-cli")
if not re.search(r"(?ms)^    permissions:\n      contents: read\n", build):
    raise SystemExit("build-cli must receive only read access to repository contents")
if "contents: write" in build:
    raise SystemExit("build-cli must not receive repository write access")
if "Upload packaged artifact" not in build or "if: github.event_name" in build.split("Upload packaged artifact", 1)[1].split("\n  ", 1)[0]:
    raise SystemExit("build-cli must upload its packaged artifact for every run")

publisher = job("publish-release-assets")
for required in (
    "needs: build-cli",
    "if: github.event_name == 'release'",
    "actions: read",
    "contents: write",
    "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
    "pattern: codexbar-cli-*",
    "merge-multiple: true",
    'gh release upload "$RELEASE_TAG" "${assets[@]}" --clobber',
):
    if required not in publisher:
        raise SystemExit(f"release publisher is missing: {required}")

tap = job("update-homebrew-tap")
if "permissions: {}" not in tap:
    raise SystemExit("tap updater must not receive the repository token")

print("Release CLI permissions workflow tests passed.")
PY

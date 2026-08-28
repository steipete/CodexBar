#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

npx --yes tailwindcss@3.4.19 \
  --config Scripts/tailwind.site.config.cjs \
  --input Scripts/site-tailwind.input.css \
  --output docs/site-utilities.css \
  --minify

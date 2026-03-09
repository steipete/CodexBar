#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Starting CodexBar local usage bridge on http://127.0.0.1:8787"
echo "Using binary: swift run CodexBarCLI"

python3 Scripts/usage_api_server.py --port 8787 --binary "swift run CodexBarCLI"

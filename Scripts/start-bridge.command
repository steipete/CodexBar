#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Starting CodexBar local usage bridge on http://127.0.0.1:8787"
echo "Building CodexBarCLI release binary (one-time; may take a minute)..."
swift build -c release --product CodexBarCLI
BIN_PATH="$(pwd)/.build/release/CodexBarCLI"
echo "Using binary: $BIN_PATH"

echo "Bridge ready. Test with: curl http://127.0.0.1:8787/api/usage/summary?range=weekly"
python3 Scripts/usage_api_server.py --port 8787 --binary "$BIN_PATH"

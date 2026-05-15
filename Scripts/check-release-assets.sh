#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$HOME/Projects/agent-scripts/release/sparkle_lib.sh"

TAG=${1:-$(git describe --tags --abbrev=0)}
ARTIFACT_PREFIX="CodexBar-macos-[A-Za-z0-9_+-]+-"

check_assets "$TAG" "$ARTIFACT_PREFIX"

#!/usr/bin/env bash
# Invoke through op run (secret references) or an existing AWS credential chain.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$script_dir/../../../.."
command -v crabbox >/dev/null || { echo 'Install Crabbox v0.57.0 or newer first.' >&2; exit 1; }
# These bounds apply to this run, regardless of shell defaults.
export CRABBOX_AWS_ROOT_GB=40
export CRABBOX_AWS_REGION=${CRABBOX_AWS_REGION:-us-east-1}
exec crabbox run --provider aws --arch arm64 --os ubuntu:24.04 \
  --type c7g.xlarge --market on-demand --ttl 45m --idle-timeout 10m \
  --stop-after always --label codexbar-rust-arm-desktop \
  --artifact-glob 'rust-evidence/*' --require-artifact 'rust-evidence/platform.txt' \
  -- timeout 30m bash Integrations/Linux/RustPrototype/tests/crabbox-remote.sh

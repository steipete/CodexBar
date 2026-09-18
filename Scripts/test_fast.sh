#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/Scripts/test_environment.sh"
unset MAKEFLAGS MFLAGS MAKEOVERRIDES

exec python3 "${ROOT_DIR}/Scripts/run_swift_test.py" "$@"

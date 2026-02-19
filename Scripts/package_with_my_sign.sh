#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CONF=${1:-release}

# Allow explicit override:
# APP_IDENTITY="Apple Development: Name (TEAMID)" ./Scripts/package_with_my_sign.sh
if [[ -z "${APP_IDENTITY:-}" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development:/{print $2; exit}')
fi

if [[ -z "${APP_IDENTITY:-}" ]]; then
  echo "ERROR: No Apple Development signing identity found." >&2
  echo "Run: security find-identity -v -p codesigning" >&2
  exit 1
fi

echo "Using signing identity: ${APP_IDENTITY}"
APP_IDENTITY="${APP_IDENTITY}" ./Scripts/package_app.sh "${CONF}"

echo ""
echo "Packaged app: ${ROOT}/CodexBar.app"
echo "Recommended verification:"
echo "  spctl -a -t exec -vv ${ROOT}/CodexBar.app"
echo "  codesign --verify --deep --strict --verbose ${ROOT}/CodexBar.app"

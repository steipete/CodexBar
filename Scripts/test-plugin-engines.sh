#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
source "$ROOT_DIR/Scripts/test_environment.sh"

FILTER='ProviderPluginRuntimeTests|ProviderPluginParityTests|ProviderPluginDetailsParityTests|ProviderPluginExtensionParityTests|Sub2APIPluginGoldenTests|UserProviderPluginPortableTests'

echo "plugin engine A/B: QuickJS default"
env -u CODEXBAR_PLUGIN_ENGINE swift test --filter "$FILTER"

echo "plugin engine A/B: JavaScriptCore rollback"
CODEXBAR_PLUGIN_ENGINE=jsc swift test --skip-build --filter "$FILTER"

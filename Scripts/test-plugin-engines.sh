#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

FILTER='ProviderPluginRuntimeTests|ProviderPluginParityTests|ProviderPluginDetailsParityTests|ProviderPluginExtensionParityTests|Sub2APIPluginGoldenTests|UserProviderPluginPortableTests'

echo "plugin engine A/B: QuickJS default"
env -u CODEXBAR_PLUGIN_ENGINE swift test --filter "$FILTER"

echo "plugin engine A/B: JavaScriptCore rollback"
CODEXBAR_PLUGIN_ENGINE=jsc swift test --skip-build --filter "$FILTER"

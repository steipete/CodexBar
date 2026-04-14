#!/usr/bin/env bash
set -euo pipefail

CONF_INPUT=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPEC_DIR="$ROOT/Xcode/WidgetBuild"
SPEC_PATH="$SPEC_DIR/project.yml"
PROJECT_PATH="$SPEC_DIR/WidgetBuild.xcodeproj"
TARGET_NAME="CodexBarWidget"
SCHEME_NAME="CodexBarWidget"

source "$ROOT/version.env"

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Missing required tool: $tool" >&2
    exit 1
  fi
}

normalize_configuration() {
  local input
  input=$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')
  case "$input" in
    debug) echo "Debug" ;;
    release) echo "Release" ;;
    *)
      echo "ERROR: Expected debug or release, got: $1" >&2
      exit 1
      ;;
  esac
}

host_arch() {
  local detected
  detected=$(uname -m)
  case "$detected" in
    arm64|x86_64) echo "$detected" ;;
    *) echo "$detected" ;;
  esac
}

resolve_arches() {
  if [[ -n "${ARCHES:-}" ]]; then
    printf "%s" "$ARCHES"
  else
    host_arch
  fi
}

default_widget_bundle_id() {
  local configuration="$1"
  if [[ "$configuration" == "Debug" ]]; then
    echo "com.steipete.codexbar.debug.widget"
  else
    echo "com.steipete.codexbar.widget"
  fi
}

default_app_group_id() {
  local widget_bundle_id="$1"
  local team_id="$2"
  local base="${team_id}.com.steipete.codexbar"
  if [[ "$widget_bundle_id" == *".debug.widget" ]]; then
    echo "${base}.debug"
  else
    echo "$base"
  fi
}

CONFIGURATION=$(normalize_configuration "$CONF_INPUT")
ARCHES_VALUE=$(resolve_arches)
APP_TEAM_ID_VALUE=${APP_TEAM_ID:-Y5PE65HELJ}
WIDGET_BUNDLE_ID_VALUE=${WIDGET_BUNDLE_ID:-$(default_widget_bundle_id "$CONFIGURATION")}
APP_GROUP_ID_VALUE=${APP_GROUP_ID:-$(default_app_group_id "$WIDGET_BUNDLE_ID_VALUE" "$APP_TEAM_ID_VALUE")}
MARKETING_VERSION_VALUE=${MARKETING_VERSION:-$MARKETING_VERSION}
BUILD_NUMBER_VALUE=${BUILD_NUMBER:-$BUILD_NUMBER}
DERIVED_DATA_PATH=${CODEXBAR_WIDGET_DERIVED_DATA:-$ROOT/.build/xcode-widget/DerivedData}
PRODUCT_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/${TARGET_NAME}.appex"
EXECUTABLE_PATH="$PRODUCT_PATH/Contents/MacOS/${TARGET_NAME}"

require_tool xcodebuild
require_tool xcodegen

if [[ ! -f "$SPEC_PATH" ]]; then
  echo "ERROR: Missing widget wrapper spec at $SPEC_PATH" >&2
  exit 1
fi

rm -rf "$DERIVED_DATA_PATH"
mkdir -p "$DERIVED_DATA_PATH"

xcodegen --quiet --spec "$SPEC_PATH" --project "$SPEC_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS="$ARCHES_VALUE" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM="$APP_TEAM_ID_VALUE" \
  APP_TEAM_ID="$APP_TEAM_ID_VALUE" \
  APP_GROUP_ID="$APP_GROUP_ID_VALUE" \
  WIDGET_BUNDLE_ID="$WIDGET_BUNDLE_ID_VALUE" \
  MARKETING_VERSION="$MARKETING_VERSION_VALUE" \
  BUILD_NUMBER="$BUILD_NUMBER_VALUE" \
  clean build >/dev/null

if [[ ! -d "$PRODUCT_PATH" ]]; then
  echo "ERROR: Missing built widget bundle at $PRODUCT_PATH" >&2
  exit 1
fi

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "ERROR: Missing widget executable at $EXECUTABLE_PATH" >&2
  exit 1
fi

EXECUTABLE_SYMBOLS=$(nm -m "$EXECUTABLE_PATH" 2>/dev/null || true)
if [[ "$EXECUTABLE_SYMBOLS" != *"NSExtensionMain"* ]]; then
  echo "ERROR: Built widget executable does not import NSExtensionMain" >&2
  exit 1
fi

printf '%s\n' "$PRODUCT_PATH"

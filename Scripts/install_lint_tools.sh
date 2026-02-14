#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/.build/lint-tools"
BIN_DIR="${TOOLS_DIR}/bin"

SWIFTFORMAT_VERSION="0.59.1"
SWIFTLINT_VERSION="0.63.2"

SWIFTFORMAT_SHA256_DARWIN="8b6289b608a44e73cd3851c3589dbd7c553f32cc805aa54b3a496ce2b90febe7"
SWIFTLINT_SHA256_DARWIN="c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sha256_value() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  fail "Missing shasum/sha256sum."
}

download_file() {
  local url="$1"
  local out="$2"
  curl -fL --retry 3 --retry-connrefused --retry-delay 2 -o "$out" "$url"
}

install_zip_binary() {
  local label="$1"
  local url="$2"
  local expected_sha="$3"
  local binary_name="$4"

  local tmp_zip
  tmp_zip="$(mktemp -t "${label}.XXXX")"
  local tmp_dir
  tmp_dir="$(mktemp -d -t "${label}.XXXX")"

  log "==> Downloading ${label}"
  download_file "$url" "$tmp_zip"

  local actual_sha
  actual_sha="$(sha256_value "$tmp_zip")"
  if [[ -n "$expected_sha" && "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$tmp_zip"
    rm -rf "$tmp_dir"
    fail "${label} SHA256 mismatch (expected ${expected_sha}, got ${actual_sha})"
  fi

  unzip -q "$tmp_zip" -d "$tmp_dir"

  local extracted_path=""
  if [[ -f "${tmp_dir}/${binary_name}" ]]; then
    extracted_path="${tmp_dir}/${binary_name}"
  else
    extracted_path="$(find "$tmp_dir" -type f -name "$binary_name" | head -n 1 || true)"
  fi

  if [[ -z "$extracted_path" || ! -f "$extracted_path" ]]; then
    rm -f "$tmp_zip"
    rm -rf "$tmp_dir"
    fail "${label} binary '${binary_name}' not found in archive"
  fi

  install -m 0755 "$extracted_path" "${BIN_DIR}/${binary_name}"

  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"
}

mkdir -p "$BIN_DIR"

if [[ -x "${BIN_DIR}/swiftformat" && -x "${BIN_DIR}/swiftlint" ]]; then
  if [[ "$("${BIN_DIR}/swiftformat" --version 2>/dev/null || true)" == "${SWIFTFORMAT_VERSION}" ]] \
    && [[ "$("${BIN_DIR}/swiftlint" version 2>/dev/null || true)" == "${SWIFTLINT_VERSION}" ]]
  then
    log "==> Lint tools already installed (${SWIFTFORMAT_VERSION}, ${SWIFTLINT_VERSION})"
    exit 0
  fi
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
    SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"

    install_zip_binary "SwiftFormat ${SWIFTFORMAT_VERSION}" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256_DARWIN" "swiftformat"
    install_zip_binary "SwiftLint ${SWIFTLINT_VERSION}" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256_DARWIN" "swiftlint"
    ;;
  Linux)
    case "$ARCH" in
      x86_64)
        SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux.zip"
        SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip"
        ;;
      aarch64|arm64)
        SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux_aarch64.zip"
        SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_arm64.zip"
        ;;
      *)
        fail "Unsupported Linux arch: ${ARCH}"
        ;;
    esac

    # SHA256 is intentionally only enforced for the macOS CI path.
    # If we later run lint on Linux CI, add pinned SHAs here as well.
    log "WARN: Linux SHA256 verification not configured for ${ARCH}; installing anyway."
    install_zip_binary "SwiftFormat ${SWIFTFORMAT_VERSION}" "$SWIFTFORMAT_URL" "" "swiftformat"
    install_zip_binary "SwiftLint ${SWIFTLINT_VERSION}" "$SWIFTLINT_URL" "" "swiftlint"
    ;;
  *)
    fail "Unsupported OS: ${OS}"
    ;;
esac

log "==> Installed lint tools to ${BIN_DIR}"
"${BIN_DIR}/swiftformat" --version
"${BIN_DIR}/swiftlint" version

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/.build/lint-tools"
BIN_DIR="${TOOLS_DIR}/bin"

SWIFTFORMAT_VERSION="0.61.1"
SWIFTLINT_VERSION="0.65.0"
OXLINT_VERSION="1.76.0"
OXFMT_VERSION="0.61.0"
OXC_APPS_RELEASE="1.76.0"
TYPESCRIPT_VERSION="5.9.3"

SWIFTFORMAT_SHA256_DARWIN="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTLINT_SHA256_DARWIN="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"
SWIFTFORMAT_SHA256_LINUX_X86_64="7bc8706e3fd51963f1f29eb99098ebdf482f3497fa527c68e6cf75cbee29c77a"
SWIFTLINT_SHA256_LINUX_X86_64="79306a34e5c7cc55a220cd108cbb861dcad5f10138dcdf261e2624ae8b0a486b"
SWIFTFORMAT_SHA256_LINUX_ARM64="42a35b557a6d56975fba3a48e78d39ab5388c8faac65d4819f25d3e20c7504c0"
SWIFTLINT_SHA256_LINUX_ARM64="12d3b84bc5b69ae13a99a5a5c79904f9ce25867f099f6368d0037854f9ee6c26"
OXLINT_SHA256_DARWIN_X86_64="8ce24ce5ab9d2ba8177f33d69a21931cc42b6fcae3658abce9b89cbe3f35c449"
OXLINT_SHA256_DARWIN_ARM64="71071f11d95e3ffc3185f46f29ebc69e099fb141016c2109e1f3580553646d61"
OXLINT_SHA256_LINUX_X86_64="5a01b07e26311b749266794b02dc3f757498fb799e66b117d10c49ec842b59f0"
OXLINT_SHA256_LINUX_ARM64="657f88fc484f0ba61bce1cb0c6ce247686d8e3e8e0b62cbc5020131b3852230e"
OXFMT_SHA256_DARWIN_X86_64="38e17bbcd6a81744676ff3a6e4bdc1f22b34baed30f91e56be80a34a54d12fd2"
OXFMT_SHA256_DARWIN_ARM64="dcb656524237ad33a0a5d46a836a2b6f67843e644a3098e4709de96b6305b1be"
OXFMT_SHA256_LINUX_X86_64="91375457015624f93914744959795b40aa552bfc05d3c1c229186acf5bef4500"
OXFMT_SHA256_LINUX_ARM64="e604e0db4aaee11cb203b094df12f8f12ff2c3b9507430a8044b4693abdad53a"
TYPESCRIPT_SHA256="10e108c9cf7d5f2879053dff18515fb405abf2ccef63eaaf017d9c571687a1d3"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

INSTALL_SWIFTFORMAT=false
INSTALL_SWIFTLINT=false
INSTALL_OXLINT=false
INSTALL_OXFMT=false
INSTALL_TYPESCRIPT=false

if [[ "$#" -eq 0 ]]; then
  INSTALL_SWIFTFORMAT=true
  INSTALL_SWIFTLINT=true
  INSTALL_OXLINT=true
  INSTALL_OXFMT=true
  INSTALL_TYPESCRIPT=true
else
  for tool in "$@"; do
    case "$tool" in
      all)
        INSTALL_SWIFTFORMAT=true
        INSTALL_SWIFTLINT=true
        INSTALL_OXLINT=true
        INSTALL_OXFMT=true
        INSTALL_TYPESCRIPT=true
        ;;
      swiftformat)
        INSTALL_SWIFTFORMAT=true
        ;;
      swiftlint)
        INSTALL_SWIFTLINT=true
        ;;
      oxlint)
        INSTALL_OXLINT=true
        ;;
      oxfmt)
        INSTALL_OXFMT=true
        ;;
      typescript)
        INSTALL_TYPESCRIPT=true
        ;;
      *)
        fail "Unknown lint tool '${tool}'. Usage: $(basename "$0") [all|swiftformat|swiftlint|oxlint|oxfmt|typescript]..."
        ;;
    esac
  done
fi

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
  local installed_name="${5:-$binary_name}"

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

  install -m 0755 "$extracted_path" "${BIN_DIR}/${installed_name}"

  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"
}

install_tar_binary() {
  local label="$1"
  local url="$2"
  local expected_sha="$3"
  local binary_name="$4"
  local installed_name="$5"

  local tmp_tar
  tmp_tar="$(mktemp -t "${label}.XXXX")"
  local tmp_dir
  tmp_dir="$(mktemp -d -t "${label}.XXXX")"

  log "==> Downloading ${label}"
  download_file "$url" "$tmp_tar"

  local actual_sha
  actual_sha="$(sha256_value "$tmp_tar")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    fail "${label} SHA256 mismatch (expected ${expected_sha}, got ${actual_sha})"
  fi

  tar -xzf "$tmp_tar" -C "$tmp_dir"
  if [[ ! -f "${tmp_dir}/${binary_name}" ]]; then
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    fail "${label} binary '${binary_name}' not found in archive"
  fi
  install -m 0755 "${tmp_dir}/${binary_name}" "${BIN_DIR}/${installed_name}"

  rm -f "$tmp_tar"
  rm -rf "$tmp_dir"
}

install_typescript() {
  local tmp_tar
  tmp_tar="$(mktemp -t "typescript.XXXX")"
  local tmp_dir
  tmp_dir="$(mktemp -d -t "typescript.XXXX")"
  local url="https://registry.npmjs.org/typescript/-/typescript-${TYPESCRIPT_VERSION}.tgz"

  log "==> Downloading TypeScript ${TYPESCRIPT_VERSION}"
  download_file "$url" "$tmp_tar"
  local actual_sha
  actual_sha="$(sha256_value "$tmp_tar")"
  if [[ "$actual_sha" != "$TYPESCRIPT_SHA256" ]]; then
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    fail "TypeScript ${TYPESCRIPT_VERSION} SHA256 mismatch (expected ${TYPESCRIPT_SHA256}, got ${actual_sha})"
  fi

  tar -xzf "$tmp_tar" -C "$tmp_dir"
  rm -rf "${TOOLS_DIR}/typescript"
  mv "${tmp_dir}/package" "${TOOLS_DIR}/typescript"
  rm -f "$tmp_tar"
  rm -rf "$tmp_dir"
}

mkdir -p "$BIN_DIR"

swiftformat_installed() {
  [[ -x "${BIN_DIR}/swiftformat" ]] \
    && [[ "$("${BIN_DIR}/swiftformat" --version 2>/dev/null || true)" == "${SWIFTFORMAT_VERSION}" ]]
}

swiftlint_installed() {
  [[ -x "${BIN_DIR}/swiftlint" ]] \
    && [[ "$("${BIN_DIR}/swiftlint" version 2>/dev/null || true)" == "${SWIFTLINT_VERSION}" ]]
}

oxlint_installed() {
  [[ -x "${BIN_DIR}/oxlint" ]] \
    && [[ "$("${BIN_DIR}/oxlint" --version 2>/dev/null || true)" == "Version: ${OXLINT_VERSION}" ]]
}

oxfmt_installed() {
  [[ -x "${BIN_DIR}/oxfmt" ]] \
    && [[ "$("${BIN_DIR}/oxfmt" --version 2>/dev/null || true)" == "Version: ${OXFMT_VERSION}" ]]
}

typescript_installed() {
  [[ -f "${TOOLS_DIR}/typescript/bin/tsc" ]] \
    && [[ "$(node "${TOOLS_DIR}/typescript/bin/tsc" --version 2>/dev/null || true)" == "Version ${TYPESCRIPT_VERSION}" ]]
}

if { [[ "$INSTALL_SWIFTFORMAT" != true ]] || swiftformat_installed; } \
  && { [[ "$INSTALL_SWIFTLINT" != true ]] || swiftlint_installed; } \
  && { [[ "$INSTALL_OXLINT" != true ]] || oxlint_installed; } \
  && { [[ "$INSTALL_OXFMT" != true ]] || oxfmt_installed; } \
  && { [[ "$INSTALL_TYPESCRIPT" != true ]] || typescript_installed; }
then
  log "==> Requested lint tools already installed"
  exit 0
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

if [[ "$INSTALL_TYPESCRIPT" == true ]] && ! typescript_installed; then
  command -v node >/dev/null 2>&1 || fail "Node.js is required to run TypeScript."
  install_typescript
fi

case "$OS" in
  Darwin)
    SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
    SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
    case "$ARCH" in
      x86_64)
        OXC_TARGET="x86_64-apple-darwin"
        OXLINT_SHA256="$OXLINT_SHA256_DARWIN_X86_64"
        OXFMT_SHA256="$OXFMT_SHA256_DARWIN_X86_64"
        ;;
      arm64)
        OXC_TARGET="aarch64-apple-darwin"
        OXLINT_SHA256="$OXLINT_SHA256_DARWIN_ARM64"
        OXFMT_SHA256="$OXFMT_SHA256_DARWIN_ARM64"
        ;;
      *)
        fail "Unsupported macOS arch: ${ARCH}"
        ;;
    esac

    if [[ "$INSTALL_SWIFTFORMAT" == true ]] && ! swiftformat_installed; then
      install_zip_binary "SwiftFormat ${SWIFTFORMAT_VERSION}" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256_DARWIN" "swiftformat"
    fi
    if [[ "$INSTALL_SWIFTLINT" == true ]] && ! swiftlint_installed; then
      install_zip_binary "SwiftLint ${SWIFTLINT_VERSION}" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256_DARWIN" "swiftlint"
    fi
    if [[ "$INSTALL_OXLINT" == true ]] && ! oxlint_installed; then
      OXLINT_URL="https://github.com/oxc-project/oxc/releases/download/apps_v${OXC_APPS_RELEASE}/oxlint-${OXC_TARGET}.tar.gz"
      install_tar_binary "oxlint ${OXLINT_VERSION}" "$OXLINT_URL" "$OXLINT_SHA256" "oxlint-${OXC_TARGET}" "oxlint"
    fi
    if [[ "$INSTALL_OXFMT" == true ]] && ! oxfmt_installed; then
      OXFMT_URL="https://github.com/oxc-project/oxc/releases/download/apps_v${OXC_APPS_RELEASE}/oxfmt-${OXC_TARGET}.tar.gz"
      install_tar_binary "oxfmt ${OXFMT_VERSION}" "$OXFMT_URL" "$OXFMT_SHA256" "oxfmt-${OXC_TARGET}" "oxfmt"
    fi
    ;;
  Linux)
    case "$ARCH" in
      x86_64)
        SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux.zip"
        SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip"
        SWIFTFORMAT_BINARY="swiftformat_linux"
        SWIFTFORMAT_SHA256="$SWIFTFORMAT_SHA256_LINUX_X86_64"
        SWIFTLINT_SHA256="$SWIFTLINT_SHA256_LINUX_X86_64"
        OXC_TARGET="x86_64-unknown-linux-gnu"
        OXLINT_SHA256="$OXLINT_SHA256_LINUX_X86_64"
        OXFMT_SHA256="$OXFMT_SHA256_LINUX_X86_64"
        ;;
      aarch64|arm64)
        SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux_aarch64.zip"
        SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_arm64.zip"
        SWIFTFORMAT_BINARY="swiftformat_linux_aarch64"
        SWIFTFORMAT_SHA256="$SWIFTFORMAT_SHA256_LINUX_ARM64"
        SWIFTLINT_SHA256="$SWIFTLINT_SHA256_LINUX_ARM64"
        OXC_TARGET="aarch64-unknown-linux-gnu"
        OXLINT_SHA256="$OXLINT_SHA256_LINUX_ARM64"
        OXFMT_SHA256="$OXFMT_SHA256_LINUX_ARM64"
        ;;
      *)
        fail "Unsupported Linux arch: ${ARCH}"
        ;;
    esac

    if { [[ "$INSTALL_SWIFTFORMAT" == true ]] && [[ -z "$SWIFTFORMAT_SHA256" ]]; } \
      || { [[ "$INSTALL_SWIFTLINT" == true ]] && [[ -z "$SWIFTLINT_SHA256" ]]; }
    then
      log "WARN: Linux SHA256 verification not configured for ${ARCH}; installing anyway."
    fi
    if [[ "$INSTALL_SWIFTFORMAT" == true ]] && ! swiftformat_installed; then
      install_zip_binary "SwiftFormat ${SWIFTFORMAT_VERSION}" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256" "$SWIFTFORMAT_BINARY" "swiftformat"
    fi
    if [[ "$INSTALL_SWIFTLINT" == true ]] && ! swiftlint_installed; then
      install_zip_binary "SwiftLint ${SWIFTLINT_VERSION}" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256" "swiftlint"
    fi
    if [[ "$INSTALL_OXLINT" == true ]] && ! oxlint_installed; then
      OXLINT_URL="https://github.com/oxc-project/oxc/releases/download/apps_v${OXC_APPS_RELEASE}/oxlint-${OXC_TARGET}.tar.gz"
      install_tar_binary "oxlint ${OXLINT_VERSION}" "$OXLINT_URL" "$OXLINT_SHA256" "oxlint-${OXC_TARGET}" "oxlint"
    fi
    if [[ "$INSTALL_OXFMT" == true ]] && ! oxfmt_installed; then
      OXFMT_URL="https://github.com/oxc-project/oxc/releases/download/apps_v${OXC_APPS_RELEASE}/oxfmt-${OXC_TARGET}.tar.gz"
      install_tar_binary "oxfmt ${OXFMT_VERSION}" "$OXFMT_URL" "$OXFMT_SHA256" "oxfmt-${OXC_TARGET}" "oxfmt"
    fi
    ;;
  *)
    fail "Unsupported OS: ${OS}"
    ;;
esac

log "==> Installed lint tools to ${BIN_DIR}"
if [[ "$INSTALL_SWIFTFORMAT" == true ]]; then
  "${BIN_DIR}/swiftformat" --version
fi
if [[ "$INSTALL_SWIFTLINT" == true ]]; then
  "${BIN_DIR}/swiftlint" version
fi
if [[ "$INSTALL_OXLINT" == true ]]; then
  "${BIN_DIR}/oxlint" --version
fi
if [[ "$INSTALL_OXFMT" == true ]]; then
  "${BIN_DIR}/oxfmt" --version
fi
if [[ "$INSTALL_TYPESCRIPT" == true ]]; then
  node "${TOOLS_DIR}/typescript/bin/tsc" --version
fi

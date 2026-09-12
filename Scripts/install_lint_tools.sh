#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/.build/lint-tools"
BIN_DIR="${TOOLS_DIR}/bin"

SWIFTFORMAT_VERSION="0.61.1"
SWIFTLINT_VERSION="0.65.1"
OXLINT_VERSION="1.82.0"
OXFMT_VERSION="0.67.0"
OXC_APPS_RELEASE="1.82.0"
TYPESCRIPT_VERSION="5.9.3"

SWIFTFORMAT_SHA256_DARWIN="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTLINT_SHA256_DARWIN="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
SWIFTFORMAT_SHA256_LINUX_X86_64="7bc8706e3fd51963f1f29eb99098ebdf482f3497fa527c68e6cf75cbee29c77a"
SWIFTLINT_SHA256_LINUX_X86_64="caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d"
SWIFTFORMAT_SHA256_LINUX_ARM64="42a35b557a6d56975fba3a48e78d39ab5388c8faac65d4819f25d3e20c7504c0"
SWIFTLINT_SHA256_LINUX_ARM64="9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8"
OXLINT_SHA256_DARWIN_X86_64="42206a631be5a65e4f32de5983e9e8991197ef2756870c257a5db2e6f493a86f"
OXLINT_SHA256_DARWIN_ARM64="e420b7f67fc1ec5426c932a7e5b07e546c67c661c9b7116ba6c8c9648ff96074"
OXLINT_SHA256_LINUX_X86_64="2284a516360c42166b9f0b1c1aa6920322d3385d93a7ff7061d2d8ed77ec1e35"
OXLINT_SHA256_LINUX_ARM64="0c59db096ce59b5d690b3e7c75d5b729e565e730634f067d352ce7eb857d944a"
OXFMT_SHA256_DARWIN_X86_64="20e82289d7f41399a4d9670a0d78135e14dbe04f421163be2cc0c120d3ad4fa1"
OXFMT_SHA256_DARWIN_ARM64="2c0a483844922828a8b9b78684cb01e9283242250cad5d7303eb2cce0e027175"
OXFMT_SHA256_LINUX_X86_64="7fcda58499e25a261069022f3c6b9827da4bcc729a6181214c0645b3e30d1603"
OXFMT_SHA256_LINUX_ARM64="b738733446781432fc6874b9e9328def0c5cd1c69335bcf258078e429e4887e1"
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

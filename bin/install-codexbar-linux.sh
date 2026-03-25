#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SWIFTLY_VERSION="1.1.1"
SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
SWIFTLY_ENV_SH="${SWIFTLY_HOME_DIR}/env.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is intended for Linux/Ubuntu only." >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

bootstrap_swift() {
  local arch tmp_dir archive
  arch="$(uname -m)"
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/swiftly-${SWIFTLY_VERSION}-${arch}.tar.gz"

  echo "Swift toolchain not found. Bootstrapping via Swiftly ${SWIFTLY_VERSION}..."
  need_cmd curl
  need_cmd tar

  curl -fL "https://download.swift.org/swiftly/linux/swiftly-${SWIFTLY_VERSION}-${arch}.tar.gz" -o "$archive"
  tar -zxf "$archive" -C "$tmp_dir"

  (
    cd "$tmp_dir"
    ./swiftly init --quiet-shell-followup
  )

  if [[ -f "$SWIFTLY_ENV_SH" ]]; then
    # shellcheck disable=SC1090
    source "$SWIFTLY_ENV_SH"
    hash -r
  fi

  if ! command -v swift >/dev/null 2>&1; then
    echo "Swiftly finished but 'swift' is still not on PATH." >&2
    echo "Source ${SWIFTLY_ENV_SH} and retry." >&2
    exit 1
  fi

  rm -rf "$tmp_dir"
}

if ! command -v swift >/dev/null 2>&1; then
  bootstrap_swift
fi

if [[ -f "$SWIFTLY_ENV_SH" ]]; then
  # shellcheck disable=SC1090
  source "$SWIFTLY_ENV_SH"
  hash -r
fi

cd "$ROOT_DIR"

swift build -c release --product CodexBarCLI
swift build -c release --product CodexBarLinux

BIN_DIR="${HOME}/.local/bin"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="${APP_DIR%/}"
DESKTOP_DIR="${APP_DIR}/applications"
ICON_DIR="${APP_DIR}/icons/hicolor/512x512/apps"

mkdir -p "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"

install -m 755 ".build/release/CodexBarCLI" "${BIN_DIR}/CodexBarCLI"
install -m 755 ".build/release/CodexBarLinux" "${BIN_DIR}/CodexBarLinux"
ln -sf "${BIN_DIR}/CodexBarCLI" "${BIN_DIR}/codexbar"
ln -sf "${BIN_DIR}/CodexBarLinux" "${BIN_DIR}/codexbar-linux"
install -m 644 "codexbar.png" "${ICON_DIR}/codexbar-linux.png"

cat > "${DESKTOP_DIR}/codexbar-linux.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=CodexBar Linux
Comment=Ubuntu dashboard for CodexBar providers
Exec=${BIN_DIR}/codexbar-linux launch
Icon=codexbar-linux
Terminal=false
Categories=Utility;Development;
EOF

update-desktop-database "${DESKTOP_DIR}" >/dev/null 2>&1 || true
gtk-update-icon-cache "${APP_DIR}/icons/hicolor" >/dev/null 2>&1 || true

echo "Installed:"
echo "  ${BIN_DIR}/codexbar"
echo "  ${BIN_DIR}/codexbar-linux"
echo
echo "Try:"
echo "  codexbar --format json --pretty"
echo "  codexbar-linux launch"
echo "  codexbar-linux stop"

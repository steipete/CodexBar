#!/usr/bin/env bash
# Builds a .deb package for CodexBar on Linux (x86_64 or aarch64).
#
# What gets installed:
#   /usr/bin/CodexBarCLI                       — statically linked CLI binary
#   /usr/bin/codexbar                          — symlink → CodexBarCLI
#   /usr/bin/codexbar-tray                     — Python tray daemon
#   /usr/bin/codexbar-linux-fetcher            — Python cookie/sidecar fetcher
#   /usr/share/icons/hicolor/512x512/apps/codexbar.png
#   /usr/share/applications/codexbar.desktop   — app launcher entry
#   /etc/xdg/autostart/codexbar-tray.desktop   — start tray on login
#
# Usage:
#   ./Scripts/package_deb.sh [--version VERSION] [--bin PATH] [--out-dir DIR]
#
# Requires: swift (to build if binary missing), dpkg-deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── defaults ──────────────────────────────────────────────────────────────────
VERSION=""
BIN_PATH=""
OUT_DIR="$REPO_ROOT"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2";  shift 2 ;;
    --bin)      BIN_PATH="$2"; shift 2 ;;
    --out-dir)  OUT_DIR="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── resolve version ───────────────────────────────────────────────────────────
if [[ -z "$VERSION" ]]; then
  if [[ -f "$REPO_ROOT/version.env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/version.env"
    VERSION="${MARKETING_VERSION:-}"
  fi
fi
if [[ -z "$VERSION" ]]; then
  echo "Could not determine version. Pass --version or ensure version.env exists." >&2
  exit 1
fi

# ── resolve architecture ──────────────────────────────────────────────────────
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64)         DEB_ARCH="amd64" ;;
  aarch64|arm64)  DEB_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $MACHINE" >&2
    exit 1
    ;;
esac

# ── build CLI binary if needed ────────────────────────────────────────────────
if [[ -z "$BIN_PATH" ]]; then
  BIN_PATH="$REPO_ROOT/.build/release/CodexBarCLI"
fi
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH — building..."
  cd "$REPO_ROOT"
  swift build -c release --product CodexBarCLI --static-swift-stdlib
fi
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Build succeeded but binary not found at $BIN_PATH" >&2
  exit 1
fi

# ── check dependencies ────────────────────────────────────────────────────────
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found. Install it with: sudo apt-get install -y dpkg" >&2
  exit 1
fi

ICON_SRC="$REPO_ROOT/docs/icon.png"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Icon not found at $ICON_SRC" >&2
  exit 1
fi

TRAY_SRC="$REPO_ROOT/bin/codexbar-tray"
if [[ ! -f "$TRAY_SRC" ]]; then
  echo "Tray script not found at $TRAY_SRC" >&2
  exit 1
fi

FETCHER_SRC="$REPO_ROOT/bin/codexbar-linux-fetcher"
if [[ ! -f "$FETCHER_SRC" ]]; then
  echo "Linux fetcher script not found at $FETCHER_SRC" >&2
  exit 1
fi

# ── assemble package tree ─────────────────────────────────────────────────────
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "$PKG_DIR"' EXIT

install -d "$PKG_DIR/DEBIAN"
install -d "$PKG_DIR/usr/bin"
install -d "$PKG_DIR/usr/share/icons/hicolor/512x512/apps"
install -d "$PKG_DIR/usr/share/applications"
install -d "$PKG_DIR/etc/xdg/autostart"

# CLI binary + symlink
install -m 0755 "$BIN_PATH"  "$PKG_DIR/usr/bin/CodexBarCLI"
ln -s "CodexBarCLI"          "$PKG_DIR/usr/bin/codexbar"

# tray daemon
install -m 0755 "$TRAY_SRC"    "$PKG_DIR/usr/bin/codexbar-tray"
install -m 0755 "$FETCHER_SRC" "$PKG_DIR/usr/bin/codexbar-linux-fetcher"

# icon
install -m 0644 "$ICON_SRC"  "$PKG_DIR/usr/share/icons/hicolor/512x512/apps/codexbar.png"

# app launcher .desktop — clicking opens the tray (or if already running, brings browser)
cat > "$PKG_DIR/usr/share/applications/codexbar.desktop" <<'DESKTOP'
[Desktop Entry]
Name=CodexBar
Comment=AI coding-provider usage tracker
Exec=codexbar-tray
Icon=codexbar
Terminal=false
Type=Application
Categories=Utility;Development;
Keywords=AI;Claude;Codex;Gemini;Cursor;usage;tokens;limits;
StartupNotify=false
DESKTOP

# autostart .desktop — starts tray daemon on login
cat > "$PKG_DIR/etc/xdg/autostart/codexbar-tray.desktop" <<'AUTOSTART'
[Desktop Entry]
Name=CodexBar Tray
Comment=AI coding-provider usage tracker (tray daemon)
Exec=codexbar-tray
Icon=codexbar
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=false
X-GNOME-Autostart-enabled=true
AUTOSTART

# post-install: refresh icon cache + create starter config
cat > "$PKG_DIR/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

# ── icon / desktop caches ─────────────────────────────────────────────────────
if command -v update-icon-caches >/dev/null 2>&1; then
  update-icon-caches /usr/share/icons/hicolor 2>/dev/null || true
elif command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
fi

# ── create starter config for the installing user ────────────────────────────
# $SUDO_USER is set when running via sudo; fall back to $USER or root
TARGET_USER="${SUDO_USER:-${USER:-root}}"
if [ "$TARGET_USER" = "root" ]; then
  TARGET_HOME="/root"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)" || true
  TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"
fi

CONFIG_DIR="$TARGET_HOME/.codexbar"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"
# Only write if no config exists yet (never overwrite user tokens)
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<'CONFIG'
{
  "version": 1,
  "providers": [
    { "id": "claude",  "enabled": true, "source": "cli" },
    { "id": "codex",   "enabled": true },
    { "id": "cursor",  "enabled": true }
  ]
}
CONFIG
  chown -R "$TARGET_USER" "$CONFIG_DIR" 2>/dev/null || true
fi

# ── print setup instructions ──────────────────────────────────────────────────
cat <<'MSG'

╔══════════════════════════════════════════════════════════════════════╗
║                   CodexBar installed successfully!                   ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  CLAUDE  — works automatically via `claude` CLI.                    ║
║            Install: npm i -g @anthropic-ai/claude-code              ║
║                                                                      ║
║  CODEX   — works automatically via `codex` CLI.                     ║
║            Install: npm i -g @openai/codex                          ║
║            Then run: codex login                                     ║
║                                                                      ║
║  CURSOR  — needs a session token (stored in Chrome's encrypted       ║
║            keyring, not accessible from the terminal).              ║
║            1. Open cursor.com in Firefox (or Chrome DevTools)       ║
║            2. Find cookie: WorkosCursorSessionToken                  ║
║            3. Add to ~/.codexbar/config.json:                        ║
║               "sessionToken": "<value>"  (under id=cursor)          ║
║                                                                      ║
║  To start: codexbar-tray &                                           ║
║  Dashboard: http://localhost:8081                                    ║
╚══════════════════════════════════════════════════════════════════════╝

MSG
POSTINST
chmod 0755 "$PKG_DIR/DEBIAN/postinst"

# post-remove: clean up icon cache
cat > "$PKG_DIR/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if command -v update-icon-caches >/dev/null 2>&1; then
  update-icon-caches /usr/share/icons/hicolor 2>/dev/null || true
elif command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
fi
POSTRM
chmod 0755 "$PKG_DIR/DEBIAN/postrm"

INSTALLED_SIZE="$(du -sk "$PKG_DIR/usr" "$PKG_DIR/etc" | awk '{s+=$1} END{print s}')"

# ── DEBIAN/control ────────────────────────────────────────────────────────────
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: codexbar
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Peter Steinberger <steipete@gmail.com>
Installed-Size: $INSTALLED_SIZE
Depends: python3 (>= 3.9), python3-gi, python3-gi-cairo, python3-cryptography, gir1.2-gtk-3.0, gir1.2-ayatanaappindicator3-0.1, gir1.2-webkit2-4.1 | gir1.2-webkit2-4.0, gnome-shell-extension-appindicator, x-terminal-emulator
Section: utils
Priority: optional
Homepage: https://codexbar.app
Description: AI coding-provider usage tracker
 CodexBar tracks AI coding-provider limits and usage windows.
 .
 On Linux this package provides:
  - codexbar CLI for API-key and OAuth-based providers
  - A native GNOME system tray icon (top bar) via codexbar-tray
  - A web dashboard at http://localhost:8080 (opened on click)
 .
 Web/browser-backed providers are macOS-only.
EOF

# ── DEBIAN/copyright ──────────────────────────────────────────────────────────
cat > "$PKG_DIR/DEBIAN/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: codexbar
Upstream-Contact: steipete@gmail.com
Source: https://github.com/steipete/CodexBar

Files: *
Copyright: Peter Steinberger
License: MIT
EOF

# ── build .deb ────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
DEB_FILE="${OUT_DIR}/codexbar_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG_DIR" "$DEB_FILE"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$DEB_FILE" > "${DEB_FILE}.sha256"
else
  shasum -a 256 "$DEB_FILE" > "${DEB_FILE}.sha256"
fi

echo ""
echo "Package: $DEB_FILE"
echo "SHA256:  $(awk '{print $1}' "${DEB_FILE}.sha256")"
echo ""
echo "Install with:"
echo "  sudo dpkg -i $DEB_FILE"
echo "  sudo apt-get install -f   # install any missing dependencies"

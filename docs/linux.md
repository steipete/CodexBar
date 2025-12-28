---
summary: "Linux support for CodexBar CLI and system tray."
read_when:
  - Running CodexBar on Linux
  - Setting up the Linux tray application
  - Troubleshooting Linux-specific issues
---

# Linux Support

CodexBar provides full Linux support via the CLI and a Python-based system tray application.

## Supported Providers on Linux

| Provider | Linux Support | Notes |
|----------|--------------|-------|
| Codex | Yes | CLI-based, requires `codex` binary in PATH |
| Claude | Yes | CLI + OAuth, requires `claude` binary in PATH |
| Cursor | Yes | Chrome cookie import or `CURSOR_COOKIE_HEADER` env var |
| Gemini | Yes | CLI-based, requires `gemini` binary in PATH |
| Antigravity | Yes | Local language server probe |
| Windsurf | Yes | Firebase token from Chrome IndexedDB or `WINDSURF_TOKEN` env var |
| GitHub Copilot | Yes | Chrome cookie import |
| z.ai | Yes | API token required |
| Factory/Droid | No | macOS only (requires Safari/WebKit) |

## CLI Installation

### From Source (Recommended)

```bash
# Requires Swift 6.0+
swift build -c release --product CodexBarCLI
cp .build/release/CodexBarCLI ~/.local/bin/codexbar
```

### From Release

```bash
# Download from GitHub Releases
tar -xzf CodexBarCLI-<version>-linux-x86_64.tar.gz
mv codexbar ~/.local/bin/
```

## CLI Usage

```bash
# Show all providers
codexbar usage --provider all --format pretty

# JSON output for scripting
codexbar usage --provider claude --format json

# Specific providers
codexbar usage --provider cursor
codexbar usage --provider copilot
codexbar usage --provider windsurf
```

## System Tray

A GTK+AppIndicator-based system tray provides a native Linux experience with live usage display.

### Dependencies

```bash
# Ubuntu/Debian
sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
pip install pystray pillow

# Arch Linux
sudo pacman -S python-gobject libappindicator-gtk3
pip install pystray pillow

# Fedora
sudo dnf install python3-gobject libappindicator-gtk3
pip install pystray pillow
```

### Running the Tray

```bash
# From the repo
python3 Sources/CodexBarLinux/codexbar_tray.py

# Or create a virtual environment
python3 -m venv /tmp/codexbar-venv
source /tmp/codexbar-venv/bin/activate
pip install pystray pillow
python3 Sources/CodexBarLinux/codexbar_tray.py
```

### Tray Features

- Live usage display with Unicode progress bars
- Auto-refresh every 60 seconds
- Manual refresh via menu
- Click "Copy CLI" to copy the CLI command to clipboard
- Displays all configured providers with:
  - Provider name and plan type
  - Account email
  - Session/weekly usage with reset times
  - Visual progress bars

### Autostart

To start the tray on login, create a `.desktop` file:

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/codexbar-tray.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=CodexBar Tray
Exec=/usr/bin/python3 /path/to/CodexBar/Sources/CodexBarLinux/codexbar_tray.py
Icon=utilities-system-monitor
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
```

## Provider-Specific Setup

### Claude

Claude uses the OAuth credentials from the CLI:

```bash
# Ensure Claude is logged in
claude login
claude --version

# CodexBar reads credentials from:
# - Keychain (via security CLI)
# - ~/.claude/.credentials.json
```

### Cursor

Cursor requires browser session cookies from Chrome:

```bash
# Option 1: Sign in to cursor.com in Chrome
# CodexBar auto-imports cookies from Chrome's SQLite database

# Option 2: Manual cookie header
export CURSOR_COOKIE_HEADER="WorkosCursorSessionToken=xxx; ..."
codexbar usage --provider cursor
```

### Windsurf

Windsurf uses Firebase tokens:

```bash
# Option 1: Auto-extract from Chrome IndexedDB (requires pysqlite3)
# Just sign in to Windsurf and CodexBar extracts the token

# Option 2: Manual token
export WINDSURF_TOKEN="your-firebase-access-token"
codexbar usage --provider windsurf

# To get the token manually:
# 1. Open Chrome DevTools on windsurf.com
# 2. Application > IndexedDB > firebaseLocalStorageDb
# 3. Find the access_token value
```

### GitHub Copilot

GitHub Copilot requires GitHub session cookies:

```bash
# Sign in to github.com in Chrome
# CodexBar auto-imports the session cookies
codexbar usage --provider copilot
```

## Troubleshooting

### CLI not found

Ensure `~/.local/bin` is in your PATH:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Provider binary not found

CodexBar searches these paths:
1. Login shell PATH (from `$SHELL -l -i -c 'echo $PATH'`)
2. Current `$PATH`
3. Common locations: `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`

For CLIs installed via nvm/fnm/mise, ensure your shell rc file exports the correct PATH.

### Chrome cookie access denied

On some systems, Chrome's cookie database may be locked:

```bash
# Close Chrome completely, then try again
pkill chrome
codexbar usage --provider cursor
```

### Tray not appearing

For GNOME with Wayland, install the AppIndicator extension:

```bash
sudo apt install gnome-shell-extension-appindicator
# Then enable via Extensions app or gnome-extensions
```

### Swift build fails

Ensure Swift 6.0+ is installed:

```bash
swift --version
# Should show Swift 6.0 or later

# On Ubuntu, install from swift.org:
# https://www.swift.org/install/linux/
```

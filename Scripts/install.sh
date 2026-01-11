#!/usr/bin/env bash
set -euo pipefail

# Scripts/install.sh
# Installs CodexBar.app to /Applications and links the CLI.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/CodexBar.app"
DEST_APP="/Applications/CodexBar.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "❌  CodexBar.app not found in project root."
    echo "    Run ./Scripts/package_app.sh first to build it."
    exit 1
fi

echo "📦  Installing CodexBar..."

# 1. Install .app
if [[ -d "$DEST_APP" ]]; then
    echo "    Removing existing app at $DEST_APP..."
    rm -rf "$DEST_APP"
fi

echo "    Copying to $DEST_APP..."
cp -R "$SOURCE_APP" "$DEST_APP"
xattr -cr "$DEST_APP" # Ensure quarantine is cleared

# 2. Install CLI
echo "🛠   Installing CLI tools..."
# We use the existing bin/install-codexbar-cli.sh logic but adapted 
# since we know where we just put the app.

CLI_HELPER="$DEST_APP/Contents/Helpers/CodexBarCLI"
if [[ ! -f "$CLI_HELPER" ]]; then
    echo "⚠️   CLI helper binary not found inside app bundle. Skipping CLI install."
else
    # Check if we can write to /usr/local/bin without sudo
    TARGET_DIR="/usr/local/bin"
    TARGET_LINK="$TARGET_DIR/codexbar"
    
    NEEDS_SUDO=false
    
    if [[ -d "$TARGET_DIR" ]]; then
        if [[ ! -w "$TARGET_DIR" ]]; then
            NEEDS_SUDO=true
        fi
    else
        # If directory doesn't exist, check if we can create it (parent writable?)
        PARENT_DIR="$(dirname "$TARGET_DIR")"
        if [[ ! -w "$PARENT_DIR" ]]; then
            NEEDS_SUDO=true
        fi
    fi

    echo "    Linking 'codexbar' to $TARGET_LINK"
    
    if $NEEDS_SUDO; then
        echo "    (Admin password required to install CLI to /usr/local/bin)"
        # Create a small script to run with sudo
        INSTALL_SCRIPT=$(mktemp)
        cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
mkdir -p "$TARGET_DIR"
ln -sf "$CLI_HELPER" "$TARGET_LINK"
EOF
        chmod +x "$INSTALL_SCRIPT"
        if sudo "$INSTALL_SCRIPT"; then
             echo "    ✅ CLI installed."
        else
             echo "    ❌ CLI install failed."
        fi
        rm "$INSTALL_SCRIPT"
    else
        mkdir -p "$TARGET_DIR"
        ln -sf "$CLI_HELPER" "$TARGET_LINK"
        echo "    ✅ CLI installed."
    fi
fi

echo ""
echo "🎉  Installation complete!"
echo "    Run 'open -a CodexBar' to start."

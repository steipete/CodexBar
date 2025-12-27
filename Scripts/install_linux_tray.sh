#!/usr/bin/env bash
# CodexBar Linux Tray Installer
# Installs the Python-based system tray frontend for Ubuntu/Linux.
#
# Usage:
#   ./Scripts/install_linux_tray.sh
#
# This script will:
#   1. Build CodexBarCLI from source (if Swift is available)
#   2. Create a Python virtual environment with dependencies
#   3. Install the tray application to ~/.local
#   4. Optionally create an autostart entry

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INSTALL_DIR="$HOME/.local/bin"
INSTALL_LIB="$HOME/.local/lib/codexbar"
VENV_DIR="$INSTALL_LIB/venv"

# Check for required tools
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required but not found."
        log_error "Install with: sudo apt install python3 python3-venv"
        exit 1
    fi
    
    # Check for venv module
    if ! python3 -c "import venv" &> /dev/null; then
        log_error "Python venv module is required."
        log_error "Install with: sudo apt install python3-venv"
        exit 1
    fi
    
    log_info "Python 3 found: $(python3 --version)"
}

# Install Python dependencies in a venv
install_python_deps() {
    log_info "Creating Python virtual environment..."

    mkdir -p "$INSTALL_LIB"

    # Create venv with system packages (needed for GTK/GI bindings)
    python3 -m venv "$VENV_DIR" --system-site-packages

    log_info "Installing Python dependencies..."
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install pystray pillow || {
        log_error "Failed to install Python packages."
        exit 1
    }
    
    log_info "Python dependencies installed in venv."
}

# Build CLI from source
build_cli() {
    if command -v swift &> /dev/null; then
        log_info "Building CodexBarCLI..."
        cd "$PROJECT_DIR"
        swift build -c release --product CodexBarCLI || {
            log_warn "Swift build failed. You may need to build manually."
            return 1
        }
        log_info "CLI built successfully."
        return 0
    else
        log_warn "Swift not found. Skipping CLI build."
        return 1
    fi
}

# Install to user's local bin
install_files() {
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_LIB"
    
    # Copy Python tray script
    cp "$PROJECT_DIR/Sources/CodexBarLinux/codexbar_tray.py" "$INSTALL_LIB/codexbar_tray.py"
    chmod +x "$INSTALL_LIB/codexbar_tray.py"
    
    # Create wrapper script that uses the venv
    cat > "$INSTALL_DIR/codexbar-tray" << EOF
#!/usr/bin/env bash
exec "$VENV_DIR/bin/python" "$INSTALL_LIB/codexbar_tray.py" "\$@"
EOF
    chmod +x "$INSTALL_DIR/codexbar-tray"
    
    # Copy CLI if built
    if [[ -f "$PROJECT_DIR/.build/release/CodexBarCLI" ]]; then
        cp "$PROJECT_DIR/.build/release/CodexBarCLI" "$INSTALL_DIR/codexbar"
        chmod +x "$INSTALL_DIR/codexbar"
        log_info "CLI installed to $INSTALL_DIR/codexbar"
    fi
    
    log_info "Tray app installed to $INSTALL_DIR/codexbar-tray"
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log_warn "$INSTALL_DIR is not in your PATH."
        log_warn "Add this to your ~/.bashrc or ~/.zshrc:"
        log_warn '  export PATH="$HOME/.local/bin:$PATH"'
    fi
}

# Create autostart entry
setup_autostart() {
    local AUTOSTART_DIR="$HOME/.config/autostart"
    local DESKTOP_FILE="$AUTOSTART_DIR/codexbar-tray.desktop"
    
    read -p "Start CodexBar automatically on login? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$AUTOSTART_DIR"
        cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=CodexBar
Comment=API usage tracker for Codex, Claude, Gemini
Exec=$INSTALL_DIR/codexbar-tray
Icon=utilities-system-monitor
Terminal=false
Categories=Utility;
StartupNotify=false
X-GNOME-Autostart-enabled=true
EOF
        log_info "Autostart entry created."
    fi
}

# Main
main() {
    echo "╔════════════════════════════════════════════╗"
    echo "║   CodexBar Linux Tray Installer            ║"
    echo "╚════════════════════════════════════════════╝"
    echo
    
    check_dependencies
    install_python_deps
    build_cli || true
    install_files
    setup_autostart
    
    echo
    log_info "Installation complete!"
    echo
    echo "To start CodexBar tray:"
    echo "  codexbar-tray"
    echo
    echo "To run the CLI directly:"
    echo "  codexbar usage --provider claude --source oauth"
}

main "$@"

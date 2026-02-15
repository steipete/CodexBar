#!/bin/bash
set -e

echo "🔧 CodexBar Prompt Minimizer"
echo "============================"
echo ""
echo "This script will configure CodexBar to minimize macOS permission prompts."
echo ""

# Check if app is running
if pgrep -x "CodexBar" > /dev/null; then
    echo "⚠️  CodexBar is currently running. Please quit it first."
    exit 1
fi

echo "📋 Current Configuration:"
echo ""

# Show current provider toggles
echo "Enabled Providers:"
defaults read com.steipete.codexbar providerToggles 2>/dev/null || echo "  (none configured yet)"
echo ""

# Show current data sources
echo "Data Sources:"
echo "  Claude: $(defaults read com.steipete.codexbar claudeUsageDataSource 2>/dev/null || echo 'auto')"
echo "  Codex: $(defaults read com.steipete.codexbar codexUsageDataSource 2>/dev/null || echo 'auto')"
echo ""

echo "🎯 Recommended Configuration (Minimal Prompts):"
echo ""
echo "  ✅ Codex (CLI) - No prompts"
echo "  ✅ Claude (CLI) - No prompts"  
echo "  ✅ Gemini (CLI) - No prompts"
echo "  ⚠️  Augment - Requires browser cookie prompt (unavoidable)"
echo "  ⚠️  Cursor - Requires browser cookie prompt (unavoidable)"
echo "  ❌ Antigravity - Disable (experimental)"
echo ""

read -p "Apply recommended configuration? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "🔧 Applying configuration..."

# Set Claude to CLI-only (avoids keychain)
defaults write com.steipete.codexbar claudeUsageDataSource -string "cli"
echo "  ✓ Claude → CLI mode (no keychain)"

# Set Codex to CLI-only (avoids keychain)
defaults write com.steipete.codexbar codexUsageDataSource -string "cli"
echo "  ✓ Codex → CLI mode (no keychain)"

# Disable Antigravity (experimental, not needed)
defaults write com.steipete.codexbar providerToggles -dict-add antigravity -bool false
echo "  ✓ Antigravity → Disabled"

# Keep Augment enabled (user wants it, accepts browser prompt)
defaults write com.steipete.codexbar providerToggles -dict-add augment -bool true
echo "  ✓ Augment → Enabled (will prompt for browser cookies once)"

# Keep Claude enabled
defaults write com.steipete.codexbar providerToggles -dict-add claude -bool true
echo "  ✓ Claude → Enabled"

# Keep Codex enabled
defaults write com.steipete.codexbar providerToggles -dict-add codex -bool true
echo "  ✓ Codex → Enabled"

# Keep Gemini enabled
defaults write com.steipete.codexbar providerToggles -dict-add gemini -bool true
echo "  ✓ Gemini → Enabled"

# Disable Cursor (requires browser cookies)
defaults write com.steipete.codexbar providerToggles -dict-add cursor -bool false
echo "  ✓ Cursor → Disabled (avoids browser cookie prompt)"

echo ""
echo "✅ Configuration complete!"
echo ""
echo "📝 What to expect:"
echo "  1. First launch: macOS will ask for browser cookie access (for Augment)"
echo "  2. Click 'Allow' ONCE - this is unavoidable for Augment"
echo "  3. No more keychain prompts (Claude/Codex use CLI)"
echo ""
echo "🚀 You can now launch CodexBar."


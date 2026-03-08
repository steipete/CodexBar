#!/bin/bash
# Stop CodexBar and all related Codex processes

echo "🛑 Stopping CodexBar..."
killall CodexBar 2>/dev/null && echo "✅ CodexBar stopped" || echo "ℹ️  CodexBar not running"

echo ""
echo "🔍 Checking for other Codex processes..."
CODEX_PIDS=$(ps aux | grep -i "codex" | grep -v "grep\|CodexBar\|cursor" | awk '{print $2}')

if [ -z "$CODEX_PIDS" ]; then
    echo "✅ No stray Codex processes found"
else
    echo "⚠️  Found Codex processes: $CODEX_PIDS"
    echo "Killing them..."
    echo "$CODEX_PIDS" | xargs kill -9 2>/dev/null
    echo "✅ Cleaned up Codex processes"
fi

echo ""
echo "📊 Current status:"
ps aux | grep -i "CodexBar\|codex" | grep -v grep || echo "All clean!"

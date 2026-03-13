#!/bin/bash
# Start CodexBar (release build)

APP_PATH="${1:-/Users/vuc229/Documents/Development/Active-Projects/specialized/CodexBar/CodexBar.app}"

echo "🚀 Starting CodexBar..."

if [ ! -d "$APP_PATH" ]; then
    echo "❌ CodexBar.app not found at: $APP_PATH"
    echo "💡 Build it first: ./Scripts/package_app.sh release"
    exit 1
fi

# Check if already running
if pgrep -x "CodexBar" > /dev/null; then
    echo "⚠️  CodexBar is already running"
    read -p "Stop and restart? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        killall CodexBar
        sleep 1
    else
        echo "Cancelled"
        exit 0
    fi
fi

open "$APP_PATH"
sleep 2

if pgrep -x "CodexBar" > /dev/null; then
    echo "✅ CodexBar started successfully"
    echo ""
    echo "📊 Process info:"
    ps aux | grep CodexBar | grep -v grep
else
    echo "❌ Failed to start CodexBar"
    echo "💡 Check Console.app for errors (filter: CodexBar)"
    exit 1
fi

#!/usr/bin/env bash
# Quick test script to verify universal binary support

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== Testing Universal Binary Support ==="
echo ""

# Step 1: Build for both architectures
echo "Step 1: Building universal binary (arm64 + x86_64)..."
echo "This will take several minutes (building for both architectures)..."
ARCHES="arm64 x86_64" ./Scripts/package_app.sh release

# Step 2: Check the architectures in the built binary
echo ""
echo "Step 2: Verifying architectures in CodexBar binary..."
BINARY="$ROOT/CodexBar.app/Contents/MacOS/CodexBar"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: CodexBar binary not found at $BINARY"
    exit 1
fi

ARCHES_IN_BINARY=$(lipo -archs "$BINARY")
echo "Architectures found: $ARCHES_IN_BINARY"

# Step 3: Verify both architectures are present
if [[ "$ARCHES_IN_BINARY" == *"arm64"* ]] && [[ "$ARCHES_IN_BINARY" == *"x86_64"* ]]; then
    echo "✅ SUCCESS: Binary contains both arm64 and x86_64"
else
    echo "❌ FAILED: Binary missing required architectures"
    echo "   Expected: arm64 x86_64"
    echo "   Got: $ARCHES_IN_BINARY"
    exit 1
fi

# Step 4: Check file info
echo ""
echo "Step 3: Binary file information:"
file "$BINARY"

# Step 5: Verify it's a universal binary
echo ""
echo "Step 4: Detailed architecture info:"
lipo -detailed_info "$BINARY" | grep -E "(architecture|cputype|cpusubtype)" | head -6

# Step 6: Test that it can run (on current architecture)
echo ""
echo "Step 5: Testing binary execution (should work on $(uname -m))..."
if "$BINARY" --help >/dev/null 2>&1; then
    echo "✅ Binary executes successfully"
else
    echo "⚠️  Binary execution test inconclusive (may need GUI context)"
fi

echo ""
echo "=== Test Complete ==="
echo ""
echo "To test the app:"
echo "  open $ROOT/CodexBar.app"
echo ""
echo "To verify on an Apple Silicon Mac, transfer the app and run:"
echo "  lipo -archs /path/to/CodexBar.app/Contents/MacOS/CodexBar"

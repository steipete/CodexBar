# Quick Reference: Building for Intel Macs

## TL;DR
CodexBar now builds universal binaries by default. No changes needed - just build normally!

## Build Commands

```bash
# Standard build (universal - arm64 + x86_64)
./Scripts/compile_and_run.sh

# Intel only
ARCHES="x86_64" ./Scripts/package_app.sh

# Apple Silicon only  
ARCHES="arm64" ./Scripts/package_app.sh

# Release (universal)
./Scripts/sign-and-notarize.sh
```

## Verify Architectures

```bash
lipo -archs CodexBar.app/Contents/MacOS/CodexBar
# Expected: x86_64 arm64
```

## Requirements

- macOS 14+ (Sonoma)
- Works on both Intel and Apple Silicon Macs

## Documentation

- Full guide: [docs/intel-mac-support.md](docs/intel-mac-support.md)
- Implementation: [INTEL_MAC_SUPPORT.md](INTEL_MAC_SUPPORT.md)
- Complete summary: [INTEL_BUILD_COMPLETE.md](INTEL_BUILD_COMPLETE.md)

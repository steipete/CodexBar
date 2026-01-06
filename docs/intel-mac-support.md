---
summary: "Building and running CodexBar on Intel Macs"
read_when:
  - Building for Intel (x86_64) Macs
  - Creating universal binaries
  - Troubleshooting architecture-specific issues
---

# Intel Mac Support

CodexBar fully supports Intel (x86_64) Macs running macOS 14+ (Sonoma).

## Universal Binary by Default

As of version 0.17.0, CodexBar builds as a **universal binary** by default, containing both:
- `arm64` (Apple Silicon)
- `x86_64` (Intel)

This means a single `.app` bundle runs natively on both architectures.

## Building

### Standard Build (Universal)
```bash
# Build universal binary (default)
./Scripts/compile_and_run.sh

# Or manually
./Scripts/package_app.sh
```

### Architecture-Specific Builds

If you need a single-architecture build:

```bash
# Intel only
ARCHES="x86_64" ./Scripts/package_app.sh

# Apple Silicon only
ARCHES="arm64" ./Scripts/package_app.sh
```

### Verify Architectures

Check what architectures are in your build:

```bash
lipo -archs CodexBar.app/Contents/MacOS/CodexBar
# Expected output: x86_64 arm64

file CodexBar.app/Contents/MacOS/CodexBar
# Expected: Mach-O universal binary with 2 architectures
```

## Release Builds

The release process (`Scripts/sign-and-notarize.sh`) creates universal binaries by default:

```bash
# Universal release (default)
./Scripts/sign-and-notarize.sh

# Custom architectures (if needed)
ARCHES="x86_64" ./Scripts/sign-and-notarize.sh
```

## Requirements

- **macOS**: 14.0+ (Sonoma or later)
- **Xcode**: Latest version with Swift 6.2+
- **Swift**: 6.2 or later

Both Intel and Apple Silicon Macs can build for both architectures.

## Performance Notes

- Native execution on both platforms
- No Rosetta 2 translation required
- Binary size increases ~2x for universal builds
- No performance difference vs single-arch builds when running natively

## Troubleshooting

### Missing Architecture

If you see "This app is not compatible with this Mac":
1. Check architectures: `lipo -archs CodexBar.app/Contents/MacOS/CodexBar`
2. Rebuild with correct `ARCHES` setting
3. Verify you're running macOS 14+

### Build Failures

If building for x86_64 fails on Apple Silicon:
1. Ensure Xcode Command Line Tools are installed: `xcode-select --install`
2. Check Swift version: `swift --version` (should be 6.2+)
3. Try cleaning: `CODEXBAR_FORCE_CLEAN=1 ./Scripts/package_app.sh`

## CI/CD

For automated builds, universal binaries ensure compatibility across all supported Macs:

```bash
# GitHub Actions, CI servers
ARCHES="arm64 x86_64" ./Scripts/package_app.sh release
```

## See Also

- [Packaging](packaging.md) - Detailed packaging/signing docs
- [Development](DEVELOPMENT.md) - Development setup
- [Releasing](RELEASING.md) - Release process

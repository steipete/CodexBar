---
summary: "Development setup: stable signing and reducing Keychain prompts."
read_when:
  - Setting up local development
  - Reducing Keychain prompts during rebuilds
  - Configuring dev signing
---

# Development Setup Guide

## Reducing Keychain Permission Prompts

When developing CodexBar, you may see frequent keychain permission prompts like:

> **CodexBar wants to access key "Claude Code-credentials" in your keychain.**

This happens because each rebuild creates a new code signature, and macOS treats it as a "different" app.
That can affect both CodexBar-owned entries (`com.steipete.CodexBar`, `com.steipete.codexbar.cache`) and
third-party items such as `Claude Code-credentials`, so an ad-hoc-signed rebuild can keep re-triggering
password/keychain approval dialogs even after you previously chose **Always Allow**.

### Quick Fix (Temporary)

When the prompt appears, click **"Always Allow"** instead of just "Allow". This grants access to the current build.

### Stable Signing

Use an installed **Developer ID Application** signing identity with a Team ID. Create or install it through Xcode → Settings → Accounts →
Manage Certificates, then configure its full name or SHA-1 certificate hash as `APP_IDENTITY`.
For the accepted identity formats and failure cases, see [local identity signing](DEVELOPMENT.md#local-development-build).

`compile_and_run.sh` automatically selects a Developer ID Application identity with a Team ID. Without one, it uses ad-hoc signing. An explicit `APP_IDENTITY` is validated by packaging and fails
if missing, ambiguous, or unable to supply a Team ID; it never silently falls back to another signing mode.

The former `setup_dev_signing.sh` self-signed certificate workflow has been removed because those certificates
have no Apple Team ID for app/widget entitlements. If your shell still sets `APP_IDENTITY='CodexBar Development'`,
replace it with a Developer ID Application identity or unset it to use automatic selection. Apple Development
certificate names can carry personal IDs rather than Team IDs and are no longer auto-selected either. Existing certificates and
Keychain entries are left in place. Consistent signing can reduce prompts, but does not grant access to
third-party credentials automatically.

---

## Cleaning Up Old App Bundles

If you see multiple `CodexBar *.app` bundles in your project directory, you can clean them up:

```bash
# Remove all numbered builds
rm -rf "CodexBar "*.app

# The .gitignore already excludes these patterns:
# - CodexBar.app
# - CodexBar *.app/
```

The build script creates `CodexBar.app` in the project root. Old numbered builds (like `CodexBar 2.app`) are created when Finder can't overwrite the running app.

---

## Development Workflow

### Standard Build & Run

```bash
./Scripts/compile_and_run.sh
```

This script:
1. Kills existing CodexBar instances
2. Runs `swift build` (release mode)
3. Runs the sharded full test suite when `--test` is passed
4. Packages the app with `./Scripts/package_app.sh`
5. Launches `CodexBar.app`
6. Verifies it stays running

Launching an unbundled `CodexBar` executable, including SwiftPM builds using `.build` or a custom scratch path, disables
Keychain access for that process to avoid repeated password prompts. Use the packaged `CodexBar.app` when local
validation needs browser cookies or stored credentials; packaged app bundles keep their normal Keychain behavior
regardless of signing mode.

When the script falls back to ad-hoc signing, it preserves CodexBar-owned keychain state by default.
That means you may still see keychain prompts for existing CodexBar cache entries, but allowing those prompts keeps the
cached browser/OAuth state available across normal rebuilds.
If you want a clean reset of CodexBar-owned keychain state for an ad-hoc build, run
`./Scripts/compile_and_run.sh --clear-adhoc-keychain` before relaunching.
Third-party keychain items still need stable signing if you want macOS to remember **Always Allow** across rebuilds.

### Quick Build (No Tests)

```bash
swift build -c release
./Scripts/package_app.sh
```

### Run Tests Only

```bash
make test
```

### Debug Build

```bash
swift build  # defaults to debug
./Scripts/package_app.sh debug
```

---

## Troubleshooting

### "CodexBar is already running"

The compile_and_run script should kill old instances, but if it doesn't:

```bash
pkill -x CodexBar || pkill -f CodexBar.app || true
```

### "Permission denied" when accessing keychain

Make sure you clicked **"Always Allow"** or set up the development certificate (see above).

### Multiple app bundles keep appearing

This happens when the running app locks the bundle. The compile_and_run script handles this by killing the app first.

If you still see old bundles:

```bash
rm -rf "CodexBar "*.app
```

### App doesn't reflect latest changes

Always rebuild and restart:

```bash
./Scripts/compile_and_run.sh
```

Or manually:

```bash
./Scripts/package_app.sh
pkill -x CodexBar || pkill -f CodexBar.app || true
open -n CodexBar.app
```

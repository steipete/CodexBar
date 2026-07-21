---
summary: "Development setup: stable signing and reducing Keychain prompts."
read_when:
  - Setting up local development
  - Reducing Keychain prompts during rebuilds
  - Configuring dev signing
---

# Development Setup Guide

## Reducing Keychain Permission Prompts

Current CodexBar builds never directly access the Claude Code-owned `Claude Code-credentials` item. Claude Code
replaces that item during credential refreshes, which also replaces its access-control list, so **Always Allow** was
never a durable solution. If a prompt names that exact item and CodexBar is the requesting process, first confirm that
you launched the freshly built bundle rather than an older installed build.

Rebuild signatures can still affect CodexBar-owned entries (`com.steipete.CodexBar` and
`com.steipete.codexbar.cache`) and other Keychain-backed provider features. macOS may treat an ad-hoc-signed rebuild as
a different app, so stable development signing remains useful.

### Quick Fix (Temporary)

For a CodexBar-owned cache prompt, **Always Allow** grants the current signed build access. It is not a recommended fix
for a prompt naming `Claude Code-credentials`; update and relaunch CodexBar instead.

### Permanent Fix (Recommended)

Use a stable development certificate that doesn't change between rebuilds:

#### 1. Create Development Certificate

```bash
./Scripts/setup_dev_signing.sh
```

This creates a self-signed certificate named "CodexBar Development".

#### 2. Trust the Certificate

1. Open **Keychain Access.app**
2. Find **"CodexBar Development"** in the **login** keychain
3. Double-click it
4. Expand the **"Trust"** section
5. Set **"Code Signing"** to **"Always Trust"**
6. Close the window (enter your password when prompted)

#### 3. Configure Your Shell

Add this to your `~/.zshrc` (or `~/.bashrc` if using bash):

```bash
export APP_IDENTITY='CodexBar Development'
```

Then restart your terminal:

```bash
source ~/.zshrc
```

#### 4. Rebuild

```bash
./Scripts/compile_and_run.sh
```

Now your builds will use the stable certificate, reducing prompts for CodexBar-owned Keychain entries.

> Note: `compile_and_run.sh` now auto-detects a valid signing identity (Developer ID or CodexBar Development).
> Set `APP_IDENTITY` to override the auto-detected choice.

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
CodexBar does not use stable signing as permission to read Claude Code's foreign-owned credential item.

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

---
summary: "Development workflow: build/run scripts, logging, and keychain migration notes."
read_when:
  - Starting local development
  - Running build/test scripts
  - Troubleshooting Keychain prompts in dev
---

# CodexBar Development Guide

## Quick Start

### Building and Running

```bash
# Full build, package, and launch (recommended)
./Scripts/compile_and_run.sh

# Also run the sharded test suite before packaging/relaunching
./Scripts/compile_and_run.sh --test

# Just build and package (no tests)
./Scripts/package_app.sh

# Launch existing app (no rebuild)
./Scripts/launch.sh
```

### Development Workflow

1. **Make code changes** in `Sources/CodexBar/`
2. **Run** `./Scripts/compile_and_run.sh --test` to test, rebuild, and launch
3. **Check logs** in Console.app (filter by "codexbar")
4. **Optional file log**: enable Debug → Logging → "Enable file logging" to write
   `~/Library/Logs/CodexBar/CodexBar.log` (verbosity defaults to "Verbose")

## Keychain Prompts (Development)

### First Launch After Fresh Clone
You'll see **one keychain prompt per stored credential** on the first launch. This is a **one-time migration** that converts existing keychain items to use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### Subsequent Rebuilds
The migration flag is stored in UserDefaults, so migrated CodexBar-owned items should not prompt again. Ad-hoc
signing can still prompt for other keychain surfaces; use `./Scripts/compile_and_run.sh --clear-adhoc-keychain`
when you intentionally want to reset ad-hoc keychain state.

### Why This Happens
- Ad-hoc signed development builds change code signature on every rebuild
- macOS keychain normally prompts when signature changes
- We use `ThisDeviceOnly` accessibility to prevent prompts
- Migration runs once to convert any existing items

### Reset Migration (Testing)
```bash
defaults delete com.steipete.codexbar KeychainMigrationV1Completed
```

## Augment Cookie Refresh

### How It Works
CodexBar checks Augment through the provider fetch pipeline. Auto mode tries the Augment CLI first, then the
browser-cookie web path. The web path reuses cached cookies when possible and imports from supported browsers when
the cache is missing or rejected.

### Refresh Frequency
- Fresh-install default: Adaptive, between 2 and 30 minutes (configurable in Preferences → General). Existing installs
  without a stored cadence retain the legacy 5-minute fallback.
- Minimum: 1 minute
- Cookie import happens automatically when cached cookies need refresh

### Supported Browsers
- Safari, Chrome variants, Edge variants, Brave, Arc variants, Dia, and Firefox.

### Manual Cookie Override
If automatic import fails:
1. Open Preferences → Providers → Augment
2. Change "Cookie source" to "Manual"
3. Paste cookie header from browser DevTools

## Project Structure

Key source, test, and packaging paths (not exhaustive):

```
CodexBar/
├── Sources/CodexBar/          # Main app (SwiftUI + AppKit)
│   ├── CodexbarApp.swift      # App entry point
│   ├── StatusItemController*.swift  # Menu bar icon, menu rendering, and actions
│   ├── UsageStore*.swift      # Usage refresh, caching, widgets, and history
│   ├── SettingsStore*.swift   # User preferences and config persistence
│   ├── Providers/             # App-side provider settings/runtime glue
│   └── Resources/             # Assets and localized strings
├── Sources/CodexBarCore/      # Shared business logic used by app, CLI, and widgets
│   ├── Config/                # Config file model, reader, writer, and validation
│   ├── Providers/             # Provider descriptors, fetchers, parsers, and status probes
│   ├── OpenAIWeb/             # OpenAI dashboard integration helpers
│   ├── WebKit/                # Web session helpers
│   └── Vendored/              # Embedded support code
├── Sources/CodexBarCLI/       # Bundled codexbar command-line tool
├── Sources/CodexBarWidget/    # WidgetKit support
├── WidgetExtension/           # Xcode wrapper for the packaged widget extension
├── Tests/CodexBarTests/       # macOS app/core test suite (XCTest + Swift Testing)
├── TestsLinux/                # Linux-specific CLI/core test coverage
└── Scripts/                   # Build and packaging scripts
```

## Common Tasks

### Add a New Provider
See the canonical [provider authoring guide](provider.md#adding-a-new-provider-current-flow) for the complete flow.

1. Add the provider identity to `Sources/CodexBarCore/Providers/Providers.swift`.
2. Add the descriptor and the fetcher, parser, settings-reader, or status-probe pieces the provider needs under
   `Sources/CodexBarCore/Providers/YourProvider/`.
3. Register the descriptor from `Sources/CodexBarCore/Providers/ProviderDescriptor.swift`.
4. Add an app-side `ProviderImplementation` under `Sources/CodexBar/Providers/YourProvider/`; implementations can use
   protocol defaults when no custom UI or macOS integration is needed.
5. Add the provider's exhaustive switch case to
   `Sources/CodexBar/Providers/Shared/ProviderImplementationRegistry.swift`.
6. Add icon assets under `Sources/CodexBar/Resources/`.
7. Add focused tests under `Tests/CodexBarTests/` and, for CLI/core behavior that must run on Linux, `TestsLinux/`.

### Debug Cookie Issues
1. Enable Debug → Logging → "Enable file logging" or raise verbosity in the app settings.
2. Reproduce with `./Scripts/compile_and_run.sh`.
3. Check logs in Console.app:
   - Filter: `subsystem:com.steipete.codexbar category:augment`
   - Importer messages include the `[augment-cookie]` prefix

### Run Tests Only
```bash
make test
```

### Format Code
```bash
swiftformat Sources Tests
swiftlint --strict
```

## Distribution

### Local Development Build
```bash
./Scripts/package_app.sh
# Creates: CodexBar.app with ad-hoc signing by default
```

### Release Build (Notarized)
```bash
./Scripts/sign-and-notarize.sh
# Creates: CodexBar-<version>.zip and CodexBar-<version>.dSYM.zip
```

See `docs/RELEASING.md` for full release process.

## Troubleshooting

### App Won't Launch
```bash
# Check crash logs
ls -lt ~/Library/Logs/DiagnosticReports/CodexBar* | head -5

# Check Console.app for errors
# Filter: process:CodexBar
```

### Keychain Prompts Keep Appearing
```bash
# Verify migration completed
defaults read com.steipete.codexbar KeychainMigrationV1Completed
# Should output: 1

# Check migration logs
log show --predicate 'category == "keychain-migration"' --last 5m
```

### Cookies Not Refreshing
1. Check the browser is supported by the Augment provider metadata
2. Verify you're logged into Augment in that browser
3. Check Preferences → Providers → Augment → Cookie source is "Automatic"
4. Enable debug logging and check Console.app

### Main-Thread Hangs

Debug builds start the hang watchdog automatically. To diagnose a release build,
enable it explicitly and restart CodexBar:

```bash
defaults write com.steipete.codexbar debugMainThreadHangWatchdog -bool true
```

Hangs are written to the app log. Hangs over two seconds also request a process
sample under `~/Library/Logs/CodexBar/`. Disable the release opt-in with:

```bash
defaults delete com.steipete.codexbar debugMainThreadHangWatchdog
```

## Architecture Notes

### Menu Bar App Pattern
- No dock icon (LSUIElement = true)
- Status item only (NSStatusBar)
- SwiftUI for preferences, AppKit for menu
- Hidden 1×1 window keeps SwiftUI lifecycle alive

### Cookie Management
- Automatic browser import via SweetCookieKit
- Keychain cache for some imported browser cookies and OAuth/device-flow credentials
- `~/.codexbar/config.json` for provider settings, manual cookies, and stored API keys
- Manual override for debugging
- Browser-cookie import when cached sessions need refresh

### Usage Polling
- Background timer (configurable frequency)
- Parallel provider fetches
- First failure can be suppressed when prior data exists
- WidgetKit snapshot for macOS widgets

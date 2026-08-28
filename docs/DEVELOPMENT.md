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
CodexBar does not run a prompt-capable startup Keychain migration. Unified config migration reads retired stores and
clears them only after every source was readable and the new config was persisted. If a source is unreadable, cleanup
and migration completion are deferred to a later launch.

### Subsequent Rebuilds
Ad-hoc development builds can still prompt for browser or provider-owned items because their code-signing identity is
not stable. Use a consistently signed packaged bundle for intentional live credential validation. Routine tests must
use the repository's suppression-safe test harness and never query the real Keychain.

### Why This Happens
- Keychain access control checks the executable's code signature and designated requirement.
- Ad-hoc builds and changed identities may no longer match an existing grant.
- Chromium and provider apps can rotate or recreate their foreign-owned items, replacing prior grants.
- `ThisDeviceOnly` accessibility controls item availability and syncing; it does not repair a code-signature ACL
  mismatch or prevent authorization prompts.

See [Keychain prompts](keychain-prompts.md) for the current user-facing boundary and safe troubleshooting.

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
├── TestsLinux/                # Portable and Linux-specific CLI/core tests (target exists on macOS too)
└── Scripts/                   # Build and packaging scripts
```

## Common Tasks

### Add a New Provider
See the canonical [provider authoring guide](provider.md#adding-a-new-provider) for the complete flow.

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

### Codex credential fixtures

Ordinary tests deny Codex credential-file access at the Codex-owned I/O boundaries, before reads,
existence probes, or writes. Detection uses the actual process name/environment, independently of
the credential environment under test. `HOME`, `CODEX_HOME`, `XDG_DATA_HOME`, and
`CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS` do not authorize files. The disabled live-account test remains
disabled; neither `LIVE_TEST` nor Keychain permission alone bypasses this boundary.

Use `CodexCredentialFileAccess.withFixtureScope(.init(files: [...], roots: [...]))` for an explicitly
owned fixture. Synchronous and asynchronous forms restore the previous scope on return or throw.
Roots use path components, reject symlinks within the fixture, and never implicitly authorize all
of `/tmp`. The `CodexCredentialFixtures` test trait creates and cleans up one owned root per test;
credential/account fixtures allocate their homes under `CodexCredentialFixtures.root`. Promotion
and scoped-refresh containers share that helper. The trait also binds the existing dashboard-cache
URL override to its owned root, so cache reads, writes, and clears stay local to the test.
`_loadForUsageForTesting` adds only its explicit
home fixture to the current scope; configured external roots still need explicit authorization.
Pure parsers and `fingerprint(data:)` need no scope. Default managed-account and workspace-cache
stores use fresh temporary paths in tests; explicit file overrides retain their existing behavior.

Task-local scopes inherit through structured tasks, but not detached work. Capture the immutable
`fixtureScope` and explicitly re-enter it in a detached task when fixture access is required; lost
context fails closed. Never authorize a path just because it appears in an environment dictionary.

`Scripts/test.sh` exports `CODEXBAR_TEST_CODEX_FILE_ISOLATION=1` and removes inherited fixture grants.
Direct test commands that launch children should export the same signal. A child needing files must
receive `FixtureScope(files: ..., roots: ...).childEnvironment(base: ...)` naming only that child's
fixtures; this replaces any inherited grants without changing global environment state. The signal,
scope decoding, and denial are compiled in release builds too. `bash Scripts/test_codex_file_isolation_child.sh`
compiles the actual policy and detector with optimization and without `DEBUG`, then checks denied,
scoped-child, and non-test decisions against synthetic temporary files. It does not build or exercise
the complete release CLI, refresh a real account, or establish isolation for other providers.

### CI Aggregate Contract

The `lint-build-test` check in `.github/workflows/ci.yml` keeps its existing name and requires successful lint,
change detection, and the full `build-linux-cli` glibc matrix (x86_64 and ARM64 build, tests, and smoke checks).
Glibc Linux has no path or draft skip: failure, cancellation, skipped, empty, missing, or unknown matrix results
fail verification. macOS tests and the musl build may skip only when their path gates allow it; required macOS
tests deferred for a draft still leave the aggregate incomplete. Whole-workflow cancellation retains the existing
`always() && !cancelled()` condition, so the verifier does not run in that case.

`Scripts/test_ci_path_gate.sh` checks these result combinations and the workflow's Linux dependency and eighth
verifier argument. `CodexBarLinuxTests` includes the portable `AntigravityLocalhostSessionLifetimeTests` suite on
both macOS and Linux. It checks session reuse and concurrent synthetic loopback failures without credentials;
this coverage does not establish or fix the cause of Linux dispatch crashes.

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
Confirm the prompt's requested item and requesting binary, then check for another running or installed CodexBar copy.
Do not validate a fix by querying the real Keychain from routine tests. See [Keychain prompts](keychain-prompts.md).

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

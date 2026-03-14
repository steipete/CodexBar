# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

CodexBar is a macOS 14+ (Sonoma) menu bar app monitoring AI coding tool usage across 18+ providers. Built with Swift 6.2 and strict concurrency, SwiftPM-only (no Xcode project). Fork of [steipete/CodexBar](https://github.com/steipete/CodexBar) — this fork preserves the Augment provider (removed upstream) and adds color-coded icons, time window selection, and weekly projection.

## Build, Test, Lint

```bash
swift build                              # Debug build
swift build -c release                   # Release build
swift test                               # Full XCTest suite
swift test --filter TestClass/testMethod  # Single test

./Scripts/compile_and_run.sh             # Full dev cycle: kill → build → test → package → relaunch → verify
./Scripts/lint.sh lint                   # SwiftFormat --lint + SwiftLint --strict (check only)
./Scripts/lint.sh format                 # SwiftFormat auto-fix
./Scripts/package_app.sh                 # Build release binary → create CodexBar.app bundle
./Scripts/sign-and-notarize.sh           # Code sign + notarize (arm64 zip)
./Scripts/make_appcast.sh <zip> <url>    # Generate Sparkle appcast
```

After code changes, always rebuild and restart via `./Scripts/compile_and_run.sh` before validating behavior.

## Architecture

### Provider System

Each provider lives in `Sources/CodexBarCore/Providers/<Name>/` with two files:
- **`*ProviderDescriptor`** — Metadata (display name, icon, color, supported source modes). Registered via `@ProviderDescriptorRegistration` and `@ProviderDescriptorDefinition` macros into `ProviderDescriptorRegistry`.
- **`*StatusProbe`** — Fetch logic implementing one or more `ProviderFetchStrategy` variants (`.oauth`, `.web`, `.cli`, `.api`, `.localProbe`). Strategies declare availability and execute fetches with automatic fallback chaining.

### Data Flow

```
UsageFetcher (orchestrator)
  → ProviderFetchPlan (strategy selection per provider)
    → *StatusProbe.fetch() (tries strategies in order, falls back on error)
      → UsageSnapshot (primary/secondary/tertiary RateWindow, identity, credits)
        → UsageStore (@Observable, central state)
          → IconRenderer (18×18 pt template images with usage bars)
          → MenuCardView (detailed provider cards in dropdown)
          → StatusItemController (NSStatusItem management)
```

### Key Types

| Type | Location | Role |
|------|----------|------|
| `UsageFetcher` | `Sources/CodexBarCore/UsageFetcher.swift` | Orchestrates all provider fetches |
| `UsageStore` | `Sources/CodexBar/UsageStore.swift` | `@Observable` state container for all snapshots |
| `SettingsStore` | `Sources/CodexBar/SettingsStore.swift` | User preferences (`@Observable`) |
| `IconRenderer` | `Sources/CodexBar/IconRenderer.swift` | Renders menu bar icons with usage bars |
| `MenuCardView` | `Sources/CodexBar/MenuCardView.swift` | SwiftUI provider detail cards |
| `StatusItemController` | `Sources/CodexBar/StatusItemController.swift` | NSStatusItem lifecycle |
| `UsageSnapshot` | `Sources/CodexBarCore/` | Core output: rate windows, identity, cost |
| `RateWindow` | `Sources/CodexBarCore/` | Percentage used, window duration, reset time |
| `ConsecutiveFailureGate` | `Sources/CodexBarCore/` | Debounces flaky errors before displaying |

### Macros (`Sources/CodexBarMacros/`)

- `@ProviderDescriptorRegistration` — Generates registry peer function
- `@ProviderDescriptorDefinition` — Generates `descriptor` computed property
- `@ProviderImplementationRegistration` — Registers provider implementation

Macro support types live in `Sources/CodexBarMacroSupport/`, implementations use SwiftSyntaxMacros.

### Authentication Chain

Providers authenticate via a fallback chain configured in their descriptor's `supportedSourceModes`:
1. **OAuth** — Token from macOS Keychain (Claude, Codex, VertexAI). Claude defaults to `/usr/bin/security` CLI reader (avoids keychain prompts on rebuild); Security.framework available as user override.
2. **Web/Cookies** — Browser cookie extraction via SweetCookieKit (Cursor, Copilot, Gemini). Default to Chrome-only to avoid other browser prompts.
3. **CLI** — Parse stdout from CLI tools via PTY (Claude, Codex, Augment)
4. **API** — Direct API calls with stored token
5. **LocalProbe** — Parse local config/log files

## Code Style (enforced by SwiftFormat + SwiftLint)

- 4-space indent, 120-char max line width, LF line endings
- **Explicit `self` required** — do not remove; required for Swift 6 concurrency safety
- `@testable` imports grouped at bottom
- Type organization: `--organizetypes class,struct,enum,extension` with `MARK: - %t + %p` annotations
- Prefer `@Observable` / `@State` / `@Bindable` over `ObservableObject` / `@ObservedObject` / `@StateObject`
- Favor modern macOS 15+ APIs over deprecated counterparts
- Keep provider data siloed — never display identity/plan fields from a different provider
- Test naming: `FeatureNameTests` class with `test_caseDescription` methods

## Dependencies

| Package | Purpose |
|---------|---------|
| Sparkle | Auto-update framework |
| Commander | CLI argument parsing |
| swift-log | Logging infrastructure |
| swift-syntax | Macro implementation |
| KeyboardShortcuts | Global hotkey support |
| SweetCookieKit | Browser cookie extraction (can override to local path via `SWEETCOOKIEKIT_PATH` env var) |

## Fork Context

- **Upstream:** `steipete/CodexBar` — upstream removed Augment; this fork preserves it
- **Secondary upstream:** `nguyenphutrong/quotio` — monitored for feature ideas
- **Fork-specific features:** Color-coded menu bar icons, time window selection, weekly projection, separator styles
- **Upstream sync scripts:** `Scripts/check_upstreams.sh`, `Scripts/review_upstream.sh`, `Scripts/prepare_upstream_pr.sh`
- **Version:** Tracked in `version.env` (`MARKETING_VERSION` + `BUILD_NUMBER`)

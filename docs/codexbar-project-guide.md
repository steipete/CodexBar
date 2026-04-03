---
summary: "Practical guide to how CodexBar is structured, built, tested, and extended."
read_when:
  - Learning the CodexBar codebase
  - Planning your own macOS menu bar app
  - Experimenting with providers, menus, or local tooling
---

# CodexBar Project Guide

## What CodexBar Is

CodexBar is a macOS 14+ menu bar app that tracks usage, limits, and reset windows across multiple AI products.

It is intentionally:

- menu-bar first
- local-first
- minimal in UI
- provider-extensible
- cautious about privacy and local credential handling

The app has no normal Dock presence and uses a status-item-driven interaction model.

## Mental Model

At a high level, CodexBar is split into three layers:

1. provider/business logic
2. app state and UI wiring
3. packaging, release, and helper tooling

The useful shortcut is:

- `CodexBarCore` knows how to fetch, parse, normalize, and validate provider data
- `CodexBar` knows how to present and coordinate that data in menus, settings, icons, and app workflows

## Main Targets

From `Package.swift`, the important targets are:

- `CodexBarCore`
  shared business logic, provider descriptors, fetchers, token/cookie handling, parsing, logging, and lower-level helpers
- `CodexBar`
  the actual macOS app target
- `CodexBarCLI`
  bundled command-line executable for scripts, CI, and non-GUI use
- `CodexBarWidget`
  widget target
- `CodexBarMacros`
  SwiftSyntax macro target used for provider registration support
- `CodexBarMacroSupport`
  shared macro support layer
- `CodexBarClaudeWatchdog`
  helper process for Claude-related CLI/PTTY stability
- `CodexBarClaudeWebProbe`
  diagnostic helper executable

## Folder Structure

The core folders to understand are:

- `Sources/CodexBar`
  app lifecycle, settings panes, menu rendering, icon rendering, stores, and provider-specific app integration
- `Sources/CodexBarCore`
  provider fetchers, auth/state models, cookie parsing, CLI integrations, status probes, logging, and shared domain logic
- `Sources/CodexBarCLI`
  CLI entry points and output formatting
- `Sources/CodexBarWidget`
  widget support
- `Tests/CodexBarTests`
  macOS-focused test suite
- `TestsLinux`
  Linux/CLI-oriented tests
- `Scripts`
  build, run, packaging, release, and helper scripts
- `docs`
  architecture, provider docs, release notes, workflows, and process notes

## Languages and File Types

If you are new to this kind of project, these are the main file types you will encounter here.

### Swift application code

- `.swift`
  the main application language

This repo is mostly Swift. Swift is used for:

- the macOS app
- shared business logic
- the CLI
- the widget
- tests
- some macro support

### Shell scripts

- `.sh`
  shell scripts used for build, release, lint, launch, and maintenance tasks

These live mostly under `Scripts/`.

### JavaScript module scripts

- `.mjs`
  small Node.js utility scripts

In this repo they are minor helpers, not the main build system.

### Package and config files

- `Package.swift`
  Swift Package Manager manifest
- `Package.resolved`
  locked package resolution data
- `package.json`
  convenience wrapper for script commands like `pnpm check`, `pnpm build`, and `pnpm test`
- `.swiftformat`
  SwiftFormat rules
- `.swiftlint.yml`
  SwiftLint rules

### Test fixtures and content files

- `.json`
  structured test data, provider responses, config-like payloads
- `.md`
  documentation
- `.plist`
  macOS bundle metadata and entitlements
- `.strings`
  localizable resource files

### UI and app resources

- `.svg`
  provider icons and vector assets
- `.icns`
  macOS app icon format
- `.png`
  screenshots and raster assets

### Generated and packaged artifacts

- `.app`
  macOS application bundle
- `.zip`
  packaged release artifact
- `appcast.xml`
  Sparkle update feed artifact

## How the App Is Designed

### UI model

CodexBar uses:

- SwiftUI for preferences and much of the app-facing UI
- AppKit for status-item and menu behavior
- hidden-window / keepalive patterns so the menu bar app lifecycle stays alive without a Dock window

This is a common pattern in polished macOS utilities:

- use AppKit where menu-bar APIs are strongest
- use SwiftUI where form/state UI is simpler

### Data flow

The common loop is:

1. provider source is detected or queried
2. normalized usage/account/status state is produced in core code
3. `UsageStore`, settings state, or a specific coordinator consumes that data
4. menus, icons, widgets, and settings read from those app-layer models

The docs call this out as:

- background refresh → provider probes/fetchers → `UsageStore` → menu/icon/widget

### Provider model

Providers are meant to be siloed.

Important design rule:

- do not show Codex identity using Claude data, or Claude status using Codex state

That sounds obvious, but in multi-provider apps it is easy to accidentally let shared UI models blur provider boundaries.

## Important App-Layer Types

These are the kinds of files worth learning first:

- `Sources/CodexBar/CodexbarApp.swift`
  app entry point
- `Sources/CodexBar/StatusItemController.swift`
  menu bar behavior anchor
- `Sources/CodexBar/UsageStore.swift`
  usage state aggregation and refresh wiring
- `Sources/CodexBar/SettingsStore.swift`
  user settings and feature toggles
- `Sources/CodexBar/PreferencesProvidersPane.swift`
  provider settings composition
- `Sources/CodexBar/MenuDescriptor.swift`
  useful stable seam for menu-model testing

If you are learning how menu bar apps are assembled, start there.

## Important Core-Layer Types

For provider or integration work, the core layer matters more:

- provider descriptors
- fetchers/status probes
- token and cookie readers
- path/environment helpers
- logging and redaction utilities

For Codex-specific work, look at:

- `Sources/CodexBarCore/Providers/Codex/`
- `docs/codex.md`
- `docs/codex-oauth.md`

## Package Dependencies

The main external dependencies in `Package.swift` are:

- `Sparkle`
  app update framework
- `Commander`
  CLI command parsing
- `swift-log`
  structured logging
- `swift-syntax`
  macro support
- `KeyboardShortcuts`
  keyboard shortcut support
- `SweetCookieKit`
  browser cookie/local-storage import helpers

Current pinned package versions in `Package.swift`:

- `Sparkle` from `2.8.1`
- `Commander` from `0.2.1`
- `swift-log` from `1.9.1`
- `swift-syntax` from `600.0.1`
- `KeyboardShortcuts` from `2.4.0`
- `SweetCookieKit` from `0.4.0` unless `CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT=1` points to a local sibling checkout

One practical detail:

- `SweetCookieKit` can be used from a local sibling checkout when `CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT=1` is set

That pattern is useful when you build apps that depend on a library you also maintain.

## Packages, Libraries, and Tools in Plain Language

If you are not used to the names yet, this is what the main pieces are for.

### Swift Package Manager

- `SwiftPM`
  Apple’s package manager and build system for Swift

In this repo, `SwiftPM` is the main package/build tool.

### pnpm

- `pnpm`
  a JavaScript package manager

Here it is only a convenience wrapper around repo scripts. It is not the primary app build system.

### SwiftFormat

- `SwiftFormat`
  automatic code formatter for Swift

It rewrites layout/style issues like spacing, line wrapping, and some structural formatting.

### SwiftLint

- `SwiftLint`
  lint tool for Swift

It reports rule violations such as oversized files, long functions, and style issues.

### Sparkle

- `Sparkle`
  macOS app update framework

This is what powers update feeds and release update behavior.

### Commander

- `Commander`
  Swift CLI argument parsing library

This is mainly relevant for the bundled `codexbar` CLI target.

### swift-log

- `swift-log`
  structured logging package from Apple

Useful for app logs, debug output, and consistent log metadata.

### swift-syntax

- `swift-syntax`
  Swift source parsing/manipulation libraries

This is mainly here to support the repo’s macro targets.

### KeyboardShortcuts

- `KeyboardShortcuts`
  library for macOS keyboard shortcut support

### SweetCookieKit

- `SweetCookieKit`
  helper library for browser cookie and local-storage import workflows

This matters for providers that rely on browser-authenticated sessions.

## Tooling and Package Manager

This repo is primarily a SwiftPM project, but it also ships a small `package.json` as a convenience wrapper.

What that means in practice:

- SwiftPM is the real build system
- `pnpm` is a convenience shell around repo scripts, not the primary runtime/build tool
- there is no JavaScript frontend pipeline here

Useful `package.json` scripts:

- `pnpm start`
  runs `./Scripts/compile_and_run.sh`
- `pnpm lint`
  runs `./Scripts/lint.sh lint`
- `pnpm format`
  runs `./Scripts/lint.sh format`
- `pnpm check`
  currently aliases the lint check
- `pnpm build`
  runs `swift build`
- `pnpm test`
  runs `swift test`

So if you are learning from this repo:

- think of `pnpm` as an ergonomic shortcut layer
- think of SwiftPM plus shell scripts as the actual build/release system

## Pinned Lint and Formatting Tools

CodexBar pins its lint tools in `Scripts/install_lint_tools.sh`.

Current pinned versions:

- `SwiftFormat 0.59.1`
- `SwiftLint 0.63.2`

Important detail:

- macOS downloads are SHA-256 pinned in the installer script
- the lint script always delegates to the installer so the expected versions are enforced

That is a good pattern for your own projects when you want stable formatting across machines and CI.

## Development Workflow

The repo strongly prefers script-driven development.

Most useful commands:

- `./Scripts/compile_and_run.sh`
  full dev loop; builds, tests, packages, relaunches
- `./Scripts/package_app.sh`
  package the app bundle
- `./Scripts/launch.sh`
  launch existing app bundle
- `./Scripts/lint.sh lint`
  formatting/lint guardrail

For quick local understanding:

1. read `README.md`
2. read `docs/DEVELOPMENT.md`
3. read `docs/architecture.md`
4. then inspect `Sources/CodexBar` and `Sources/CodexBarCore`

## Build and Test Toolchain

The repo is currently configured for:

- Swift tools version `6.2`
- macOS deployment target `14`
- Swift strict concurrency migration features enabled across targets
- experimental Swift Testing support enabled in test targets

In practical terms:

- you should expect Swift 6 concurrency diagnostics to matter
- some test failures may be caused by Swift Testing/toolchain evolution rather than your feature
- build/test behavior can differ when stale module caches are reused between different checkout locations

If you hit odd build cache issues in a second checkout, a fresh scratch build path can help:

```bash
swift build --scratch-path /tmp/codexbar-clean-build
```

## Testing Strategy

The project uses Swift Testing/XCTest-style coverage across a large suite.

The most useful rule from the repo guidelines is:

- prefer stable state/model seams over brittle live-AppKit tests

That means:

- test menu composition through model builders like `MenuDescriptor`
- test settings sections through state builders and section state
- use direct AppKit tests only when the AppKit wiring itself is the feature

Important test reality in this repo:

- the suite is large
- some repo-wide baseline issues can exist outside your feature
- it is often useful to run both:
  - a full `swift test`
  - a focused filtered test for the feature area you touched

Examples:

- `swift test --filter CodexAccountsSettingsSectionTests`
- `swift test --filter StatusMenuCodexLocalProfilesTests`
- `swift test --filter CodexLocalProfileManagerTests`

This is a good rule for your own apps too because menu/UI integration tests can become noisy and expensive quickly.

## Design Philosophy

CodexBar is not trying to be a dashboard-heavy app.

The design tendencies are:

- minimal surface area
- small, dense menus
- stock-macOS-feeling controls
- conservative changes to established UI sections
- additive features rather than major redesigns

A useful lesson from this project:

- when adding a feature, try to isolate it in a new, well-scoped UI surface rather than reshaping existing surfaces unless you really need to

## Restrictions and Constraints

These constraints matter when modifying or copying ideas from CodexBar:

### Platform

- targets macOS 14+
- Swift 6 strict concurrency is enabled

That means your changes should respect:

- `Sendable` safety
- actor boundaries
- explicit main-thread hops for UI work

### Privacy and security

CodexBar is local-first and intentionally narrow in what it reads.

It may read:

- known browser cookie/local storage locations
- known local CLI or auth files
- provider-specific config/log paths

It should not become a broad filesystem crawler.

### Permissions

macOS prompts may be involved for:

- Keychain access
- browser cookie decryption
- Safari/Full Disk Access cases
- CLI access to protected folders

If you build your own app, expect macOS integrations to drive permission complexity more than your own code does.

### UI discipline

The repo favors:

- minimal menu clutter
- no unnecessary extra chrome
- staying close to existing patterns

So “can we add this?” is often the wrong question.
The better question is:

- can this be added without making the current menu/settings experience feel heavier?

### File and complexity guardrails

There is no hard “one file must never exceed X lines” rule in the repo, but there are practical limits enforced by linting.

Current notable SwiftLint thresholds:

- file length:
  - warning at `1500`
  - error at `2500`
- function body length:
  - warning at `150`
  - error at `300`
- type body length:
  - warning at `800`
  - error at `1200`
- line length:
  - warning at `120`
  - error at `250`
- cyclomatic complexity:
  - warning at `20`
  - error at `120`

So the repo does not impose a tiny-file style, but it does push against giant files and very large functions.

### Formatting constraints

Current formatting expectations include:

- 4-space indentation
- 120-character preferred width
- explicit `self`
- organized type and extension `MARK` sections
- Swift 6.2 formatting assumptions

Those are enforced through `.swiftformat` and `.swiftlint.yml`.

## How to Add Features Safely

When experimenting with your own apps, CodexBar is a good model for this workflow:

1. identify the stable boundary
2. keep business logic out of the view
3. add a small coordinator if the feature crosses UI and process/filesystem boundaries
4. add focused tests at stable seams
5. verify with scripts, not only ad hoc clicking
6. keep the published diff clean and reviewable

The local-profile feature followed exactly that pattern.

## How to Add a Provider

The repo already documents provider authoring, but the practical pattern is:

1. define or extend the provider descriptor and settings reader in core
2. implement fetch/status/auth logic in core
3. add app-facing provider integration in `Sources/CodexBar/Providers/...`
4. register the provider
5. add icons/resources if needed
6. add focused tests for parsing, auth routing, and presentation

For details, read:

- `docs/provider.md`
- provider-specific docs under `docs/`

## Good Files To Study If You Want To Learn

If you are experimenting with your own apps, these are strong examples:

### For app structure

- `Sources/CodexBar/CodexbarApp.swift`
- `Sources/CodexBar/StatusItemController.swift`
- `Sources/CodexBar/PreferencesProvidersPane.swift`
- `Sources/CodexBar/UsageStore.swift`

### For menu/state testing

- `Sources/CodexBar/MenuDescriptor.swift`
- `Tests/CodexBarTests/StatusMenuTests.swift`
- `Tests/CodexBarTests/CodexAccountsSettingsSectionTests.swift`

### For provider-style business logic

- `Sources/CodexBarCore/Providers/Codex/`
- `Sources/CodexBarCore/Providers/Claude/`
- `Sources/CodexBarCore/OpenAIWeb/`

### For build/release process

- `Scripts/compile_and_run.sh`
- `Scripts/package_app.sh`
- `Scripts/sign-and-notarize.sh`
- `docs/RELEASING.md`

## Practical Lessons You Can Reuse In Your Own Apps

CodexBar is a good reference for:

- local-first app design
- mixing SwiftUI and AppKit pragmatically
- small-tool UX rather than full-window dashboard UX
- keeping auth/cookie handling explicit and scoped
- building stable test seams around otherwise hard-to-test menu bar behavior
- resisting unnecessary architecture layers

## Things That Are Easy To Miss

These details are helpful when experimenting in your own apps:

- this repo uses shell scripts as the main developer workflow surface, not Xcode schemes alone
- `pnpm` is present, but it is not the app’s core build system
- provider integrations are numerous, so cross-provider leakage is a real architectural risk
- menu bar apps need different testing and lifecycle strategies than standard document/window apps
- local auth and cookie handling tends to dominate security complexity
- fresh builds in a new checkout can fail because of stale module caches, not because your code is wrong

## Related Docs

Use this guide as the broad orientation layer, then read:

- `README.md`
- `docs/DEVELOPMENT.md`
- `docs/architecture.md`
- `docs/provider.md`
- `docs/refresh-loop.md`
- `docs/ui.md`
- `docs/codex.md`
- `docs/runbook-codex-local-profiles.md`

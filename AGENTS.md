# Repository Guidelines

## Project Structure & Modules
- `Sources/CodexBar`: Swift 6 menu bar app (usage/credits probes, icon renderer, settings). Keep changes small and reuse existing helpers.
- `Sources/CodexBarCore`: Shared core library used by app, CLI, and tests.
- `Sources/CodexBarCLI`: CLI tool (`codexbar` command).
- `Sources/CodexBarWidget`: WidgetKit widget extension.
- `Tests/CodexBarTests`: XCTest coverage for usage parsing, status probes, icon patterns; mirror new logic with focused tests.
- `Tests/CodexBarLinuxTests`: Linux-compatible tests (Swift Testing framework).
- `Scripts`: build/package helpers (`package_app.sh`, `sign-and-notarize.sh`, `make_appcast.sh`, `build_icon.sh`, `compile_and_run.sh`).

## Build, Test, Run
- Dev loop: `./Scripts/compile_and_run.sh` kills old instances, runs `swift build` + `swift test`, packages, relaunches `CodexBar.app`, and confirms it stays running.
- Quick build: `swift build` (debug) or `swift build -c release`.
- Run all tests: `swift test`.
- Run single test: `swift test --filter CodexBarTests.ClaudeUsageTests/parsesUsageJSONWithSonnetLimit`.
- Run single test suite: `swift test --filter CodexBarTests.ClaudeUsageTests`.
- Package locally: `./Scripts/package_app.sh` to refresh `CodexBar.app`, then restart with `pkill -x CodexBar || pkill -f CodexBar.app || true; open -n CodexBar.app`.
- Release flow: `./Scripts/sign-and-notarize.sh` (arm64 notarized zip) and `./Scripts/make_appcast.sh <zip> <feed-url>`.

## Code Style & Conventions

### Formatting & Linting
- Enforce SwiftFormat/SwiftLint: run `swiftformat Sources Tests` and `swiftlint --strict`.
- 4-space indentation, 120-char line limit.
- Explicit `self` is intentional—do not remove.

### Swift Language & Patterns
- Swift 6 with strict concurrency enabled: `.enableUpcomingFeature("StrictConcurrency")`.
- Prefer modern SwiftUI/Observation macros: use `@Observable` models with `@State` ownership and `@Bindable` in views; avoid `ObservableObject`, `@ObservedObject`, and `@StateObject`.
- Favor modern macOS 15+ APIs over legacy/deprecated counterparts (Observation, new display link APIs, updated menu item styling).
- Use `async/await` for asynchronous operations; Swift Concurrency throughout.
- Mark types as `Sendable` when thread-safe.
- Use `@MainActor` for UI-related classes and view controllers.
- Prefer small, typed structs/enums; maintain existing `MARK` organization.
- Use descriptive symbols; match current commit tone.

### Import Organization
- Group imports alphabetically within each section: Foundation, AppKit/SwiftUI, then third-party.
- Use `@testable import CodexBar` or `@testable import CodexBarCore` in tests when needed.
- Prefer explicit imports over umbrella imports where possible.

### Naming Conventions
- Types: PascalCase (`UsageSnapshot`, `RateWindow`).
- Functions/variables: camelCase (`loadLatestUsage`, `accountEmail`).
- Constants: camelCase (`menuObservationToken`).
- Test methods: `test_caseDescription` (Swift Testing uses `@Test`).
- Private helpers: private functions/classes; prefix with underscore for internal testing APIs (`_setSnapshotForTesting`).

### Error Handling
- Define custom error types conforming to `LocalizedError` and `Sendable`.
- Provide descriptive `errorDescription` in cases.
- Use `Result` types for operations that can fail without throwing.
- Graceful degradation: fallback mechanisms (e.g., RPC → TTY for Codex).
- Consecutive failure gating: don't surface single flakes when prior data exists.

### Testing Guidelines
- Add/extend XCTest cases under `Tests/CodexBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Use Swift Testing framework (`@Suite`, `@Test`, `#expect`) where available.
- Always run `swift test` (or `./Scripts/compile_and_run.sh`) before handoff.
- Add fixtures for new parsing/formatting scenarios.
- Use environment variables (`LIVE_CLAUDE_FETCH`, `LIVE_CLAUDE_WEB_FETCH`) for live integration tests.

### Observability & Logging
- Use `CodexBarLog.logger("category")` for structured logging.
- Include debug helper methods marked with `#if DEBUG`.
- Probe logs captured in `UsageStore.probeLogs` for diagnostics.

## Agent Notes
- Use the provided scripts and package manager (SwiftPM); avoid adding dependencies or tooling without confirmation.
- Validate behavior against the freshly built bundle; restart via the pkill+open command above to avoid running stale binaries.
- After any code change that affects the app, always rebuild with `Scripts/package_app.sh` and restart the app using the command above before validating behavior.
- If you edited code, run `./Scripts/compile_and_run.sh` before handoff; it kills old instances, builds, tests, packages, relaunches, and verifies the app stays running.
- Per user request: after every edit (code or docs), rebuild and restart using `./Scripts/compile_and_run.sh` so the running app reflects the latest changes.
- Release script: keep it in the foreground; do not background it—wait until it finishes.
- Keep provider data siloed: when rendering usage or account info for a provider (Claude vs Codex), never display identity/plan fields sourced from a different provider.
- Claude CLI status line is custom + user-configurable; never rely on it for usage parsing.

## Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., "Improve usage probe", "Fix icon dimming"); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

# Repository Guidelines

## Project Structure & Modules
- `Sources/CodexBar`: Swift 6 menu bar app (usage/credits probes, icon renderer, settings). Keep changes small and reuse existing helpers.
- `Tests/CodexBarTests`: XCTest coverage for usage parsing, status probes, icon patterns; mirror new logic with focused tests.
- `Scripts`: build/package helpers (`package_app.sh`, `sign-and-notarize.sh`, `make_appcast.sh`, `build_icon.sh`, `compile_and_run.sh`).
- `docs`: release notes and process (`docs/RELEASING.md`, screenshots). Root-level zips/appcast are generated artifacts—avoid editing except during releases.

## Build, Test, Run
- Dev loop: `./Scripts/compile_and_run.sh` kills old instances, runs `swift build` + `swift test`, packages, relaunches `CodexBar.app`, and confirms it stays running.
- Quick build/test: `swift build` (debug) or `swift build -c release`; `swift test` for the full XCTest suite.
- Package locally: `./Scripts/package_app.sh` to refresh `CodexBar.app`, then restart with `pkill -x CodexBar || pkill -f CodexBar.app || true; cd /Users/steipete/Projects/codexbar && open -n /Users/steipete/Projects/codexbar/CodexBar.app`.
- Release flow: `./Scripts/sign-and-notarize.sh` (arm64 notarized zip) and `./Scripts/make_appcast.sh <zip> <feed-url>`; follow validation steps in `docs/RELEASING.md`.

## Coding Style & Naming
- Enforce SwiftFormat/SwiftLint: run `swiftformat Sources Tests` and `swiftlint --strict`. 4-space indent, 120-char lines, explicit `self` is intentional—do not remove.
- Favor small, typed structs/enums; maintain existing `MARK` organization. Use descriptive symbols; match current commit tone.

## Testing Guidelines
- Add/extend XCTest cases under `Tests/CodexBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Always run `swift test` before handoff; add focused filters for parser/provider fixes when possible.
- After any code change, run `make check` and fix all reported format/lint issues before handoff.
- Prefer CLI/focused tests over app-bundle live tests when behavior can be verified without relaunching CodexBar.
- macOS CI is brittle around headless AppKit status/menu tests. Prefer covering menu behavior through stable state/model seams (`MenuDescriptor`, `ProvidersPane`, `CodexAccountsSectionState`, etc.) instead of constructing live `NSStatusBar`/`NSMenu` flows unless the AppKit wiring itself is the thing under test.

## Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., “Improve usage probe”, “Fix icon dimming”); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

## Agent Notes
- Use the provided scripts and package manager (SwiftPM); avoid adding dependencies or tooling without confirmation.
- Validate UI/runtime behavior against the freshly built bundle; restart via the pkill+open command above to avoid running stale binaries.
- To guarantee the right bundle is running after a rebuild, use: `pkill -x CodexBar || pkill -f CodexBar.app || true; cd /Users/steipete/Projects/codexbar && open -n /Users/steipete/Projects/codexbar/CodexBar.app`.
- For CLI-testable provider/parser/settings behavior, use CLI/focused tests instead of `Scripts/package_app.sh` or `./Scripts/compile_and_run.sh`.
- Run `./Scripts/compile_and_run.sh` only when UI/runtime behavior needs bundle-level validation; it builds, tests, packages, relaunches, and verifies the app stays running.
- Release script: keep it in the foreground; do not background it—wait until it finishes.
- Release keys: find in `~/.profile` if missing (Sparkle + App Store Connect).
- Swift concurrency: treat sibling `async let` tasks as a review red flag when one child is required and another is optional/best-effort. Prefer sequential awaits or a drained `withThrowingTaskGroup` that surfaces required failures and explicitly contains optional failures; crash stacks mentioning `swift_task_dealloc` or `asyncLet_finish_after_task_completion` should trigger an audit of nearby `async let` usage.
- Prefer modern SwiftUI/Observation macros: use `@Observable` models with `@State` ownership and `@Bindable` in views; avoid `ObservableObject`, `@ObservedObject`, and `@StateObject`.
- Favor modern macOS 15+ APIs over legacy/deprecated counterparts when refactoring (Observation, new display link APIs, updated menu item styling, etc.).
- Keep provider data siloed: when rendering usage or account info for a provider (Claude vs Codex), never display identity/plan fields sourced from a different provider.***
- Claude CLI status line is custom + user-configurable; never rely on it for usage parsing.
- Cookie imports: default Chrome-only when possible to avoid other browser prompts; override via browser list when needed.

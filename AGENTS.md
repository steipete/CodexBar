# Repository Guidelines

## Personal maintenance
- Consult `docs/adr/` when changing provider scope or quota data sources.
- For feature discussions, behavior changes, bug fixes, and upstream evaluations, read `.agents/skills/personal-requirements/SKILL.md`.
- For compilation, tests, checks, packaging, or artifact retrieval, read `.agents/skills/cloud-build/SKILL.md`; prefer GitHub execution to avoid occupying the local device. Finishing development does not authorize installation or app restart.
- Local Swift builds use `--jobs 2` by default; run build/test/package operations sequentially on this device.
- Public release scripts and `release-codexbar` apply only to an explicit public release request; personal builds use ad-hoc signing.

## Project Structure & Modules
- `Sources/CodexBar`: Swift 6 menu bar app (usage/credits probes, icon renderer, settings). Keep changes small and reuse existing helpers.
- `Tests/CodexBarTests`: XCTest coverage for usage parsing, status probes, icon patterns; mirror new logic with focused tests.
- `Scripts`: build/package helpers (`package_app.sh`, `sign-and-notarize.sh`, `make_appcast.sh`, `build_icon.sh`, `compile_and_run.sh`). Release wrappers call `Scripts/mac-release`, which resolves `MAC_RELEASE_TOOL` or the shared `agent-scripts` checkout.
- `docs`: release notes and process (`docs/RELEASING.md`, screenshots). Root-level zips/appcast are generated artifacts—avoid editing except during releases.

## Build, Test, Run
- Explicit runtime validation: `./Scripts/compile_and_run.sh` kills old instances, builds, packages, and relaunches the checkout bundle. Use only when restarting the app is part of the requested task; add `--test` for the sharded full suite.
- Build, test, check, and package through the workflow documented in `.agents/skills/cloud-build/SKILL.md`. Keep command parameters in the workflow and scripts.
- Release flow: `./Scripts/release.sh`; app metadata lives in `.mac-release.env`, repo build/signing stays in `Scripts/sign-and-notarize.sh`, and validation steps live in `docs/RELEASING.md`.

## Coding Style & Naming
- Enforce SwiftFormat/SwiftLint through the cloud check job; use `swiftformat` when formatting edits are needed. 4-space indent, 120-char lines, explicit `self` is intentional—do not remove.
- Favor small, typed structs/enums; maintain existing `MARK` organization. Use descriptive symbols; match current commit tone.

## Testing Guidelines
- Add/extend XCTest cases under `Tests/CodexBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Swift Testing: prefer backticked sentence names; no camelCase.
- Model names in tests/code: released models or clearly fictitious names only; never expose unreleased names.
- Cover changed behavior with focused tests; complete cloud tests and checks during PR work. When the user explicitly requests an update based on a PR, reuse its completed validation and follow the build-only path in `.agents/skills/cloud-build/SKILL.md`. Record the source SHA and remote results before installation. Documentation/workflow preparation needs static validation only.
- After code changes, require successful remote checks before installation; PR validation reuse follows the rule above. Fix issues in changed code; report unrelated baseline failures.
- When local iteration is needed, use focused runs (`make test-fast FILTER='SuiteName'` or `swift test --filter ...`). For a local full run use `./Scripts/test.sh --direct-workers 8` instead of serial `make test`. The full suite is not a foreground handoff gate: prefer PR CI or cloud checks; never block on it in the foreground.
- While iterating locally, format/lint only touched files; run `make check` once before commit/handoff and fix reported issues.
- Prefer CLI/focused tests over app-bundle live tests when behavior can be verified without relaunching CodexBar.
- Never run tests/checks or ad-hoc validation that can display macOS Keychain prompts. Live provider probes, browser-cookie imports, `codexbar usage` against real accounts, and real SecItem reads must be explicitly requested; otherwise use parser tests, stubs, test stores, or `KeychainNoUIQuery`.
- App-group migration tests must inject dictionary-backed defaults, both snapshot URLs, a synthetic home, and a contained recording FileManager. UUID defaults suites and Keychain isolation flags do not isolate defaults search domains or filesystem access. Ordinary SettingsStore tests must not discover shared defaults or run app-group migration.
- macOS CI is brittle around headless AppKit status/menu tests. Prefer covering menu behavior through stable state/model seams (`MenuDescriptor`, `ProvidersPane`, `CodexAccountsSectionState`, etc.) instead of constructing live `NSStatusBar`/`NSMenu` flows unless the AppKit wiring itself is the thing under test.

## CI Efficiency
- Follow `.agents/skills/cloud-build/SKILL.md` and upstream CI contracts when changing CI or test execution; preserve full test inventory, deadlines, failure handling, cache verification, and clean fallback.
- Reuse incremental builds during iteration; never copy compiled products between worktrees. Clean `.build` for diagnosed contamination, a cold-build comparison, or maintainer-requested cleanup.
- Run focused tests during development; the final code needs focused tests plus `make check`, with the full suite from PR CI or a background run. Repeat successful full checks when relevant inputs or the environment change, a failure or unresolved concern requires it, or a maintainer requests it; do not repeat them solely to prepare a report.

## Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., “Improve usage probe”, “Fix icon dimming”); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

## Agent Notes
- Use the provided scripts and package manager (SwiftPM); avoid adding dependencies or tooling without confirmation.
- Menu bar automation: capture the target screen first and verify the CodexBar icon is visibly onscreen. Reject `click-extra` success when coordinates fall outside display bounds; hidden menu extras are not click proof.
- Validate requested UI/runtime behavior against the freshly built bundle. For installed-version verification, launch `/Applications/CodexBar.app` and verify the running executable path, version, and source SHA against the selected artifact.
- For CLI-testable provider/parser/settings behavior, use CLI/focused tests instead of `Scripts/package_app.sh` or `./Scripts/compile_and_run.sh`.
- Run `./Scripts/compile_and_run.sh` only when UI/runtime behavior needs bundle-level validation; it builds, packages, relaunches, and verifies the app stays running; tests require `--test`.
- Widget/Tahoe UI issues: use an available Parallels macOS VM for version-specific verification; otherwise report the missing runtime coverage and use stable model tests.
- Release script: keep it in the foreground; do not background it—wait until it finishes.
- Sparkle release key: use `.mac-release.env` `MAC_RELEASE_SIGNING_KEY_FILE`, the legacy `AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=` key. Do not use `sparkle-private-key-KEEP-SECURE.txt`; that is VibeTunnel's mismatched key.
- Swift concurrency: treat sibling `async let` tasks as a review red flag when one child is required and another is optional/best-effort. Prefer sequential awaits or a drained `withThrowingTaskGroup` that surfaces required failures and explicitly contains optional failures; crash stacks mentioning `swift_task_dealloc` or `asyncLet_finish_after_task_completion` should trigger an audit of nearby `async let` usage.
- Prefer modern SwiftUI/Observation macros: use `@Observable` models with `@State` ownership and `@Bindable` in views; avoid `ObservableObject`, `@ObservedObject`, and `@StateObject`.
- Favor modern macOS 15+ APIs over legacy/deprecated counterparts when refactoring (Observation, new display link APIs, updated menu item styling, etc.).
- Keep provider data siloed: when rendering usage or account info for a provider (Claude vs Codex), never display identity/plan fields sourced from a different provider.
- Claude CLI status line is custom + user-configurable; never rely on it for usage parsing by default. A user-enabled, opt-in statusLine JSON feed is permitted as an explicit data source (owner ruling, #2733): it must be off by default, clearly labeled as sourced from the user's own statusLine config, and fail soft when the format drifts.
- Cookie imports: use the shared default browser order; `BrowserCookieAccessGate` ensures no background/settings prompts, host-matching cookie rows before Safe Storage access, at most one interactive Keychain read per manual action, denial cooldowns even on manual retries (only `codexbar cookie refresh --allow-keychain-prompt` overrides), and traversal stopping at the first validated session. Restrict a provider to a browser subset only with a documented technical reason next to the code.

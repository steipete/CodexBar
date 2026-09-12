---
summary: "Architecture overview: modules, entry points, and data flow."
read_when:
  - Reviewing architecture before feature work
  - Refactoring app structure, app lifecycle, or module boundaries
---

# Architecture overview

## Modules
- `Sources/CodexBarCore`: fetch + parse (Codex RPC, PTY runner, Claude probes, OpenAI web scraping, status polling).
- `Sources/CodexBar`: state + UI (UsageStore, SettingsStore, StatusItemController, menus, icon rendering).
- `Sources/CodexBarWidget`: WidgetKit extension wired to the shared snapshot.
- `Sources/CodexBarCLI`: bundled CLI for `codexbar` usage/status output.
- `Sources/CodexBarClaudeWatchdog`: helper process for stable Claude CLI PTY sessions.
- `Sources/CodexBarClaudeWebProbe`: CLI helper to diagnose Claude web fetches.

## Entry points
- `CodexBarApp`: SwiftUI keepalive + Settings scene.
- `AppDelegate`: wires status controller, Sparkle updater, notifications.

## Data flow
- Background refresh → `UsageFetcher`/provider probes → `UsageStore` → menu/icon/widgets.
- Settings toggles feed `SettingsStore` → `UsageStore` refresh cadence + feature flags.
- Runtime-only provider settings flow through typed, descriptor-registered sections in `ProviderSettingsSnapshot`.

## CLI login lifecycle
- `CodexLoginRunner` and `KiroLoginRunner` resolve their own executable and environment, including Codex home scoping.
- `CLILoginRunner` owns browser-waiting login processes, bounded output capture, timeout/cancellation, and optional
  device-flow progress. It returns one shared result type; provider presentations retain their own recovery messages.
- The login runner and `SubprocessRunner` share `ProcessTermination` and process-tree termination. Cancelling a login
  stops its child process, joins its progress callback task, and produces no failure alert. Timeouts retain captured
  diagnostic output, and inherited pipes cannot keep the caller waiting indefinitely.

## Concurrency & platform
- Swift 6 strict concurrency enabled; prefer Sendable state and explicit MainActor hops.
- macOS 14+ targeting; avoid deprecated APIs when refactoring.

See also: `docs/providers.md`, `docs/refresh-loop.md`, `docs/ui.md`.

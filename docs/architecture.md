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
- `Sources/CodexBarLinuxTray` (Linux only): native tray host loop built on `CodexBarCore`, writing `WidgetSnapshotStore`.
- `Sources/CodexBarMacros`: SwiftSyntax macros for provider registration.
- `Sources/CodexBarMacroSupport`: shared macro support used by app/core/CLI targets.
- `Sources/CodexBarClaudeWatchdog`: helper process for stable Claude CLI PTY sessions.
- `Sources/CodexBarClaudeWebProbe`: CLI helper to diagnose Claude web fetches.

## Entry points
- `CodexBarApp`: SwiftUI keepalive + Settings scene.
- `AppDelegate`: wires status controller, Sparkle updater, notifications.
- `CodexBarLinuxTray`: Linux tray process that refreshes provider usage and updates the tray indicator.

## Data flow
- Background refresh → `UsageFetcher`/provider probes → `UsageStore` → menu/icon/widgets.
- Settings toggles feed `SettingsStore` → `UsageStore` refresh cadence + feature flags.

## Concurrency & platform
- Swift 6 strict concurrency enabled; prefer Sendable state and explicit MainActor hops.
- macOS 14+ targeting; avoid deprecated APIs when refactoring.
- Linux tray runtime follows the same provider registry/fetch pipeline and stores snapshot output through
  `WidgetSnapshotStore`.

## Platform boundaries
- macOS host layer: `Sources/CodexBar/StatusItemController*.swift`, `Sources/CodexBar/CodexbarApp.swift`.
- Shared cross-platform logic: `Sources/CodexBarCore` provider descriptors, fetch strategies, formatting,
  config store, and widget snapshot models.
- Linux host layer: `Sources/CodexBarLinuxTray` for tray lifecycle, refresh scheduling, and Linux-specific
  runtime config.

See also: `docs/providers.md`, `docs/refresh-loop.md`, `docs/ui.md`.

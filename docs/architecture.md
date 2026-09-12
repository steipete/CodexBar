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

## Shared policy ownership
- App credential properties read directly from the config snapshot and delegate common string writes to the typed
  `SettingsStore` config accessor, which owns normalization, persistence, and secret-update logging. Field activation
  does not trigger credential loading. Legacy provider toggles are read only by the config migrator.
- The native status-item controller owns menu composition. Persistent refresh-row metrics are independent of menu
  rendering, and screenshot fixtures exercise the active card views. Legacy menu-layout resolution retains its
  rendering mode and projected layout without copying unused settings into a second state object.
- Core owns status feed fetching, decoding, and status models through `ProviderStatusFetcher`; the app supplies
  localized labels and component UI, and the CLI supplies its existing status payload and English labels.
- `KeychainStringStore` owns generic-password operations for legacy credential migration. Provider adapters retain
  their existing item names, prompt kinds, cookie validation, and cache lifetimes. Structured OAuth/cache stores
  retain their separate persistence and authorization contracts.
- Simple API-token providers use `ProviderFetchPlan.apiToken`; provider loaders retain endpoint-specific behavior
  and optional-data rules. Strategies with credential provenance, region selection, or fallback policies stay explicit.
- `ProviderCostSnapshot.spendLimitWindow` owns spend-budget quota projection. Antigravity's shared family classifier
  owns ID-before-title precedence; visibility and compact widget selection retain their distinct unknown-family rules.
- `TestProcessSafety` owns test-runner recognition; callers retain explicit headless and fixture-path policies.
- `CheckedSum` owns integer overflow handling. Callers still decide whether absent or empty counts mean zero,
  unavailable, or incomplete; persistent accumulators retain their own overflow state.
- `BrowserCookieProfiles` merges browser stores within each profile using the existing expiry and store-priority
  rules. Providers still validate their own sessions. `ExpiringValueCache` supplies their short-lived import caches,
  with a separate cache instance per provider. `CookiePropertyJSON` preserves the legacy Date/URL marker encoding;
  session stores retain their own file envelopes, expiration policies, and secure writes.
- `OpenCodeWebParsing` owns workspace discovery and quota-candidate traversal for OpenCode and OpenCode Go. Each
  supplies its own numeric/window decoder and required-lane policy. Alibaba Token Plan and Qwen Cloud share
  `OneConsoleTokenPlanSnapshot` projection while retaining distinct public snapshot types and provider identities.
- `StreamScanBuffer` supplies bounded overlap for Codex and Claude terminal-marker matching; command handling and
  session lifecycle remain provider-specific.
- Raw Chromium local-storage consumers share `ChromiumLocalStorageDiscovery`, retaining their own browser lists and
  origin decoders. Both plugin engines use the manifest's management-auth eligibility policy after adapting their
  engine-specific option values.
- Codex RPC and OAuth spend limits use `CodexSpendControlNumber` while keeping their wire-field aliases separate.
  Reset values retain truncation toward zero, with unrepresentable values omitted instead of trapping.
- Claude's persistent CLI operations and serialized browser fetches each own an `AsyncOperationGate`; the shared
  implementation retains FIFO ownership and the CLI cleanup path's explicit cancellation exception. CLI usage and
  cards validate account/provider selection through `TokenAccountCLISelection` before resolving credentials.

See also: `docs/providers.md`, `docs/refresh-loop.md`, `docs/ui.md`.

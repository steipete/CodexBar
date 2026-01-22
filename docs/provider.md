---
summary: "Provider authoring guide: shared host APIs, provider boundaries, and how to add a new provider."
read_when:
  - Adding a new provider (usage + status + identity)
  - Refactoring provider architecture or shared host APIs
  - Reviewing provider boundaries (no identity leakage)
---

# Provider authoring guide

Goal: adding a provider should feel like:
- add one folder
- define one descriptor + strategies
- add one implementation (UI hooks only)
- done (tests + docs)

This doc describes the **current provider architecture** (post-macro registry) and the exact steps to add a new provider.

## Terms
- **Provider**: a source of usage/quota/status data (Codex, Claude, Gemini, Antigravity, Cursor, …).
- **Descriptor**: the single source of truth for labels, URLs, defaults, and fetch strategies.
- **Fetch strategy**: one concrete way to obtain usage (CLI, web cookies, OAuth API, local probe, etc.).
- **Host APIs**: shared capabilities we provide to providers (Keychain, browser cookies, PTY, HTTP, WebView scrape, token-cost).
- **Identity fields**: email/org/plan/loginMethod. Must stay **siloed per provider**.

## Architecture overview (now)
- `Sources/CodexBarCore`: provider descriptors + fetch strategies + probes + parsing + shared utilities.
- `Sources/CodexBar`: UI/state + provider implementations (settings/login/menu hooks only).
- Provider IDs are compile-time: `UsageProvider` enum (used for persistence + widgets).
- Provider wiring is descriptor-driven:
  - `ProviderDescriptor` owns labels, URLs, default enablement, and fetch pipeline.
  - `ProviderFetchStrategy` objects implement concrete fetch paths.
  - CLI + app both call the same descriptor/fetch pipeline.

Common building blocks already exist:
- PTY: `TTYCommandRunner`
- subprocess: `SubprocessRunner`
- cookie import: `BrowserCookieImporter` (Safari/Chrome/Firefox adapters)
- OpenAI dashboard web scrape: `OpenAIDashboardFetcher` (WKWebView + JS)
- cost usage: local log scanner (Codex + Claude)

The old “switch provider” wiring is gone. Everything should be driven by the descriptor and its strategies.

## Provider descriptor (source of truth)

Introduce a single descriptor per provider:
- `id` (stable `UsageProvider`)
- display/labels/URLs (menu title, dashboard URL, status URL)
- UI branding (icon name, primary color)
- capabilities (supportsCredits, supportsTokenCost, supportsStatusPolling, supportsLogin)
- fetch plan (allowed `--source` modes + ordered strategy pipeline)
- CLI metadata (cliName, aliases, version provider)
- account behavior (e.g., `usesAccountFallback` for Codex auth.json)

UI and settings should become descriptor-driven:
- no provider-specific branching for labels/links/toggle titles
- minimal provider-specific UI (only when a provider truly needs bespoke UX)

## Fetch strategies

A provider declares a pipeline of strategies, in priority order. Each strategy:
- advertises a `kind` (cli, web cookies, oauth, api token, local probe, web dashboard)
- declares availability (checks settings, cookies, env vars, installed CLI)
- fetches `UsageSnapshot` (and optional credits/dashboard)
- can be filtered by CLI `--source` or app settings

The pipeline resolves to the best available strategy, and falls back on failure when allowed.
Each run returns a `ProviderFetchOutcome` with **attempts + errors** for debug UI and CLI `--verbose`.

## Host APIs are explicit, small, testable
Expose a narrow set of protocols/structs that provider implementations can use:
- `KeychainAPI`: read-only, allowlisted service/account pairs
- `BrowserCookieAPI`: import cookies by domain list; returns cookie header + diagnostics
- `PTYAPI`: run CLI interactions with timeouts + “send on substring” + stop rules
- `HTTPAPI`: URLSession wrapper with domain allowlist + standard headers + tracing
- `WebViewScrapeAPI`: WKWebView lease + `evaluateJavaScript` + snapshot dumping
- `TokenCostAPI`: Cost Usage local-log integration (Codex/Claude today; extend later)
- `StatusAPI`: status polling helpers (Statuspage + Workspace incidents)
- `LoggerAPI`: scoped logger + redaction helpers

Rule: providers do not talk to `FileManager`, `Security`, or “browser internals” directly unless they *are* the host API implementation.

## Provider-specific code layout
- `Sources/CodexBarCore/Providers/<ProviderID>/`
  - `<ProviderID>Descriptor.swift` (descriptor + strategy pipeline)
  - `<ProviderID>Strategies.swift` (strategy implementations)
  - `<ProviderID>Probe.swift` / `<ProviderID>Fetcher.swift`
  - `<ProviderID>Models.swift`
  - `<ProviderID>Parser.swift` (if text/HTML parsing)
- `Sources/CodexBar/Providers/<ProviderID>/`
  - `<ProviderID>ProviderImplementation.swift` (settings/login UI hooks only)

## Minimal provider example (copy-paste)

```swift
import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ExampleProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .example,
            metadata: ProviderMetadata(
                id: .example,
                displayName: "Example",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Example usage",
                cliName: "example",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .codex,
                iconResourceName: "ProviderIcon-example",
                color: ProviderColor(red: 0.2, green: 0.6, blue: 0.8)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Example cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ExampleFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "example",
                versionDetector: nil))
    }
}

struct ExampleFetchStrategy: ProviderFetchStrategy {
    let id: String = "example.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: nil)
        return self.makeResult(usage: usage, sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
```

## Guardrails (non-negotiable)
- Identity silo: never display identity/plan fields from provider A inside provider B UI.
- Privacy: default to on-device parsing; browser cookies are opt-in and never persisted by us beyond WebKit stores.
- Reliability: providers must be timeout-bounded; no unbounded waits on network/PTY/UI.
- Degradation: prefer cached data over flapping; show clear errors when stale.

## Adding a new provider (current flow)

Checklist:
- Add `UsageProvider` case in `Sources/CodexBarCore/Providers/Providers.swift`.
- Create `Sources/CodexBarCore/Providers/<ProviderID>/`:
  - `<ProviderID>Descriptor.swift`: define `ProviderDescriptor` + fetch pipeline.
  - `<ProviderID>Strategies.swift`: implement one or more `ProviderFetchStrategy`.
  - `<ProviderID>Probe.swift` / `<ProviderID>Fetcher.swift`: concrete fetcher logic.
  - `<ProviderID>Models.swift`: snapshot structs.
  - `<ProviderID>Parser.swift` (if needed).
- Attach `@ProviderDescriptorRegistration` + `@ProviderDescriptorDefinition` to the descriptor type.
  Implement `static func makeDescriptor() -> ProviderDescriptor`.
- Attach `@ProviderImplementationRegistration` to the implementation type (macros auto-register).
  - No manual list edits.
- Add `Sources/CodexBar/Providers/<ProviderID>/<ProviderID>ProviderImplementation.swift`:
  - `ProviderImplementation` only for settings/login UI hooks.
- Add icons + color in descriptor:
  - `iconName` must match `ProviderIcon-<id>` asset.
  - Color used in menu cards + switcher.
- If CLI-specific behavior is needed:
  - add `cliName`, `cliAliases`, `sourceModes`, `versionProvider` in descriptor.
  - strategies decide which `--source` modes apply.
- Tests:
  - `UsageSnapshot` mapping unit tests
  - strategy availability + fallback tests
  - CLI provider parsing (aliases + --source validation)
- Docs:
  - add provider section in `docs/providers.md` with data source + auth notes
  - update `docs/provider.md` if the pipeline model changes

## UI notes (Providers settings)
Current: checkboxes per provider.

Preferred direction: table/list rows (like a “sessions” table):
- Provider (name + short auth hint)
- Enabled toggle
- Status (ok/stale/error + last updated)
- Auth source (CLI / cookies / web / oauth) when applicable
- Actions (Login / Diagnose / Copy debug log)

This keeps the pane scannable once we have >5 providers.

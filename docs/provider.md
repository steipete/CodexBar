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

This doc describes the **current provider architecture** and the exact steps to add a new provider.

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

Provider behavior is descriptor-driven. Two flat first-party manifests form the closed bootstrap boundary:
`ProviderManifest` lists core descriptors and `ProviderImplementationManifest` lists app implementations. The registries
retain thread-safe `register(_:)` methods for future dynamic providers.

## Provider descriptor (source of truth)

Introduce a single descriptor per provider:
- `id` (stable `UsageProvider`)
- display/labels/URLs (menu title, dashboard URL, status URL)
- UI branding (icon name, primary color, 2–3-color confetti palette)
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
- `BrowserLocalStorageAPI`: read origin-scoped key/value snapshots across browser profiles
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
import Foundation

public enum ExampleProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

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
                iconStyle: .init(provider: .example),
                iconResourceName: "ProviderIcon-example",
                color: ProviderColor(red: 0.2, green: 0.6, blue: 0.8),
                confettiPalette: [
                    ProviderColor(hex: 0x3399CC),
                    ProviderColor(hex: 0x66C2FF),
                ]),
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

## Hosted relay eligibility

Hosted relays and upstream aggregators need enough public evidence for maintainers and users to evaluate the trust
boundary:

- An identifiable legal operator and jurisdiction.
- Verifiable authorization to resell or provide the advertised upstream access; operator self-assertion alone is not
  sufficient.
- A public operating track record that supports ongoing reliability, security, and maintenance review.

An integration can be restored when missing operator or authorization evidence becomes available.

## Adding a new provider

The mandatory registration checklist is intentionally short:

1. Create `Sources/CodexBarCore/Providers/<Name>/` with the descriptor and fetch strategies.
2. Create `Sources/CodexBar/Providers/<Name>/` with the app implementation and optional settings extension.
3. Add one stable case to `UsageProvider` in `Sources/CodexBarCore/Providers/Providers.swift`.
4. Add one `ProviderIcon-<id>.svg` resource under `Sources/CodexBar/Resources` and reference it from branding.
5. Add one descriptor line to `ProviderManifest.allDescriptors`.
6. Add one implementation factory line to `ProviderImplementationManifest.makeImplementations`.
7. Add one case to the WidgetKit `ProviderChoice` `AppEnum`. New descriptors are widget-selectable by default; set
   `widgetSelectable: false` in the provider's descriptor only when the provider genuinely cannot appear in widgets.

Everything else is derived from the descriptor: icon-style identity, log-category construction, display and compact
labels, default enablement, fetch/CLI metadata, icon validation, and widget display representations. The provider
architecture gatekeeper test reports missing descriptor, implementation, icon, or widget registrations by provider ID.

Provider-specific behavior still deserves focused tests—for example snapshot mapping, strategy availability/fallback,
CLI aliases/source validation, and parser fixtures. Add a section to `docs/providers.md` when users need data-source or
authentication guidance.

## UI notes (Providers settings)
Current: checkboxes per provider.

Preferred direction: table/list rows (like a “sessions” table):
- Provider (name + short auth hint)
- Enabled toggle
- Status (ok/stale/error + last updated)
- Auth source (CLI / cookies / web / oauth) when applicable
- Actions (Login / Diagnose / Copy debug log)

This keeps the pane scannable once we have >5 providers.

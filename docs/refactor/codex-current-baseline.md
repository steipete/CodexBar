---
summary: "Current Codex behavior baseline before phase-1 provider-boundary refactor work."
read_when:
  - Planning Codex refactor tickets
  - Changing Codex runtime/source selection
  - Changing Codex OpenAI-web enrichment or cookie import behavior
  - Changing Codex managed/live account routing
  - Changing Codex usage window mapping or menu projection
---

# Codex current baseline

This document is the current-state parity reference for Codex behavior in CodexBar.

Use it when later tickets need to preserve or intentionally change Codex behavior. When refactor plans, summary docs,
and running code disagree, treat current code plus characterization coverage as authoritative, and use this document as
the human-readable summary of that current state.

## Scope of this baseline

This baseline captures the current Codex behavior surface that later refactor work must preserve unless a future ticket
changes it intentionally:

- provider fetch-plan runtime/source behavior,
- app-side OpenAI-web enrichment and backfill behavior,
- source-specific usage-window mapping and normalization,
- compatibility-seam projection into current menu and source-label consumers,
- managed/live/OpenAI-web identity and account siloing.

## Active behavior owners

Current Codex behavior is defined by several active owners, not one central planner:

- `Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift`
  owns the main provider fetch plan, runtime/source-mode strategy order, OAuth usage mapping, and OAuth identity/plan
  extraction.
- `Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift`
  owns Codex CLI `/status` parsing for credits, 5h usage, weekly usage, and reset text/date extraction.
- `Sources/CodexBarCore/Providers/Codex/CodexRateWindowNormalizer.swift`
  owns current session/weekly/unknown lane ordering rules.
- `Sources/CodexBarCore/UsageFetcher.swift`
  owns Codex RPC and PTY usage mapping into `UsageSnapshot`, including the normalization seam used by consumers.
- `Sources/CodexBar/Providers/Codex/CodexSettingsStore.swift`
  owns app-side Codex source settings, managed-home fail-closed behavior, and cookie-source configuration.
- `Sources/CodexBar/CodexAccountReconciliation.swift`
  owns live-vs-managed reconciliation, visible-account projection, and active-source correction when managed and live
  identities collapse onto the same account.
- `Sources/CodexBar/ProviderRegistry.swift`
  owns app-side Codex environment and fetcher scoping, including managed `CODEX_HOME` routing.
- `Sources/CodexBarCore/Providers/Codex/CodexWebDashboardStrategy.swift`
  owns fetch-plan-side web behavior when Codex web is selected through the provider pipeline, especially the CLI web
  path and fetch-plan availability/fallback semantics that are distinct from app-side OpenAI-web enrichment/backfill.
- `Sources/CodexBar/Providers/Codex/UsageStore+CodexAccountState.swift`
  owns Codex account-scoped refresh guards and stale-result rejection.
- `Sources/CodexBar/Providers/Codex/UsageStore+CodexRefresh.swift`
  owns Codex credits refresh coordination relative to the active Codex account boundary.
- `Sources/CodexBar/UsageStore+OpenAIWeb.swift`
  owns OpenAI-web dashboard refresh, targeting, cookie-import behavior, fail-closed handling, and gap-fill/backfill
  application.
- `Sources/CodexBar/Providers/Codex/CodexProviderImplementation.swift`
  owns app-visible Codex source labels, the `+ openai-web` decoration behavior, and credits menu rows.
- `Sources/CodexBar/MenuDescriptor.swift`
  owns the current compatibility seam that renders Codex windows and account/plan fallback behavior.

This fragmentation is real and intentional to record here. RAT-189 should document and characterize it, not reconcile
it.

## Current runtime and source-mode behavior

### Primary fetch-plan behavior

The generic provider fetch plan currently resolves Codex strategies in this order:

| Runtime | Selected mode | Ordered strategies | Fallback behavior |
| --- | --- | --- | --- |
| app | auto | `oauth -> cli` | OAuth can fall through to CLI. CLI is terminal. |
| app | oauth | `oauth` | No fallback. |
| app | cli | `cli` | No fallback. |
| app | web | `web` | No fallback. |
| cli | auto | `web -> cli` | Web can fall through to CLI. CLI is terminal. |
| cli | oauth | `oauth` | No fallback. |
| cli | cli | `cli` | No fallback. |
| cli | web | `web` | No fallback. |

This behavior is owned by `CodexProviderDescriptor` through `ProviderFetchPlan` and `ProviderFetchPipeline`.

Important current-state distinction:

- App `.auto` does not include OpenAI-web in the provider fetch plan.
- CLI `.auto` does include web in the provider fetch plan.
- App-side OpenAI-web behavior is a separate enrichment/backfill seam described below.

### Secondary/documented strategy surface

`CodexProviderDescriptor.resolveUsageStrategy(...)` still exists and currently maps:

- `.auto` + OAuth credentials present -> `oauth`
- `.auto` + no OAuth credentials -> `cli`
- explicit selection -> the explicit selection

Current repo search does not show this helper as the primary active runtime contract for Codex fetch execution. Treat it
as a documented secondary surface for now rather than the main parity driver, unless a later task proves an active
contract depends on it.

## OpenAI-web enrichment and backfill baseline

OpenAI-web enrichment/backfill behavior is separate from app `.auto` fetch-plan behavior.

Current behavior that later refactor work must preserve:

- OpenAI-web refresh only runs when Codex is enabled and Codex cookies are enabled.
- Managed and known-account paths use targeted refresh rules rather than arbitrary browser-account matching.
- Live-system refresh can intentionally allow any signed-in browser account only when reconciliation and current
  Codex state cannot establish a safe target email.
- Managed and live-system paths use different target-email and cookie-cache-scope behavior.
- OpenAI-web only fills gaps for usage and credits:
  - usage backfill applies only when the current Codex snapshot is missing,
  - credits backfill applies only when current Codex credits are missing.
- When OpenAI-web backfills usage, the temporary source label becomes `openai-web`.
- In the app UI, the displayed source label becomes `base + openai-web` only when dashboard data exists and login is
  not currently required.
- Managed mismatch, unreadable managed-store, and missing managed-target paths fail closed rather than falling back to
  another signed-in browser account.

This behavior is implemented primarily in:

- `Sources/CodexBar/UsageStore+OpenAIWeb.swift`
- `Sources/CodexBar/Providers/Codex/CodexProviderImplementation.swift`
- `Sources/CodexBar/UsageStore.swift`

This behavior is intentionally narrower than "provider-wide free-for-all matching" but broader than "always
account-targeted". The live-system path may bootstrap from an unknown account state and later tighten once usage,
reconciliation, or dashboard state discovers a stable email.

## Usage-window mapping and normalization baseline

Current Codex window semantics are role-based, not strictly positional.

Window-role mapping:

- `300` minutes -> session
- `10080` minutes -> weekly
- any other window length -> unknown

Current normalization rules:

- session-only stays in `primary`
- weekly-only moves to `secondary`
- unknown single-window stays in `primary`
- `(session, weekly)` stays unchanged
- `(session, unknown)` stays unchanged
- `(unknown, weekly)` stays unchanged
- `(weekly, session)` swaps to `(session, weekly)`
- `(weekly, unknown)` swaps to `(unknown, weekly)`
- other pairings preserve input order

These rules apply across the current Codex mapping surfaces:

- OAuth usage mapping in `CodexOAuthFetchStrategy.mapUsage(...)`
- Codex RPC mapping in `UsageFetcher.makeCodexUsageSnapshot(...)`
- Codex PTY `/status` mapping in `UsageFetcher.makeCodexUsageSnapshot(...)`

Current edge cases already visible in code and tests include:

- weekly-only,
- unknown single-window,
- reversed weekly/unknown ordering,
- no-window failure.

## Compatibility-seam behavior

The current consumer-facing compatibility seam is the `UsageSnapshot` shape projected through `MenuDescriptor` and the
Codex provider implementation.

Current behavior that later work must preserve:

- `MenuDescriptor` renders `primary` as the session row and `secondary` as the weekly row.
- If Codex has only a weekly window, the menu shows only a weekly row and does not synthesize a session row.
- Account and plan rows come from provider-scoped snapshot identity first.
- If provider-scoped identity is missing and the provider metadata allows fallback, the menu falls back to
  provider-scoped `AccountInfo`.
- Current Codex source-label decoration is additive:
  - base label comes from current Codex source setting or the last successful source label,
  - `+ openai-web` is appended only when dashboard data is present and login is not required.

This is a compatibility seam, not a statement that the underlying ownership is already cleanly unified.

## Identity, account, and siloing baseline

Codex identity/account behavior is source-scoped and account-scoped.

Current behavior that later refactor work must preserve:

- `UsageSnapshot` identity is provider-scoped; `accountEmail(for:)`, `loginMethod(for:)`, and related accessors only
  return data when the stored identity belongs to the requested provider.
- Managed Codex routing scopes remote account fetches through the selected managed home.
- Live-system routing preserves the ambient/system Codex home instead of silently using a managed home.
- If a persisted managed selection collapses onto the live-system account by normalized email, resolved active source
  corrects back to live-system.
- Selected managed-account paths fail closed when the managed-account store is unreadable or when the selected managed
  target no longer exists.
- OpenAI-web cookie cache scope is account-scoped for managed accounts and provider-global for live-system Codex.
- OpenAI-web target email must not reuse stale managed identity when live-system is active.
- OpenAI-web mismatch paths clear stale dashboard state instead of restoring it.
- Account-scoped refresh guards reject stale Codex usage, credits, and dashboard completions after an account switch.

There is also one intentional current boundary:

- managed-home routing only scopes remote account state such as identity, plan, quotas, credits, and dashboard data.
- local token-cost/session-history scanning remains ambient-system scoped and is not currently treated as managed-account
  owned remote state.

## Current fragmentation to preserve honestly

The current Codex behavior surface is not owned in one place.

- Fetch-plan runtime/source behavior lives in the descriptor and caller pipelines.
- Fetch-plan-side Codex web behavior also has its own owner in `CodexWebDashboardStrategy`.
- App-side OpenAI-web enrichment/backfill lives in `UsageStore` orchestration, not inside app `.auto`.
- Window normalization is centralized, but mapping into that normalizer still happens from multiple source-specific
  paths.
- Compatibility behavior is consumer-driven by the current `UsageSnapshot` shape rather than by a dedicated Codex view
  model boundary.
- Managed/live/OpenAI-web siloing is enforced by several cooperating seams: settings, reconciliation, registry,
  refresh guards, fetch-plan-side web behavior, and app-side web refresh logic.

This ticket should lock that reality in docs and characterization coverage before any ownership cleanup happens.

## Documentation contract

- [docs/codex.md](../codex.md) is the contributor-facing overview doc for Codex.
- This file is the exact current-state parity reference for Codex refactor work.
- Later Codex refactor plans should cite this file for present behavior rather than paraphrasing current semantics from
  memory.

## Characterization coverage status

Current partial coverage already exists in:

- `Tests/CodexBarTests/CodexCLIWindowNormalizationTests.swift`
- `Tests/CodexBarTests/StatusProbeTests.swift`
- `Tests/CodexBarTests/CodexOAuthTests.swift`
- `Tests/CodexBarTests/CodexManagedRoutingTests.swift`
- `Tests/CodexBarTests/MenuDescriptorCodexManagedFallbackTests.swift`
- `Tests/CodexBarTests/CodexManagedOpenAIWebTests.swift`
- `Tests/CodexBarTests/CodexAccountScopedRefreshTests.swift`

RAT-189 should add or consolidate parity-focused characterization around the stable seams above. If a current behavior
detail is real but not reachable through a stable seam without widening the task, keep it documented here instead of
forcing invasive hooks.

---
summary: "Current Claude behavior baseline before vNext refactor work."
read_when:
  - Planning Claude refactor tickets
  - Changing Claude runtime/source selection
  - Changing Claude OAuth prompt or cooldown behavior
  - Changing Claude token-account routing
---

# Claude current baseline

This document is the current-state parity reference for Claude behavior in CodexBar.

Use it when later tickets need to preserve or intentionally change Claude behavior. When the refactor plan,
summary docs, and running code disagree, treat current code plus characterization coverage as authoritative, and use
this document as the human-readable summary of that current state.

## Scope of this baseline

This baseline captures the current behavior surface that later refactor work must preserve unless a future ticket
changes it intentionally:

- runtime/source-mode selection,
- prompt and cooldown behavior that affects Claude OAuth repair flows,
- token-account routing at the app and CLI edges,
- provider siloing and web-enrichment rules,
- the current relationship between the public Claude doc and the vNext refactor plan.

## Active behavior owners

Current Claude behavior is defined by several active owners, not one central planner:

- `Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
  owns the main provider-pipeline strategy order and fallback rules.
- `Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
  still owns a separate direct `.auto` path, delegated refresh, prompt/cooldown handling, and web-extra enrichment.
- `Sources/CodexBar/Providers/Claude/ClaudeSettingsStore.swift`
  owns app-side token-account routing into cookie or OAuth behavior.
- `Sources/CodexBarCLI/TokenAccountCLI.swift`
  owns CLI-side token-account routing and effective source-mode overrides.
- `Sources/CodexBarCore/TokenAccountSupport.swift`
  owns the current string heuristics that distinguish Claude OAuth access tokens from cookie/session-key inputs.

## Current runtime and source-mode behavior

### Main provider pipeline

The generic provider pipeline currently resolves Claude strategies in this order:

| Runtime | Selected mode | Ordered strategies | Fallback behavior |
| --- | --- | --- | --- |
| app | auto | `oauth -> cli -> web` | OAuth can fall through to CLI/Web. CLI can fall through to Web only when Web is available. Web is terminal. |
| app | oauth | `oauth` | No fallback. |
| app | cli | `cli` | No fallback. |
| app | web | `web` | No fallback. |
| cli | auto | `web -> cli` | Web can fall through to CLI. CLI is terminal. |
| cli | oauth | `oauth` | No fallback. |
| cli | cli | `cli` | No fallback. |
| cli | web | `web` | No fallback. |

This behavior is owned by `Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
through `ProviderFetchPlan` and `ProviderFetchPipeline`.

### Other active `.auto` decision sites

The codebase still contains multiple active `.auto` decision sites:

| Owner | Current behavior |
| --- | --- |
| `ClaudeProviderDescriptor.resolveUsageStrategy(...)` | Chooses `oauth`, then `cli`, then `web`, with final `cli` fallback when none are available. |
| `ClaudeUsageFetcher.loadLatestUsage(.auto)` | Chooses `oauth`, then `web`, then `cli`, with final `oauth` fallback. |

This inconsistency is intentional to record here. RAT-107 directly characterizes the active direct-fetcher branches it
can reach cleanly in tests and records the remaining current-state behavior without reconciling it.

## Prompt and cooldown baseline

Current behavior that later refactor work must preserve:

- The default Claude keychain prompt mode is `onlyOnUserAction`.
- Prompt policy is only applicable when the Claude OAuth read strategy is `securityFramework`.
- User-initiated interaction clears a prior Claude keychain cooldown denial before retrying availability or repair.
- Startup bootstrap prompting is allowed only when all of these are true:
  - runtime is app,
  - interaction is background,
  - refresh phase is startup,
  - prompt mode is `onlyOnUserAction`,
  - no cached Claude credentials exist.
- Background delegated refresh is blocked when prompt policy is `onlyOnUserAction` and the caller did not explicitly
  allow background delegated refresh.
- Prompt mode `never` blocks delegated refresh attempts.
- Expired credential owner behavior remains owner-specific:
  - `.claudeCLI`: delegated refresh path,
  - `.codexbar`: direct refresh path,
  - `.environment`: no auto-refresh.

## Token-account routing baseline

Accepted Claude token-account input shapes today:

- raw OAuth access token with `sk-ant-oat...` prefix,
- `Bearer sk-ant-oat...` input,
- raw session key,
- full cookie header.

Current routing rules:

- OAuth-token-shaped inputs are not treated as cookies.
- Cookie/header-shaped inputs are any value that already contains `Cookie:` or `=`.
- App-side Claude snapshot behavior:
  - OAuth token account keeps the usage source setting as-is, disables cookie mode (`.off`), clears the manual cookie
    header, and relies on environment-token injection.
  - Session-key or cookie-header account keeps the usage source setting as-is, forces manual cookie mode, and
    normalizes raw session keys into `sessionKey=<value>`.
- CLI-side Claude token-account behavior:
  - OAuth token account changes the effective source mode from `auto` to `oauth`, disables cookie mode, omits a
    manual cookie header, and injects `CODEXBAR_CLAUDE_OAUTH_TOKEN`.
  - Session-key or cookie-header account stays in cookie/manual mode.

## Siloing and web-enrichment baseline

Claude Web enrichment is cost-only when the primary source is OAuth or CLI:

- Web extras may populate `providerCost` when it is missing.
- Web extras must not replace `accountEmail`, `accountOrganization`, or `loginMethod` from the primary source.
- Snapshot identity remains provider-scoped to Claude.

This behavior is implemented in `Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
inside `applyWebExtrasIfNeeded`.

## Documentation contract

- [docs/claude.md](../claude.md) is the summary doc for contributors who want an overview.
- This file is the exact current-state baseline for contributor and refactor parity work.
- [claude-provider-vnext-locked.md](claude-provider-vnext-locked.md)
  is the future refactor plan and should cite this file for present behavior.

## Characterization coverage

Stable automated coverage for this baseline lives in:

- `Tests/CodexBarTests/ClaudeBaselineCharacterizationTests.swift`
- `Tests/CodexBarTests/ClaudeOAuthFetchStrategyAvailabilityTests.swift`
- `Tests/CodexBarTests/ClaudeUsageTests.swift`
- `Tests/CodexBarTests/TokenAccountEnvironmentPrecedenceTests.swift`
- `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`

`ClaudeUsageTests.swift` now directly characterizes the reachable `ClaudeUsageFetcher(.auto)` branches for:

- OAuth when OAuth, Web, and CLI all appear available,
- Web before CLI when OAuth is unavailable,

The successful CLI-selected branch and the CLI-failure-to-OAuth fallback remain documented from code inspection plus
surrounding Claude probe/regression coverage, because the current CLI-availability decision is sourced from process-wide
binary discovery with no stable test seam that would keep RAT-107 in scope.

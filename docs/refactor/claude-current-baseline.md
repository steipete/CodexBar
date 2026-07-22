---
summary: "Current Claude source-selection and credential-ownership baseline."
read_when:
  - Planning Claude refactor tickets
  - Changing Claude runtime/source selection
  - Changing Claude credential ownership or OAuth behavior
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
- the production boundary around Claude Code-owned credentials,
- explicit app OAuth compatibility,
- token-account routing at the app and CLI edges,
- provider siloing and web-enrichment rules,
- the current relationship between the public Claude doc and the vNext refactor plan.

## Active behavior owners

Current Claude behavior is defined by several active owners, not one central planner:

- `Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
  owns the main provider-pipeline strategy order and fallback rules.
- `Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
  executes planned sources, explicit OAuth refresh behavior, and web-extra enrichment.
- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`
  enforces the production prohibition on direct access to Claude Code's Keychain item.
- `Sources/CodexBar/Providers/Claude/ClaudeSettingsStore.swift`
  owns app-side explicit-source persistence and token-account routing into cookie or OAuth behavior.
- `Sources/CodexBarCLI/TokenAccountCLI.swift`
  owns CLI-side token-account routing and effective source-mode overrides.
- `Sources/CodexBarCore/TokenAccountSupport.swift`
  owns the current string heuristics that distinguish Claude OAuth access tokens from cookie/session-key inputs.

## Current runtime and source-mode behavior

### Main provider pipeline

The generic provider pipeline currently resolves Claude strategies in this order:

| Runtime | Selected mode | Ordered strategies | Fallback behavior |
| --- | --- | --- | --- |
| app | auto | `cli -> web` | CLI is preferred when installed; Web is the only fallback. Auto never plans direct OAuth. |
| app | selected OAuth token account | `oauth` | Account-scoped and terminal; it never falls through to another account. |
| app | oauth | `oauth` | Persisted and newly selected explicit OAuth remains terminal and uses only noninteractive environment, file, or CodexBar-owned credentials. |
| app | api | `api` | No fallback. |
| app | cli | `cli` | No fallback. |
| app | web | `web` | No fallback. |
| cli | auto | `web -> cli` | Web can fall through to CLI. CLI is terminal. |
| cli | oauth | `oauth` | No fallback. |
| cli | api | `api` | No fallback. |
| cli | cli | `cli` | No fallback. |
| cli | web | `web` | No fallback. |

This behavior is owned by `Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
through `ProviderFetchPlan` and `ProviderFetchPipeline`.

### `.auto` decision sites

Both active entry points resolve through `ClaudeSourcePlanner`:

| Owner | Current behavior |
| --- | --- |
| `ClaudeProviderDescriptor.resolveUsageStrategy(...)` | App Auto plans `cli`, then `web`. |
| `ClaudeUsageFetcher.loadLatestUsage(.auto)` | Uses the same planner and does not probe OAuth availability. |

The app descriptor also skips OAuth availability work while building an Auto plan. This matters because availability
checks must not become an indirect route back to Claude Code's Keychain item.

## Credential-ownership baseline

`Claude Code-credentials` belongs to Claude Code. Claude Code can replace it during token refresh, which also replaces
its access-control list and invalidates any prior **Always Allow** grant to CodexBar.

Current production invariants:

- CodexBar never reads `Claude Code-credentials` with Security.framework, including a no-UI query.
- CodexBar never launches `/usr/bin/security` to read that item.
- Claude refresh/history bookkeeping fingerprints only the credentials file; it does not read a Keychain fingerprint or
  persistent reference before or after a refresh.
- App Auto runs the noninteractive, owner-mediated `claude auth status --json` preflight before starting the CLI PTY.
  This prevents a logged-out background probe from opening an interactive browser sign-in.
- The global Keychain-access switch and legacy Claude prompt-mode/read-strategy preferences cannot reopen this boundary.
- Synthetic task-local Keychain records remain available in DEBUG tests, but do not enable production access.

The Claude-specific “Avoid Keychain prompts” toggle and Keychain prompt-policy picker are no longer exposed. Their
settings could only choose when an unstable foreign-item access was attempted; they could not make the grant durable.

Explicit app OAuth and OAuth token accounts can load credentials supplied through an environment token, CodexBar's own
cache, or Claude's secure-storage `.credentials.json` (normally `~/.claude/.credentials.json`). Credential loads are
noninteractive and never bootstrap or repair from Claude Code's Keychain item.

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
  - A persisted or newly selected `.oauth` source remains `.oauth` and is offered in the app picker; it never falls
    through to Auto's CLI/Web route.
  - A selected OAuth token account forces its snapshot to `.oauth`, disables cookie mode (`.off`), clears the manual
    cookie header, and relies on environment-token injection.
  - A selected session-key or cookie-header account forces its snapshot to `.web`, uses manual cookie mode, and
    normalizes raw session keys into `sessionKey=<value>`; it overrides every ambient global source.
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
- `Tests/CodexBarTests/ClaudeCredentialOwnershipBoundaryTests.swift`
- `Tests/CodexBarTests/ClaudeOAuthFetchStrategyAvailabilityTests.swift`
- `Tests/CodexBarTests/ClaudeUsageTests.swift`
- `Tests/CodexBarTests/TokenAccountEnvironmentPrecedenceTests.swift`
- `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`

The characterization suite covers app Auto's CLI-to-Web order, the absence of OAuth planning in Auto, persisted
explicit app OAuth, OAuth-token-account routing, and the default-deny production Keychain boundary. OAuth repository
tests use only synthetic task-local records.

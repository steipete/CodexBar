# Kilo Organization Selection & Usage — Design

**Status:** approved
**Date:** 2026-05-11
**Owner:** noefabris

## Problem

The Kilo provider in CodexBar always queries the personal account. Users who belong to one or more Kilo organizations cannot see organization-level credits, KiloPass usage, or plan info. Kilo's own clients (VS Code extension, CLI) let users pick "Personal" or any organization they belong to and route requests with an `X-KILOCODE-ORGANIZATIONID` header.

Goal: let CodexBar users opt in to seeing one or more Kilo organizations alongside their personal account.

## Non-goals

- Menu-bar org switcher. Selection lives in Preferences only.
- Editing org membership from CodexBar (read-only consumer of Kilo's org list).
- Per-org auth (CodexBar reuses the same API key/CLI session; Kilo's gateway scopes via header).
- Replacing the existing single-account `Personal` flow when no orgs are configured.

## Constraints / context

- Kilo gateway accepts `X-KILOCODE-ORGANIZATIONID: <orgId>` to scope any authenticated request. Documented at `kilo.ai/docs/gateway/authentication`.
- Profile endpoint shape (from `Kilo-Org/kilocode` `packages/kilo-gateway/src/api/profile.ts`):
  `GET /api/profile` → `{ user: { email, name }, organizations: [{ id, name, role }] }`.
- CodexBar's Kilo provider currently calls `https://app.kilo.ai/api/trpc` with procedures `user.getCreditBlocks`, `kiloPass.getState`, `user.getAutoTopUpPaymentMethod`. The `X-KILOCODE-ORGANIZATIONID` header is transport-level and must work for the same procedures.
- Existing CodexBar patterns to reuse:
  - `ProviderIdentitySnapshot.accountOrganization` for rendering the org name in a card.
  - Stacked multi-snapshot rendering used by Claude tokenAccounts (Preferences → Advanced → Display).
  - `~/.codexbar/config.json` per-provider entry for persisted state.

## User stories

1. **As a user with no orgs**, the Kilo card looks exactly as it does today. No new UI noise.
2. **As a user with one or more orgs**, I can open Preferences → Providers → Kilo, hit "Refresh organizations", see my org list, and tick the orgs I want to monitor. Each enabled org appears as its own card stacked with Personal in the menu.
3. **As a user whose API key isn't set**, the Organizations section explains I need the key first and the Refresh button is disabled.
4. **As a user using CLI source mode**, org selection still works — the header is sent on every fetch regardless of where the bearer token came from.

## Architecture

### Data model

- `KiloOrganization` (Sendable, Codable, Equatable) in `Sources/CodexBarCore/Providers/Kilo/`:
  - `id: String`
  - `name: String`
  - `role: String?` (optional; treated as display-only)
- `KiloUsageScope` (Sendable, Hashable) in same module:
  - `.personal`
  - `.organization(id: String, name: String)`
  - A `scopeIdentifier` computed property: `"personal"` or `"org:<id>"` used as the snapshot map key.
- `KiloUsageSnapshot` gains `scope: KiloUsageScope` (default `.personal` keeps existing call sites compiling).

### API layer (`KiloUsageFetcher`)

- Existing `fetchUsage(apiKey:environment:)` becomes:
  `fetchUsage(apiKey:scope:environment:)` with `scope: KiloUsageScope = .personal`.
  - When `.organization(id, _)`: set request header `X-KILOCODE-ORGANIZATIONID: id` on the existing tRPC batch URLRequest. Everything else unchanged.
- New `fetchOrganizations(apiKey:environment:)` → `[KiloOrganization]`:
  - Primary: tRPC batch call to `user.getOrganizations` against `https://app.kilo.ai/api/trpc`. Parse the same payload-context shape as other procedures (defensive against schema drift).
  - Fallback: if tRPC returns 404 / endpoint not found, fall back to `GET https://api.kilo.ai/api/profile` and read `data.organizations`. Both endpoints are part of the documented Kilo Gateway.
  - Returns `[]` (not error) when the user has no orgs.
  - Maps `401/403 → KiloUsageError.unauthorized`, `404 → endpointNotFound`, etc., using the existing `statusError(for:)`.

### Settings

`SettingsStore` extension (new file `SettingsStore+Kilo.swift` or extend `KiloSettingsStore.swift`):

- `kiloKnownOrganizations: [KiloOrganization]` — cache of organizations last fetched. Survives restart.
- `kiloEnabledOrganizationIDs: Set<String>` — which orgs the user wants to fetch + render.
- Personal scope is implicit: always enabled, can't be toggled off.

Persistence:
- Add `organizations: [KiloOrganization]?` and `enabledOrganizationIds: [String]?` to the Kilo provider's entry in `~/.codexbar/config.json`.
- Mutators write through `updateProviderConfig(provider: .kilo)`.

### Refresh / UsageStore

- `UsageStore`'s Kilo refresh path computes the active scope list: `[.personal] + enabled orgs from kiloKnownOrganizations`.
- Fan-out using a `TaskGroup`, one child per scope, each calling `KiloUsageFetcher.fetchUsage(apiKey:scope:)`.
- Per-scope failures isolated: a 403 on one org sets that scope's error state but does not affect personal or other orgs.
- Snapshots stored in a new dictionary `kiloScopedSnapshots: [String: KiloUsageSnapshot]` keyed by `scope.scopeIdentifier`, alongside the existing single-snapshot field. When `kiloScopedSnapshots` has more than one entry the menu uses stacked rendering; otherwise existing single-card rendering.

### UI — Preferences → Providers → Kilo

- New section header "Organizations" placed below the API key field.
- Row 1 (always): `Personal account` with a disabled-on checkbox.
- Rows 2..N: each known organization with a togglable checkbox `[✓] <Org name> — <role>`.
- Empty state when `kiloKnownOrganizations` is empty: "No organizations loaded. Click Refresh after setting your API key."
- "Refresh organizations" button:
  - Disabled when API key is empty.
  - Calls `KiloUsageFetcher.fetchOrganizations(apiKey:)` on a background task.
  - On success: writes to `kiloKnownOrganizations`, prunes `kiloEnabledOrganizationIDs` entries that no longer exist.
  - On 401/403: surface inline error "API key unauthorized. Refresh or update it."
  - On network error: surface inline error.

### Menu rendering

- The Kilo card renderer reads `kiloScopedSnapshots`. When count > 1, render each as a stacked card using the same vertical layout already used by Claude's stacked tokenAccount snapshots.
- Each scope's card sets `ProviderIdentitySnapshot.accountOrganization`:
  - `.personal` → `"Personal"`
  - `.organization(_, name)` → `name`
- Existing credit/pass/plan rows render unchanged inside each card.

### Errors / edge cases

| Case | Behavior |
| --- | --- |
| User has no orgs | Personal scope only. Org section shows empty state. No fan-out. |
| API key missing | Refresh button disabled. Existing missing-credentials error still surfaces on usage fetch. |
| Org refresh fails (401/403) | Inline error in Preferences; keep cached list. |
| Org usage fetch returns 403 | That org's card shows a small error label; personal + other orgs render normally. |
| Org removed on Kilo side | Next Refresh drops it from `kiloKnownOrganizations`; if it was in `kiloEnabledOrganizationIDs` it is silently pruned. |
| CLI source mode | Header sent same way. If the resolved CLI bearer can't scope to that org, it 403s — handled by the per-scope error case above. |
| Source = `auto` | Org scope follows the same auto fallback; failures inside the scope respect the fallback chain. |
| Multiple orgs enabled | Concurrent fetch; per-scope timeouts isolated. |

## Testing

- Unit tests (in `Tests/CodexBarTests`):
  - `KiloUsageFetcherTests`:
    - Header injection: `.organization(id, _)` → request contains `X-KILOCODE-ORGANIZATIONID: id`. `.personal` → no header.
    - `fetchOrganizations` parses both tRPC shape and `/api/profile` REST shape.
    - 401/403 → `.unauthorized`.
  - `KiloSettingsStoreTests`:
    - Round-trip of `kiloKnownOrganizations` and `kiloEnabledOrganizationIDs` through config.json.
    - Pruning of stale IDs when known list shrinks.
  - `UsageStore+KiloRefreshTests`:
    - Fan-out runs N scopes, per-scope error isolation.
    - Single-scope path unchanged when no orgs enabled.
- CLI snapshot test (`Tests/CodexBarTests/CLIRendererTests` or similar): `codexbar-cli kilo` shows one section per active scope when orgs are enabled.
- Run `make check` and `swift test` before handoff.

## Migration / compatibility

- `KiloUsageSnapshot.scope` defaults to `.personal` — all existing call sites compile unchanged.
- Config additions are optional — old configs continue to load as personal-only.
- No new dependencies.

## Open items (verify during build)

- Confirm `https://app.kilo.ai/api/trpc/user.getOrganizations` exists. If not, the REST fallback to `https://api.kilo.ai/api/profile` is the path of record.
- Confirm the tRPC procedures honor `X-KILOCODE-ORGANIZATIONID`. Documented for gateway; spot-check during integration.

## Out of scope

- Menu-bar org switcher UI.
- Per-org token storage / multiple API keys for the same provider.
- CLI command for org switching (`codexbar-cli` consumes the same settings).
- Widget rendering changes for multi-scope (widget continues to show personal scope).

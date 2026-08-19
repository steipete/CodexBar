---
summary: "Fireworks provider data sources: API key account discovery and the 30-day spend billing summary."
read_when:
  - Adding or tweaking Fireworks spend parsing
  - Updating Fireworks API key or account slug handling
  - Documenting Fireworks provider behavior
---

# Fireworks provider

Fireworks is API-only for billing: there is no public credit-balance endpoint, so CodexBar shows the
**last 30 days of rated spend** from the account billing summary API instead of a balance gauge.

## Data sources

1. **API key** stored in `~/.codexbar/config.json` or supplied via `FIREWORKS_API_KEY` (legacy alias: `FIREWORKS_KEY`).
2. **Optional account slug** stored in `~/.codexbar/config.json` or supplied via `FIREWORKS_ACCOUNT_SLUG`.

CodexBar calls `GET https://api.fireworks.ai/v1/accounts` to list the accounts visible to the key. A single
account is selected automatically and its slug is saved to the config. When several accounts are visible, the
user must choose one in the app.fireworks.ai home account switcher or obtain it from `firectl whoami`, then enter
it in Settings. A configured slug remains useful for selecting among multiple accounts.

## Spend endpoint

- `GET https://api.fireworks.ai/v1/accounts/{account_slug}/billing/summary?startTime=...&endTime=...`
- Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
- The 30-day window is sent explicitly (`startTime`/`endTime` as ISO 8601); `granularity` is not requested.
- Response contains `lineItems` with rated `totalCost` entries (`currencyCode`, `units`, `nanos`).
- CodexBar sums `units + nanos / 1e9` across line items, using the first rated currency as the display currency
  and skipping rows in other currencies.

## Usage details

- The menu card shows the 30-day spend, e.g. `$0.53` under a "Spend" label.
- There is no session or weekly window — Fireworks does not expose per-window quota via API.
- HTTP 401/403 surfaces an invalid-key message, 429 a rate-limit message.
- A 404 for a configured slug retries account discovery. An empty billing response is accepted only when the
  slug is present in the account listing, so a guessed or stale slug cannot look like a successful refresh.
- There is no balance display; the Fireworks web console (app.fireworks.ai → Settings/Billing) is the
  authoritative balance source.

## Plugin conversion status

The native fetcher remains authoritative. A valid response with no rated line items for a listed account
intentionally produces a successful snapshot with no rate window, cost, or detail; the current plugin snapshot
contract rejects that shape.

## Key files

- `Sources/CodexBarCore/Providers/Fireworks/FireworksProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Fireworks/FireworksUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/Fireworks/FireworksSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/Fireworks/FireworksProviderImplementation.swift` (settings fields)
- `Sources/CodexBar/Providers/Fireworks/FireworksSettingsStore.swift` (SettingsStore extension)

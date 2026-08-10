---
summary: "Fireworks provider data sources: API key, account slug, and the 30-day spend billing summary."
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
2. **Account slug** stored in `~/.codexbar/config.json` or supplied via `FIREWORKS_ACCOUNT_SLUG`.

The slug is the segment after `/accounts/` in console URLs (e.g. the slug for
`app.fireworks.ai/accounts/x0mh0x` is `x0mh0x`). Fireworks does not expose a whoami endpoint, so the slug
cannot be derived from the API key and is required. Settings shows an API key field plus an Account slug field,
and the config validator flags a missing slug when a key is configured.

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
- There is no balance display; the Fireworks web console (app.fireworks.ai → Settings/Billing) is the
  authoritative balance source.

## Plugin conversion status

The native fetcher remains authoritative. A valid response with no rated line items intentionally produces a
successful snapshot with no rate window, cost, or detail; the current plugin snapshot contract rejects that shape.

## Key files

- `Sources/CodexBarCore/Providers/Fireworks/FireworksProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Fireworks/FireworksUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/Fireworks/FireworksSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/Fireworks/FireworksProviderImplementation.swift` (settings fields)
- `Sources/CodexBar/Providers/Fireworks/FireworksSettingsStore.swift` (SettingsStore extension)

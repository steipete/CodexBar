---
summary: "Moonshot / Kimi API provider data sources: API key + balance endpoint."
read_when:
  - Adding or tweaking Moonshot balance parsing
  - Updating Moonshot / Kimi API key handling
  - Documenting Moonshot / Kimi API provider behavior
---

# Moonshot / Kimi API provider

Moonshot / Kimi API is API-only. Balance is reported by `GET /v1/users/me/balance`,
so CodexBar only needs a valid API key to show the current account balance.

## Rationale

Kimi API docs use the Moonshot API surface for current Kimi models: examples read
`MOONSHOT_API_KEY` and call `https://api.moonshot.ai/v1`, including the Kimi K2.6
quickstart. This provider is therefore named after the account and billing surface,
not a specific Kimi model version.

The existing `Kimi K2` provider remains separate because it targets the legacy
`kimi-k2.ai` credit endpoint. Migrating or deprecating that provider should be a
separate cleanup so existing user settings are not silently repointed.

## Data sources

1. **API key** stored in `~/.codexbar/config.json` or supplied via `MOONSHOT_API_KEY` / `MOONSHOT_KEY`.
   CodexBar stores the key in config after you paste it in Settings → Providers → Moonshot / Kimi API.
2. **Region**
   - International: `https://api.moonshot.ai/v1/users/me/balance`
   - China mainland: `https://api.moonshot.cn/v1/users/me/balance`
   - Configure with Settings → Providers → Moonshot → API region or `MOONSHOT_REGION`.
3. **Balance endpoint**
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response contains `available_balance`, `voucher_balance`, and `cash_balance`.

## Usage details

- The menu card shows the available balance.
- If `cash_balance` is negative, the card also surfaces the deficit.
- There is no session or weekly window — Moonshot / Kimi API does not expose per-window quota via API.
- Settings config takes precedence over environment variables when both are present.

## Key files

- `Sources/CodexBarCore/Providers/Moonshot/MoonshotProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/Moonshot/MoonshotProviderImplementation.swift` (settings field + activation logic)
- `Sources/CodexBar/Providers/Moonshot/MoonshotSettingsStore.swift` (SettingsStore extension)

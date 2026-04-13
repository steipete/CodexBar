---
summary: "Moonshot provider data sources: official API key + balance endpoint."
read_when:
  - Adding or tweaking Moonshot balance parsing
  - Updating Moonshot API key or region handling
  - Documenting the official Moonshot provider
---

# Moonshot provider

Moonshot is API-only. CodexBar calls the official Moonshot balance endpoint and shows the available USD balance for the selected region.
This provider is intentionally separate from Kimi K2, which points at the third-party `kimi-k2.ai` service instead of Moonshot's official platform.

Official docs: <https://platform.moonshot.ai/docs/api/balance>

## Data sources + configuration

1. **API key** stored in `~/.codexbar/config.json` or supplied via `MOONSHOT_API_KEY` / `MOONSHOT_KEY`.
   CodexBar stores the key in config after you paste it in Preferences → Providers → Moonshot.
2. **Region** stored in `~/.codexbar/config.json` (`providerConfig.moonshot.region`) or supplied via `MOONSHOT_REGION`.
   Supported values: `international` and `china`. Default: `international`.
3. **Balance endpoint**
   - International: `GET https://api.moonshot.ai/v1/users/me/balance`
   - China: `GET https://api.moonshot.cn/v1/users/me/balance`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`

## Response format

Moonshot documents a stable JSON object:

```json
{
  "code": 0,
  "data": {
    "available_balance": 49.58,
    "voucher_balance": 50.0,
    "cash_balance": -0.42
  }
}
```

CodexBar displays:
- `Balance: $X.XX`
- `No limit set`
- `cash_balance` deficits as `... in deficit` when the cash portion is negative

There is no session window, weekly window, or reset timestamp for Moonshot.

## Key files

- `Sources/CodexBarCore/Providers/Moonshot/MoonshotProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotSettingsReader.swift`
- `Sources/CodexBar/Providers/Moonshot/MoonshotProviderImplementation.swift`
- `Sources/CodexBar/Providers/Moonshot/MoonshotSettingsStore.swift`

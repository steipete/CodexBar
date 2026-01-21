---
summary: "Kimi K2 provider data sources: API key + credit endpoint."
read_when:
  - Adding or tweaking Kimi K2 usage parsing
  - Updating API key handling or config migration
  - Documenting new provider behavior
---

# Kimi K2 provider

Kimi K2 is API-only. Usage is reported by the credit counter behind `GET https://kimi-k2.ai/api/user/credits`,
so CodexBar only needs a valid API key to pull your remaining balance and usage.

## Data sources + fallback order

1) **API key** stored in `~/.codexbar/config.json` or supplied via `KIMI_K2_API_KEY` / `KIMI_API_KEY` / `KIMI_KEY`.
   CodexBar stores the key in config after you paste it in Preferences → Providers → Kimi K2.
2) **Credit endpoint**
   - `GET https://kimi-k2.ai/api/user/credits`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response headers may include `X-Credits-Remaining`.
   - JSON payload contains total credits consumed, credits remaining, and optional usage metadata.
     CodexBar scans common keys and falls back to the remaining header when JSON omits it.

## Usage details

- Credits are the billing unit; CodexBar computes used percent as `consumed / (consumed + remaining)`.
- There is no explicit reset timestamp in the API, so the snapshot has no reset time.
- Environment variables take precedence over config.

## Key files

- `Sources/CodexBarCore/Providers/KimiK2/KimiK2ProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/KimiK2/KimiK2UsageFetcher.swift` (HTTP client + parser)
- `Sources/CodexBarCore/Providers/KimiK2/KimiK2SettingsReader.swift` (env var parsing)
- `Sources/CodexBar/Providers/KimiK2/KimiK2ProviderImplementation.swift` (settings field + activation logic)
- `Sources/CodexBar/KimiK2TokenStore.swift` (legacy migration helper)

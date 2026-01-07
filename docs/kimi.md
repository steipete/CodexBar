---
summary: "Kimi provider data sources: API key + credit endpoint."
read_when:
  - Adding or tweaking Kimi usage parsing
  - Updating API key handling or Keychain prompts
  - Documenting new provider behavior
---

# Kimi provider

Kimi (Coding Moonshot) is API-only. Usage is reported by the credit counter behind `GET https://kimi-k2.ai/api/user/credits`, so CodexBar only needs a valid API key to pull your remaining balance and historical usage.

## Data sources + fallback order

1) **API token** (KIMI API key) stored in Keychain or supplied via `KIMI_API_KEY`/`KIMI_KEY` environment variable. CodexBar prompts for the key once and keeps it in `com.steipete.CodexBar` → `kimi-api-token`.
2) **Credit endpoint**
   - `GET https://kimi-k2.ai/api/user/credits`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response headers include `X-Credits-Remaining`.
   - JSON payload contains total credits consumed, credits remaining, usage by day/hour, and average tokens per request (CodexBar scans for whatever keys the service returns and falls back to the remaining header when the JSON omits it).

## Usage details

- Credits are the billing unit (`1 credit = 1 request`, failed requests are not charged, and usage history is kept in the dashboard).
- CodexBar treats the sum of `credits remaining + credits consumed` as the total window and reports the used percent on the menu bar icon. There is no explicit reset timestamp, so the widget stays `updatedAt = now`.
- If your environment already exposes `KIMI_API_KEY`, CodexBar prefers the environment token before falling back to Keychain.

## Key files

- `Sources/CodexBarCore/Providers/Kimi/KimiProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Kimi/KimiUsageFetcher.swift` (HTTP client + parser)
- `Sources/CodexBarCore/Providers/Kimi/KimiSettingsReader.swift` (env var parsing)
- `Sources/CodexBar/Providers/Kimi/KimiProviderImplementation.swift` (settings field + activation logic)
- `Sources/CodexBar/KimiTokenStore.swift` (Keychain persistence + prompt)

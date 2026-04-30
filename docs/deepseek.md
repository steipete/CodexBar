---
summary: "DeepSeek provider data sources: API key + balance endpoint."
read_when:
  - Adding or tweaking DeepSeek balance parsing
  - Updating API key handling
  - Documenting new provider behavior
---

# DeepSeek provider

DeepSeek is API-only. Balance is reported by `GET https://api.deepseek.com/user/balance`,
so CodexBar only needs a valid API key to show your remaining credit balance.

## Data sources

1. **API key** stored in `~/.codexbar/config.json` or supplied via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`.
   CodexBar stores the key in config after you paste it in Settings → Providers → DeepSeek.
2. **Balance endpoint**
   - `GET https://api.deepseek.com/user/balance`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response contains `is_available`, and a `balance_infos` array with per-currency entries
     (`total_balance`, `granted_balance`, `topped_up_balance`).

## Usage details

- The menu card shows total balance with the paid vs. granted breakdown:
  e.g. `$50.00 (Paid: $40.00 / Granted: $10.00)`.
- Granted credits are promotional and may expire; topped-up credits are user-paid and do not expire.
- When multiple currencies are present, USD is shown preferentially.
- `is_available: false` from the API dims the icon and shows "Account unavailable".
- There is no session or weekly window — DeepSeek does not expose per-window quota via API.
- Settings config takes precedence over environment variables when both are present.

## Key files

- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/DeepSeek/DeepSeekProviderImplementation.swift` (settings field + activation logic)
- `Sources/CodexBar/Providers/DeepSeek/DeepSeekSettingsStore.swift` (SettingsStore extension)

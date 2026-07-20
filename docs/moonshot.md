---
summary: "Moonshot / Kimi open-platform balance: API key + China/intl region."
read_when:
  - Adding or tweaking Moonshot balance parsing
  - Updating Moonshot / Kimi open-platform key handling
  - Documenting China vs international Kimi API hosts
---

# Moonshot / Kimi Open Platform provider

Tracks **open-platform pay-as-you-go balance** via `GET /v1/users/me/balance`.
This is the product with a real **China mainland** API host (`api.moonshot.cn`).

## Not Kimi Code subscription

| Product | Host | CodexBar provider |
| --- | --- | --- |
| **Open platform (this page)** | `api.moonshot.cn` / `api.moonshot.ai` | `moonshot` |
| **Kimi Code weekly quota** | `api.kimi.com` only | `kimi` — see [kimi.md](kimi.md) |

Do not paste a Kimi Code subscription key into this provider. Keys from
`platform.kimi.com` (China) or `platform.moonshot.ai` (intl) belong here.

CLI aliases: `moonshot`, `kimi-open`, `kimi-cn`, `moonshot-cn`.

## Rationale

Kimi open-platform docs use the Moonshot API surface: examples read `MOONSHOT_API_KEY`
and call `https://api.moonshot.ai/v1` (global) or `https://api.moonshot.cn/v1` (China).
CodexBar names this after the billing surface, not a single model version.

## Data sources

1. **API key** stored in `~/.codexbar/config.json` or supplied via `MOONSHOT_API_KEY` / `MOONSHOT_KEY`.
   CodexBar stores the key after you paste it in Settings → Providers → Moonshot / Kimi Open Platform.
2. **Region**
   - International: `https://api.moonshot.ai/v1/users/me/balance` (console: platform.moonshot.ai)
   - China mainland: `https://api.moonshot.cn/v1/users/me/balance` (console: platform.kimi.com)
   - Configure with Settings → Providers → Moonshot → API region or `MOONSHOT_REGION`.
3. **Balance endpoint**
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response contains `available_balance`, `voucher_balance`, and `cash_balance`.

## Usage details

- The menu card shows the available balance.
- If `cash_balance` is negative, the card also surfaces the deficit.
- There is no session or weekly window — the open platform does not expose per-window quota via this API.
- Settings config takes precedence over environment variables when both are present.

## Key files

- `Sources/CodexBarCore/Providers/Moonshot/MoonshotProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/Moonshot/MoonshotSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/Moonshot/MoonshotProviderImplementation.swift` (settings field + activation logic)
- `Sources/CodexBar/Providers/Moonshot/MoonshotSettingsStore.swift` (SettingsStore extension)

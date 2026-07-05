---
summary: "DeepSeek provider data sources: API key balance + platform web session usage summaries."
read_when:
  - Adding or tweaking DeepSeek balance parsing
  - Updating API key handling
  - Documenting new provider behavior
---

# DeepSeek provider

DeepSeek combines two auth surfaces:

1. **API key balance** — `GET https://api.deepseek.com/user/balance` with `Authorization: Bearer <api key>`.
2. **Platform usage summaries** — `GET https://platform.deepseek.com/api/v0/usage/amount` and `/usage/cost` with a **platform.deepseek.com web session** (browser Cookie and/or Authorization header). Bearer API keys return `code: 40003` on these endpoints.
3. **Platform account summary** — `GET https://platform.deepseek.com/api/v0/users/get_user_summary` (web session) returns wallet balances (`normal_wallets` = paid, `bonus_wallets` = granted), `total_available_token_estimation`, and `monthly_costs`. This lets CodexBar show balance **without an API key** when only a web session is present.
4. **Platform identity** — `GET https://platform.deepseek.com/auth-api/v0/users/current` (web session; note the `/auth-api/` prefix) returns masked `email`/`mobile_number`, `currency`, and `balance_alert` (per-currency `enabled` + `alert_bound`).

When an API key is present CodexBar uses it for balance and enriches with the web session (usage + account summary + identity). When no API key is present but a web session is available, the `deepseek.web` strategy produces balance + usage from the session alone. Optional usage dashboards use the same inline KPI grid and sparkline as upstream CodexBar when a platform web session is available.

## Data sources

1. **API key** via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`, or DeepSeek token accounts in `~/.codexbar/config.json`.
2. **Balance endpoint** (`api.deepseek.com/user/balance`) — Bearer API key only.
3. **Usage amount/cost endpoints** (`platform.deepseek.com/api/v0/usage/*`) — web session only:
   - Settings → Providers → DeepSeek → **Usage summary source**
   - Env override: `DEEPSEEK_COOKIE` / `DEEPSEEK_PLATFORM_SESSION` (Cookie or `Bearer …` header value)
   - Browser import (Chrome by default) on **user-initiated refresh** (⌘R), then cached for background refreshes
   - Early in the month, CodexBar also fetches the prior month so 7d/30d trends stay rolling instead of truncating at the calendar boundary.

## Usage details

- Menu card shows total balance with paid vs. granted breakdown.
- When **Show optional credits & extra usage** is enabled and a platform session is available, the card also shows the upstream inline dashboard (Today / This month / Models / Requests KPIs, 30-day sparkline, and cache-hit / cache-miss / output breakdown lines).
- **Widgets**: DeepSeek is available in compact metric and switcher widgets when optional usage data is present.
- Optional usage summary lines in the text menu are owned by `DeepSeekProviderImplementation.appendUsageMenuEntries` and gated by the optional-usage setting.
- **Status page**: when **Check provider status** is enabled, CodexBar polls `status.deepseek.com` and shows native component rows for **API Service** and **Web Chat Service** (Flashcat `/summary/active` feed).
- Without a platform session, balance still refreshes; usage summaries are omitted (expected).
- The API separates granted balance from topped-up balance; CodexBar labels these as granted vs. paid credit.
- When a web session provides `get_user_summary`, its wallet balances take precedence over the API-key balance in the menu-card balance line, which also appends `≈<n> tok` from `total_available_token_estimation`.
- When `users/current` reports an enabled balance alert and the balance drops below `alert_bound`, the balance line is marked full (warning styling) and appends `— below alert <amount>`. The masked account email flows into the provider identity snapshot.
- Fetch strategy resolution (`DeepSeekProviderDescriptor.resolveStrategies`): `.web` → `deepseek.web` only; `.api` → `deepseek.api` only; `.auto` → `deepseek.api` (with web enrichment) when an API key exists, otherwise `deepseek.web`.
- Disabling the usage-summary source (`cookieSource == .off`) suppresses **all** session candidates — settings, environment `DEEPSEEK_COOKIE`, cache, and browser import.
- **Manual** usage-summary source uses only the pasted platform session from Settings; it does not fall back to environment variables, cache, or browser import.
- **Auto** usage-summary source may use settings header, `DEEPSEEK_COOKIE`, cache, and browser import.
- Browser cookie/localStorage import runs only on **user-initiated app refresh** (`ProviderInteractionContext.userInitiated`); background refreshes and CLI never trigger browser import.
- When multiple currencies are present, USD is shown preferentially.
- If total balance is zero, CodexBar shows an add-credits message. If balance is nonzero but `is_available` is false, it shows "Balance unavailable for API calls".
- DeepSeek does not expose session/weekly quota windows via API.
- Token-account selection injects the selected key into the fetch environment; otherwise CodexBar reads `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`.

## Key files

- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekProviderDescriptor.swift` (descriptor + fetch strategy + web enrichment)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift` (balance + platform usage HTTP)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageCostParser.swift` (usage amount/cost parsing)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageSummary+Display.swift` (dashboard projections + cost history)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekWebEnrichmentResolver.swift` (cookie candidate chain)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekCookieImporter.swift` (browser cookie import)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/DeepSeek/DeepSeekProviderImplementation.swift` (settings UI + token-account visibility)
- `Sources/CodexBarCore/TokenAccountSupportCatalog+Data.swift` (DeepSeek token-account injection)

---
summary: "DeepSeek provider data sources: API key, balance, and optional detailed usage endpoints."
read_when:
  - Adding or tweaking DeepSeek balance parsing
  - Adding or tweaking DeepSeek detailed usage parsing
  - Updating API key handling
  - Documenting new provider behavior
---

# DeepSeek provider

CodexBar can use either a DeepSeek API key or a signed-in DeepSeek Platform session for the remaining credit balance.
Detailed cost and token usage comes from the Platform session; an API key cannot authenticate the private dashboard
endpoints.

## Data sources

1. **Optional API key** supplied via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`, or selected from DeepSeek token accounts in `~/.codexbar/config.json`.
2. **API-key balance endpoint**
   - `GET https://api.deepseek.com/user/balance`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response contains `is_available`, and a `balance_infos` array with per-currency entries
     (`total_balance`, `granted_balance`, `topped_up_balance`).
3. **Platform-session balance endpoint**
   - `GET https://platform.deepseek.com/api/v0/users/get_user_summary`
   - Request headers: `Authorization: Bearer <platform userToken>`, `Accept: application/json`
   - Used as the balance source when no API key is configured.
4. **Optional detailed usage endpoints**
   - `GET https://platform.deepseek.com/api/v0/usage/amount?month=<month>&year=<year>`
   - `GET https://platform.deepseek.com/api/v0/usage/cost?month=<month>&year=<year>`
   - Request headers: `Authorization: Bearer <platform userToken>`, `Accept: application/json`
   - These are private dashboard endpoints rather than documented public API endpoints and may change without notice.

## Platform session

CodexBar resolves the Platform `userToken` in this order:

1. An explicitly supplied `DEEPSEEK_PLATFORM_TOKEN` / `DEEPSEEK_USER_TOKEN` or a legacy
   `providers[].cookieHeader` value preserved from an existing config.
2. A prompt-free read of `userToken` from the `https://platform.deepseek.com` local-storage origin in Chrome.

The legacy config value remains a compatibility fallback so upgrading cannot silently erase a working browser-only
session. An unscoped legacy or environment token is never combined with an API-key balance; API enrichment requires
a session saved for that credential scope. New automatic imports are never written back to config.

CodexBar checks every Chrome profile containing a parseable `userToken` against DeepSeek. Rejected or expired
sessions are omitted. Settings shows a **Chrome profile** picker containing only valid sessions. With no API key, one
valid session is selected automatically; with multiple valid sessions, CodexBar reuses the saved choice or asks once.
When an API key supplies the balance, a new or changed API credential requires an explicit session selection before
website usage is combined with it. CodexBar persists a stable browser/profile identifier, not an absolute home-directory path, and
keeps automatically imported tokens in memory only. The choice is scoped to a non-reversible fingerprint of the
active API credential and saved-account slot, so replacing a key or switching accounts cannot silently reuse an old
browser session. Validation results are cached briefly so normal
refreshes do not probe every profile, and a temporary network failure does not erase a previously validated profile.
If the selected session expires, CodexBar asks before switching to another valid profile.

If no session is valid, the menu keeps the API-key balance when one exists; otherwise it asks the user to sign in to
DeepSeek Platform in Chrome. Authentication failures returned as top-level or nested DeepSeek codes `40002` and
`40003` are treated as expired sessions.

## Usage details

- The menu card shows total balance with the paid vs. granted breakdown:
  e.g. `$50.00 (Paid: $40.00 / Granted: $10.00)`.
- The API separates granted balance from topped-up balance; CodexBar labels these as granted vs. paid credit.
- With optional extra usage enabled, the menu shows today's and the current month's cost and tokens,
  request counts, cache/input/output categories, the top model, and a current-month token chart.
- The amount and cost requests run concurrently. After balance arrives, CodexBar waits up to five seconds for
  automatic Chrome resolution and detailed usage. The deadline remains bounded even if a local Chrome read does not
  respond to cancellation. If the optional work fails or times out, the balance and previously validated profile list
  remain available while the menu reports that detailed usage is unavailable.
- With multiple configured API keys, browser-derived detailed usage is shown only with the active API-key account;
  other account cards remain balance-only so website usage is never duplicated across accounts.
- When multiple currencies are present, USD is shown preferentially.
- If total balance is zero, CodexBar shows an add-credits message. If balance is nonzero but `is_available` is false, it shows "Balance unavailable for API calls".
- There is no session or weekly window — DeepSeek does not expose per-window quota via API.
- Token-account selection injects the selected key into the fetch environment; otherwise CodexBar reads `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`.

## Key files

- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift` (HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekPlatformTokenImporter.swift` (Chrome Platform session import)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/DeepSeek/DeepSeekProviderImplementation.swift` (provider activation and token-account visibility)
- `Sources/CodexBarCore/TokenAccountSupportCatalog+Data.swift` (DeepSeek token-account injection)

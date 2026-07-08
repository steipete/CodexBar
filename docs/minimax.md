---
summary: "MiniMax provider data sources: Coding Plan tokens, browser cookies, and web-session parsing."
read_when:
  - Debugging MiniMax usage parsing
  - Updating MiniMax cookie handling or coding plan scraping
  - Adjusting MiniMax provider UI/menu behavior
---

# MiniMax provider

MiniMax supports Coding Plan API tokens or web sessions. Web-session mode uses MiniMax browser/session state and
falls back across the provider's supported web requests when needed.

## Data sources

1) **Coding Plan API token**
   - Set in Preferences → Providers → MiniMax (stored in `~/.codexbar/config.json`), `MINIMAX_CODING_API_KEY`,
     or `MINIMAX_API_KEY`.
   - When both environment variables are present, `MINIMAX_CODING_API_KEY` wins so a standard `sk-api-*` key does
     not mask a coding-plan `sk-cp-*` key.
   - Auto mode can fall back to the web/cookie path when API-token credentials are rejected or the global endpoint
     returns 404.

2) **MiniMax Agent desktop session** (automatic web-session path when installed)
   - Reads the logged-in MiniMax Agent / MiniMax Code desktop cookie store from
     `~/Library/Application Support/MiniMax/Cookies`.
   - Does not require Chrome Keychain access; used first on web-session refreshes when present.
   - Also used for API-token optional enrichment when no explicit manual/env cookie is available.

3) **Cached/imported browser session** (automatic web path)
   - Uses CodexBar's standard cookie cache and browser import flow.

4) **Browser cookie import** (automatic)
   - Uses provider metadata for browser order and MiniMax domain filters.
   - Chromium browser storage can supplement imported cookies with access-token context when available.
   - Chrome decryption may require a one-time Keychain approval. Use **⌘R** on the MiniMax menu card to
     trigger a user-initiated refresh when automatic background import is suppressed.

5) **Manual session cookie header** (optional web-path override)
   - Stored in `~/.codexbar/config.json` via Preferences → Providers → MiniMax (Cookie source → Manual).
   - Accepts a raw `Cookie:` header or a full "Copy as cURL" string.
   - Low-level no-settings runtime can read `MINIMAX_COOKIE` or `MINIMAX_COOKIE_HEADER`.

## Requests
- Web sessions use the global host or China mainland host.
- Region picker in Providers settings toggles the host; environment overrides:
  - `MINIMAX_HOST=platform.minimaxi.com`
  - `MINIMAX_CODING_PLAN_URL=...` (full URL override)
  - `MINIMAX_REMAINS_URL=...` (full URL override)
  - `MINIMAX_TOKEN_PLAN_CREDIT_URL=...` (full URL override for recharge-credit balance)
- `MINIMAX_HOST` also selects the matching `www.*` credit and usage-summary hosts for MiniMax-owned domains (`minimaxi.com` → `www.minimaxi.com`, `minimax.io` → `www.minimax.io`). Custom proxy hosts (for example `proxy.example.test:8443`) route coding-plan, remains, billing-history, and usage-summary requests through the override while keeping credit/summary on the configured host path.
- Security policy: endpoint overrides are only accepted when they use `https://`, omit userinfo, and do not contain encoded host delimiters. Custom HTTPS proxy/test domains continue to work for compatibility, but `http://` endpoints are rejected so cookies and authorization headers are not sent in cleartext.
- Strict provider-host mode: set `MINIMAX_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES=true` to additionally reject custom proxy/test domains and only accept MiniMax-owned hosts under `minimax.io` or `minimaxi.com`.

## Cookie capture (optional override)
- Preferred automatic paths:
  - stay logged into **MiniMax Agent / MiniMax Code**, or
  - stay logged into `platform.minimaxi.com` / `www.minimaxi.com` in Chrome, then press **⌘R** once and approve the Keychain prompt if macOS asks for Chrome safe-storage access.
- Manual fallback:
  - Open the Coding Plan page and DevTools → Network.
- Select the request to `/v1/api/openplatform/coding_plan/remains`.
- Copy the `Cookie` request header (or use “Copy as cURL” and paste the whole line).
- Paste into Preferences → Providers → MiniMax only if automatic import fails.

## Snapshot mapping
- Primary usage, reset timing, and plan/tier are derived from Coding Plan response fields or page text.
- Token Plan recharge credits (积分余额) are fetched from `GET https://www.minimaxi.com/backend/account/token_plan_credit` (or the global `www.minimax.io` host) using a web session cookie. API-token remains responses do not include this balance.
- **Web-session refreshes** merge recharge credits and usage-summary enrichment through `MiniMaxWebEnrichmentResolver.candidates`, trying MiniMax Agent cookies first, then cached/browser/manual candidates. Successful browser profiles are cached for later background refreshes once Chrome Keychain access is already authorized.
- **API-token refreshes** attach optional recharge credits and usage-summary enrichment from explicit cookies (manual settings cookie header or `MINIMAX_COOKIE` / `MINIMAX_COOKIE_HEADER`), **MiniMax Agent desktop cookies**, a previously validated browser-session cache, or a user-initiated browser re-import. The API path calls `MiniMaxWebEnrichmentResolver.apiEnrichmentCandidates` and does not attach background browser imports, so a different account's live browser session cannot be merged onto an API-key quota snapshot without user action.
- Console usage summary (`GET .../backend/account/token_plan/usage_summary`) uses the same cookie source split as recharge credits above.
- Pay-as-you-go cost projections treat `input_token` and `cache_read_token` as separate counters when pricing usage-summary model rows.
- Menu **Usage Dashboard** opens `https://platform.minimax.io/console/usage` or `https://platform.minimaxi.com/console/usage` based on the configured API region. Settings **Open Token Plan** still opens the Coding Plan page.
- 5-hour and weekly reset countdowns prefer plausible `remains_time` values but fall back to `end_time` when the API countdown is far outside the declared window.
- Web-session billing history, when available, is mapped into the shared inline usage dashboard:
  - 30-day token trend.
  - Top model and top method breakdowns.
  - Summary rows for recent billing-history totals.

If the billing-history endpoint is unavailable but normal Coding Plan quota data is present, CodexBar still shows the
quota card and omits the chart instead of treating the whole provider as failed.

## Key files
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxDesktopCookieImporter.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxWebEnrichmentResolver.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxTokenPlanCreditFetcher.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageSummary.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsagePricing.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxProviderDescriptor.swift`
- `Sources/CodexBar/Providers/MiniMax/MiniMaxProviderImplementation.swift`

## CLI diagnose command

The generic `diagnose` command performs a real provider diagnostic invocation and emits a safe, redacted JSON export
for issue reporting and verification. MiniMax adds a provider-specific `details` block with safe usage metadata.

### Usage
```
codexbar diagnose --provider minimax --format json --pretty
```

### Output
- Structural diagnostic JSON with provider, source/source mode, auth summary, usage summary, fetch attempts, and error categories.
- Per-service quota percentages, used values, limits, remaining values, reset metadata, and unlimited state. These are
  the same non-secret values shown in the menu and help diagnose boosted quota denominators.
- Recharge-credit balance (`pointsBalance`) when a browser session successfully fetched `token_plan_credit`.
- All sensitive fields (API tokens, cookies, emails, auth headers) are redacted via `LogRedactor`.
- Errors are mapped to safe categories (`network`, `auth`, `api`, `parse`) with user-friendly descriptions.
- No raw API responses, raw error messages, tokens, cookies, emails, account IDs, org IDs, or billing history.

### What is excluded from output
- Raw API tokens (`sk-cp-*`, `sk-api-*`) and authorization headers
- Cookie header values
- Email addresses
- Account IDs, org IDs
- Raw error messages (replaced with safe category-based descriptions)
- Raw HTTP responses or request bodies
- Billing history details

### Exit codes
- `0`: Diagnostic completed successfully (even if provider auth is not configured)
- `1`: Unknown error or invalid arguments

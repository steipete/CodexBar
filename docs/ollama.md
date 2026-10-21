---
summary: "Ollama provider notes: API key auth, settings scrape, cookie auth, and Cloud Usage parsing."
read_when:
  - Adding or modifying the Ollama provider
  - Debugging Ollama cookie import or settings parsing
  - Adjusting Ollama menu labels or usage mapping
---

# Ollama Provider

The Ollama provider reads included usage and purchased credits through an API key or usage-related data from the authenticated settings page. Current Usage settings can expose a **credit balance**, **monthly credits used**, and a **refill target**, but not a quota percentage; CodexBar shows those as details instead of inventing a quota bar. Older settings pages that report monthly included-usage, session/hourly, or weekly meters remain supported.

## Features

- **Current credit page**: Shows the available Usage credits balance, monthly credits used, and next refill target as provider details. These are wallet/spend figures, not a quota percentage.
- **Balance layouts**: The reported credit balance supplies the Balance element and automatic text when no quota meter is available. Monthly spending and refill targets never substitute for a missing balance.
- **Plan badge**: Reads the plan tier (Free/Pro/Max) from the Usage credits, Included usage, or legacy Cloud Usage header.
- **Monthly usage**: Converts the reported included dollar credits (for example, `$7.50 of $60 used`) to utilization
  (`12.5%`). Free plans label the same included-credit meter **Free usage**; both labels map to the primary
  **Monthly** quota bar. This is not a token-cost or spend estimate.
- **Legacy usage**: Retains session/hourly and weekly percentage parsing for older settings pages.
- **Reset timestamps**: Uses the `data-time` attribute on the “Resets in …” elements.
- **API key auth**: Reads `https://ollama.com/api/balance` with `OLLAMA_API_KEY` or a configured key. Included usage is the primary **Monthly** bar; purchased credits appear as **Credit balance** in the same **Credits** section used by browser cookies.
- **Browser cookie auth**: Reads the settings page without an API key, including older session/hourly and weekly meters.

## Setup

1. Open **Settings → Providers**.
2. Enable **Ollama**.
3. For API-key mode, select **API key** as the usage source and paste an API key from `https://ollama.com/settings/keys` or set `OLLAMA_API_KEY`.
4. For browser-cookie mode, leave **Cookie source** on **Auto**, or paste a manual header below.

Ollama API keys currently do not expire, but they can be revoked from the key settings page.

### Manual cookie import (optional)

1. Open `https://ollama.com/settings` in your browser.
2. Copy a `Cookie:` header from the Network tab.
3. Paste it into **Ollama → Cookie source → Manual**.

If Manual is selected with no header or saved cookie account, the settings row says **No cookie header pasted.**
Use **Use automatic cookies** to return to Auto, or paste a header. The action is hidden in API-key mode and while
Keychain access is disabled in Advanced settings. CodexBar does not switch cookie sources automatically.

## How it works

- API-key mode uses the bundled `ollama-api.ts` plugin to send one bearer-authenticated GET to `https://ollama.com/api/balance`. It no longer probes search or fetches the public model catalog during refresh.
- The API's `included.allowance_usd - included.balance_usd` supplies **Monthly credits used** and the primary utilization percentage. `included.period.until` supplies its reset. The monthly classification and calendar pace match the cookie path; the shared window model does not store `period.from` as a separate start date.
- `purchased.balance_usd` supplies **Credit balance**, including Balance layouts. It is never added to the included allowance. Both numeric and decimal-string amounts are supported; absent purchased credits stay absent. Purchased-only accounts get balance details without a quota bar, and a zero allowance does not create a percentage.
- HTTP 401 and 403 invalidate the API key. Malformed balances fail parsing without exposing the response body; missing reset timestamps remain unavailable.
- Cookie mode fetches `https://ollama.com/settings` using browser cookies.
- Credit-wallet fields are matched by complete elements within their wallet section. Details coexist with any reported quota meters; no percentage is inferred when Ollama does not provide a meter. Refill text ends at its own element, even when it has no final period.
- Temporary network failures during API balance fetching retain the prior API snapshot
  and its original timestamp. Localized errors use the same startup retry policy; rejected API keys still invalidate
  prior data.
- Cookie discovery recognizes the current WorkOS AuthKit `wos-session` cookie alongside legacy Ollama and NextAuth
  session names.
- Redirects from settings to `/signin` or the WorkOS AuthKit authorization page are treated as expired sessions, so
  CodexBar can try the next cookie candidate and show sign-in guidance instead of a parser error.
- Parses:
  - Plan badge under **Included usage** or **Cloud Usage**.
  - **Monthly usage** dollar credits, falling back to a valid meter width in the same usage block when necessary.
  - **Free usage** percentage meter, the free-plan label for the same included-credit window.
  - Legacy **Session usage**, **Hourly usage**, and **Weekly usage** percentages.
  - `data-time` ISO timestamps for reset times.
- Monthly pace uses an inferred calendar billing window anchored to the reported reset, not a fixed 30-day session.
  A reset timestamp alone cannot establish the start of a partial migration interval.
- With a monthly-only snapshot, plan history shows only the Monthly tab. Previously saved session and weekly history
  is retained; legacy snapshots continue to use the existing history-tab selection rules.

## Troubleshooting

### “Ollama cookie source is Manual, but no cookie header is configured”

Paste a `Cookie:` header from `https://ollama.com/settings`, or select **Use automatic cookies** in Ollama settings.
Signing in to the website alone does not fill the Manual field. Empty Manual configuration stops before browser
import or a network request; a nonempty header without a recognized session cookie still reports the error below.

### “No Ollama session cookie found”

Sign in at `https://ollama.com/signin` in Chrome, then refresh CodexBar.
If your active session is only in Safari (or another browser), use **Cookie source → Manual** and paste a cookie header.

### “Ollama session cookie expired”

Sign out and back in at `https://ollama.com/signin`, then refresh.

### “Could not parse Ollama usage”

The settings page HTML may have changed. Capture the latest page HTML and update `OllamaUsageParser`.

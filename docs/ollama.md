---
summary: "Ollama provider notes: API key auth, settings scrape, cookie auth, and Cloud Usage parsing."
read_when:
  - Adding or modifying the Ollama provider
  - Debugging Ollama cookie import or settings parsing
  - Adjusting Ollama menu labels or usage mapping
---

# Ollama Provider

The Ollama provider verifies Cloud API-key access and reads usage-related data from the authenticated settings page. Current Usage settings can expose a **credit balance**, **monthly credits used**, and a **refill target**, but not a quota percentage; CodexBar shows those as details instead of inventing a quota bar. Older settings pages that report monthly included-usage, session/hourly, or weekly meters remain supported.

## Features

- **Current credit page**: Shows the available Usage credits balance, monthly credits used, and next refill target as provider details. These are wallet/spend figures, not a quota percentage.
- **Balance layouts**: The reported credit balance supplies the Balance element and automatic text when no quota meter is available. Monthly spending and refill targets never substitute for a missing balance.
- **Plan badge**: Reads the plan tier (Free/Pro/Max) from the Usage credits, Included usage, or legacy Cloud Usage header.
- **Monthly usage**: Converts the reported included dollar credits (for example, `$7.50 of $60 used`) to utilization
  (`12.5%`). Free plans label the same included-credit meter **Free usage**; both labels map to the primary
  **Monthly** quota bar. This is not a token-cost or spend estimate.
- **Legacy usage**: Retains session/hourly and weekly percentage parsing for older settings pages.
- **Reset timestamps**: Uses the `data-time` attribute on the “Resets in …” elements.
- **API key auth**: Verifies direct `https://ollama.com/api` access with `OLLAMA_API_KEY` or a configured key.
- **Browser cookie auth**: Required for Cloud Usage quota windows because Ollama does not expose those limits through
  the documented API.

## Setup

1. Open **Settings → Providers**.
2. Enable **Ollama**.
3. For API-key mode, paste an API key from `https://ollama.com/settings/keys` or set `OLLAMA_API_KEY`.
4. For quota bars, leave **Cookie source** on **Auto** (recommended, imports Chrome cookies by default).

Ollama API keys currently do not expire, but they can be revoked from the key settings page.

### Manual cookie import (optional)

1. Open `https://ollama.com/settings` in your browser.
2. Copy a `Cookie:` header from the Network tab.
3. Paste it into **Ollama → Cookie source → Manual**.

If Manual is selected with no header or saved cookie account, the settings row says **No cookie header pasted.**
Use **Use automatic cookies** to return to Auto, or paste a header. The action is hidden in API-key mode and while
Keychain access is disabled in Advanced settings. CodexBar does not switch cookie sources automatically.

## How it works

- API-key mode first probes the authenticated `https://ollama.com/api/web_search` endpoint without performing a
  search, then fetches `https://ollama.com/api/tags` for the model catalog. The catalog endpoint is public and cannot
  verify a key by itself.
- Cookie mode fetches `https://ollama.com/settings` using browser cookies.
- Credit-wallet fields are matched by complete elements within their wallet section. Details coexist with any reported quota meters; no percentage is inferred when Ollama does not provide a meter. Refill text ends at its own element, even when it has no final period.
- Temporary network failures during API-key validation or catalog fetching retain the prior API identity snapshot
  and its original timestamp. Localized errors use the same startup retry policy; rejected API keys still invalidate
  prior data. API-key mode does not supply Cloud Usage quota windows.
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

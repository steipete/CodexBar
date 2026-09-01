---
summary: "Ollama provider notes: API key auth, settings scrape, cookie auth, and Cloud Usage parsing."
read_when:
  - Adding or modifying the Ollama provider
  - Debugging Ollama cookie import or settings parsing
  - Adjusting Ollama menu labels or usage mapping
---

# Ollama Provider

The Ollama provider can verify Ollama Cloud API-key access and scrape the **Plan & Billing** page to extract monthly
included-credit utilization. Older pages with session/hourly and weekly quota windows remain supported.

## Features

- **Plan badge**: Reads the plan tier (Free/Pro/Max) from the Included usage or legacy Cloud Usage header.
- **Monthly usage**: Converts the reported included dollar credits (for example, `$7.50 of $60 used`) to utilization
  (`12.5%`). The primary quota bar is labeled **Monthly**; this is not a token-cost or spend estimate.
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

## How it works

- API-key mode first probes the authenticated `https://ollama.com/api/web_search` endpoint without performing a
  search, then fetches `https://ollama.com/api/tags` for the model catalog. The catalog endpoint is public and cannot
  verify a key by itself.
- Cookie mode fetches `https://ollama.com/settings` using browser cookies.
- Cookie discovery recognizes the current WorkOS AuthKit `wos-session` cookie alongside legacy Ollama and NextAuth
  session names.
- Redirects from settings to `/signin` or the WorkOS AuthKit authorization page are treated as expired sessions, so
  CodexBar can try the next cookie candidate and show sign-in guidance instead of a parser error.
- Parses:
  - Plan badge under **Included usage** or **Cloud Usage**.
  - **Monthly usage** dollar credits, falling back to a valid meter width in the same usage block when necessary.
  - Legacy **Session usage**, **Hourly usage**, and **Weekly usage** percentages.
  - `data-time` ISO timestamps for reset times.
- Monthly pace uses an inferred calendar billing window anchored to the reported reset, not a fixed 30-day session.
  A reset timestamp alone cannot establish the start of a partial migration interval.
- With a monthly-only snapshot, plan history shows only the Monthly tab. Previously saved session and weekly history
  is retained; legacy snapshots continue to use the existing history-tab selection rules.

## Troubleshooting

### “No Ollama session cookie found”

Sign in at `https://ollama.com/signin` in Chrome, then refresh CodexBar.
If your active session is only in Safari (or another browser), use **Cookie source → Manual** and paste a cookie header.

### “Ollama session cookie expired”

Sign out and back in at `https://ollama.com/signin`, then refresh.

### “Could not parse Ollama usage”

The settings page HTML may have changed. Capture the latest page HTML and update `OllamaUsageParser`.

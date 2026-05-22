---
summary: "Ollama provider notes: API key auth, settings scrape, cookie auth, and Cloud Usage parsing."
read_when:
  - Adding or modifying the Ollama provider
  - Debugging Ollama cookie import or settings parsing
  - Adjusting Ollama menu labels or usage mapping
---

# Ollama Provider

The Ollama provider can verify Ollama Cloud API-key access and scrape the **Plan & Billing** page to extract Cloud
Usage limits for session and weekly windows.

## Features

- **Plan badge**: Reads the plan tier (Free/Pro/Max) from the Cloud Usage header.
- **Session + weekly usage**: Parses the percent-used values shown in the usage bars.
- **Reset timestamps**: Uses the `data-time` attribute on the “Resets in …” elements.
- **API key auth**: Verifies direct `https://ollama.com/api` access with `OLLAMA_API_KEY` or a configured key.
- **Browser cookie auth**: Required for Cloud Usage quota windows because Ollama does not expose those limits through
  the documented API.

## Setup

1. Open **Settings → Providers**.
2. Enable **Ollama**.
3. For API-key mode, paste an API key from `https://ollama.com/settings/keys` or set `OLLAMA_API_KEY`.
4. For quota bars, leave **Cookie source** on **Auto** (recommended, imports Chrome cookies by default).

### Manual cookie import (optional)

1. Open `https://ollama.com/settings` in your browser.
2. Copy a `Cookie:` header from the Network tab.
3. Paste it into **Ollama → Cookie source → Manual**.

## How it works

- API-key mode fetches `https://ollama.com/api/tags` with `Authorization: Bearer <key>` to verify Cloud API access.
- Cookie mode fetches `https://ollama.com/settings` using browser cookies.
- Parses:
  - Plan badge under **Cloud Usage**.
  - **Session usage** and **Weekly usage** percentages.
  - `data-time` ISO timestamps for reset times.

## Troubleshooting

### “No Ollama session cookie found”

Log in to `https://ollama.com/settings` in Chrome, then refresh in CodexBar.
If your active session is only in Safari (or another browser), use **Cookie source → Manual** and paste a cookie header.

### “Ollama session cookie expired”

Sign out and back in at `https://ollama.com/settings`, then refresh.

### “Could not parse Ollama usage”

The settings page HTML may have changed. Capture the latest page HTML and update `OllamaUsageParser`.

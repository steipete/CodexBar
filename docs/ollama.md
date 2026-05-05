---
summary: "Ollama provider notes: settings scrape, cookie auth, and Cloud Usage parsing."
read_when:
  - Adding or modifying the Ollama provider
  - Debugging Ollama cookie import or settings parsing
  - Adjusting Ollama menu labels or usage mapping
---

# Ollama Provider

The Ollama provider scrapes the **Plan & Billing** page to extract Cloud Usage limits for session and weekly windows.

## Features

- **Plan badge**: Reads the plan tier (Free/Pro/Max) from the Cloud Usage header.
- **Session + weekly usage**: Parses the percent-used values shown in the usage bars.
- **Reset timestamps**: Uses the `data-time` attribute on the “Resets in …” elements.
- **Browser cookie auth**: No API keys required.

## Setup

1. Open **Settings → Providers**.
2. Enable **Ollama**.
3. Leave **Cookie source** on **Auto**. CodexBar tries Chrome first, then falls back to Safari and other available browser sessions.

### Manual cookie import (optional)

1. Open `https://ollama.com/settings` in your browser.
2. Copy a `Cookie:` header from the Network tab.
3. Paste it into **Ollama → Cookie source → Manual**.

## How it works

- Fetches `https://ollama.com/settings` using browser cookies.
- Parses:
  - Plan badge under **Cloud Usage**.
  - **Session usage** and **Weekly usage** percentages.
  - `data-time` ISO timestamps for reset times.

## Troubleshooting

### “No Ollama session cookie found”

Log in to `https://ollama.com/settings` in Chrome, then refresh in CodexBar.
If your active session is only in Safari, refresh once more and allow any macOS browser-data prompt.
If automatic import still cannot see the session, use **Cookie source → Manual** and paste a cookie header.

### “Ollama browser cookies are not readable”

Safari cookie files are protected by macOS privacy controls. Open **System Settings → Privacy & Security → Full Disk Access**,
add **CodexBar.app**, then refresh Ollama in CodexBar. If you do not want to grant Full Disk Access, use
**Cookie source → Manual** and paste a cookie header from `https://ollama.com/settings`.

### “Ollama session cookie expired”

Sign out and back in at `https://ollama.com/settings`, then refresh.

### “Could not parse Ollama usage”

The settings page HTML may have changed. Capture the latest page HTML and update `OllamaUsageParser`.

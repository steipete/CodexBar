---
summary: "Manus provider: browser session_id cookie auth for credit balance, monthly credits, and daily refresh tracking."
read_when:
  - Adding or modifying the Manus provider
  - Debugging Manus cookie imports or API responses
  - Adjusting Manus usage display or credit formatting
---

# Manus Provider

The Manus provider tracks credit usage on [manus.im](https://manus.im) via browser `session_id` cookie authentication.

## Features

- **Monthly credit gauge**: Shows Pro monthly credits used vs. plan total (`proMonthlyCredits` − `periodicCredits`).
- **Daily refresh gauge**: Shows daily refresh credits used vs. max refresh allotment, with reset timing.
- **Balance display**: Total credits available, shown in the menu identity line.
- **Cookie auth**: Automatic browser cookie import (Safari, Chrome, Firefox) or manual cookie header.
- **Env var support**: `MANUS_SESSION_TOKEN` (raw token) or `MANUS_COOKIE` (full cookie header) for CLI/headless usage.

## Setup

1. Open **Settings → Providers**
2. Enable **Manus**
3. Log in to [manus.im](https://manus.im) in your browser
4. Cookie import happens automatically on the next refresh

### Manual cookie mode

1. In **Settings → Providers → Manus**, set Cookie source to **Manual**
2. Open your browser DevTools on `manus.im`, copy the `Cookie:` header from any API request (must contain `session_id=...`)
3. Paste the header into the cookie field in CodexBar

### Environment variables (CLI / headless)

- `MANUS_SESSION_TOKEN`: the raw `session_id` value.
- `MANUS_COOKIE`: a full cookie header; the provider extracts `session_id` from it.

Either works; raw-token form is preferred when only one value is needed.

## How it works

A single API endpoint is fetched with a bearer token derived from the `session_id` cookie value:

- `POST https://api.manus.im/user.v1.UserService/GetAvailableCredits` — returns credit fields including `totalCredits`, `freeCredits`, `periodicCredits`, `proMonthlyCredits`, `refreshCredits`, `maxRefreshCredits`, `nextRefreshTime`, and `refreshInterval`.

Cookie domain: `manus.im`. Valid `session_id` cookies are cached in Keychain and reused until the session expires.

The response parser tolerates both a direct object and common envelope shapes (`data` / `result` / `response` / `availableCredits`). Payloads missing all expected credit fields are rejected as a parse error rather than surfacing a misleading zero-credit snapshot.

## Token accounts

Manus supports multiple accounts via the standard token-account mechanism. Add entries to `~/.codexbar/config.json` (`tokenAccounts`) with the full `Cookie:` header (containing `session_id=...`), then switch between accounts from the menu.

## CLI

```bash
codexbar usage --provider manus --verbose
```

## Troubleshooting

### "No Manus session token provided"

Log in to [manus.im](https://manus.im) in a supported browser (Safari, Chrome, Firefox), then refresh CodexBar. Alternatively, set `MANUS_SESSION_TOKEN` or `MANUS_COOKIE`, or paste a cookie header in manual mode.

### "Invalid Manus session token"

Your session has expired or been revoked. Log out and back in to Manus, or paste a fresh `Cookie:` header in manual mode.

### "Response missing expected credits fields"

The API returned a 200 response that doesn't look like a credits payload (often an error object). Re-login to Manus; if it persists, the upstream response schema may have changed.

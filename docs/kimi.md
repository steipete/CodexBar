---
summary: "Kimi provider notes: cookie auth, quotas, and rate-limit parsing."
read_when:
  - Adding or modifying the Kimi provider
  - Debugging Kimi cookie import or usage parsing
  - Adjusting Kimi menu labels or settings
---

# Kimi Provider

Tracks usage for [Kimi For Coding](https://www.kimi.com/code) in CodexBar.

## Features

- Shows current session/rate-limit usage first
- Displays weekly request quota (from membership tier)
- API-key, Kimi Code OAuth credential, automatic cookie, and manual cookie authentication methods
- Automatic refresh countdown

## Setup

Choose one of four authentication methods:

### Method 1: Kimi Code API Key (Recommended)

Create an API key in the [Kimi Code Console](https://www.kimi.com/code/console), then save it in CodexBar:

```bash
codexbar config set-api-key --provider kimi --api-key "kimi-api-key-here"
```

Or provide it through the environment:

```bash
export KIMI_CODE_API_KEY="kimi-code-api-key-here"
```

CodexBar calls `GET https://api.kimi.com/coding/v1/usages` with the API key. Set
`KIMI_CODE_BASE_URL` only when testing a compatible HTTPS proxy or alternate host.

### Method 2: Kimi Code OAuth Credential

If you have signed in with the official Kimi Code CLI, CodexBar can reuse its OAuth credential file:

```text
~/.kimi-code/credentials/kimi-code.json
```

Set `KIMI_CODE_HOME` only when the official CLI uses a non-default home directory:

```bash
export KIMI_CODE_HOME="/path/to/kimi-code-home"
```

CodexBar uses the stored `access_token` for the same `GET https://api.kimi.com/coding/v1/usages`
endpoint. If the access token is expired and the file has a `refresh_token`, CodexBar refreshes the
credential through `https://auth.kimi.com/api/oauth/token` before giving up. For compatible test
OAuth hosts, set `KIMI_CODE_OAUTH_HOST` or `KIMI_OAUTH_HOST` to an HTTPS URL.

### Method 3: Automatic Browser Import

**No setup needed!** If you're already logged in to Kimi in Arc, Chrome, Safari, Edge, Brave, or Chromium:

1. Open CodexBar settings → Providers → Kimi
2. Set "Cookie source" to "Automatic"
3. Enable the Kimi provider toggle
4. CodexBar will automatically find your session

**Note**: Requires Full Disk Access to read browser cookies (System Settings → Privacy & Security → Full Disk Access → CodexBar).

### Method 4: Manual Token Entry

For advanced users or when automatic import fails:

1. Open CodexBar settings → Providers → Kimi
2. Set "Cookie source" to "Manual"
3. Visit `https://www.kimi.com/code/console` in your browser
4. Open Developer Tools (F12 or Cmd+Option+I)
5. Go to **Application** → **Cookies**
6. Copy the `kimi-auth` cookie value (JWT token)
7. Paste it into the "Auth Token" field in CodexBar

### Cookie Environment Variable

Alternatively, set the `KIMI_AUTH_TOKEN` environment variable:

```bash
export KIMI_AUTH_TOKEN="jwt-token-here"
```

## Authentication Priority

When multiple sources are available, CodexBar uses this order:

1. API key (`providers[].apiKey` or `KIMI_CODE_API_KEY`) in Auto mode
2. Kimi Code OAuth credential (`~/.kimi-code/credentials/kimi-code.json`, or `KIMI_CODE_HOME`)
3. Manual cookie/token (from Settings UI) when web fallback is used
4. Cookie environment variable (`KIMI_AUTH_TOKEN`)
5. Browser cookies (Arc → Chrome → Safari → Edge → Brave → Chromium)

**Note**: Browser cookie import requires Full Disk Access permission.

## API Details

## Display Semantics

CodexBar maps Kimi's short-window rate limit to **Session** and shows it before the account-wide
**Weekly** quota. The Kimi API can return more than one `limits[]` window; CodexBar keeps additional
windows as extra session limits instead of flattening everything into the first 5-hour bucket.

Model usage is best-effort when it becomes available. Kimi quotas are account-wide, so activity from
Kimi Code CLI, browser sessions, CodexBar, or pi-provider-kimi-code can share the same quota without a
stable per-tool attribution trail. CodexBar treats Kimi-reported quota and plan context as the source
of truth, and avoids presenting inferred model cost as authoritative.

### Kimi Code API key

**Endpoint**: `GET https://api.kimi.com/coding/v1/usages`

**Authentication**: Bearer token (from `providers[].apiKey`, `KIMI_CODE_API_KEY`, or the Kimi Code OAuth credential file)

**Response**:
```json
{
  "usage": {
    "limit": "2048",
    "used": "214",
    "remaining": "1834",
    "resetTime": "2026-01-09T15:23:13.716839300Z"
  },
  "limits": [{
    "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
    "detail": {
      "limit": "200",
      "used": "139",
      "remaining": "61",
      "resetTime": "2026-01-06T13:33:02.717479433Z"
    }
  }]
}
```

### Kimi web cookie fallback

**Endpoint**: `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`

**Authentication**: Bearer token (from `kimi-auth` cookie)

**Response**:
```json
{
  "usages": [{
    "scope": "FEATURE_CODING",
    "detail": {
      "limit": "2048",
      "used": "214",
      "remaining": "1834",
      "resetTime": "2026-01-09T15:23:13.716839300Z"
    },
    "limits": [{
      "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
      "detail": {
        "limit": "200",
        "used": "139",
        "remaining": "61",
        "resetTime": "2026-01-06T13:33:02.717479433Z"
      }
    }]
  }]
}
```

## Membership Tiers

| Tier | Price | Weekly Quota |
|------|-------|--------------|
| Andante | ¥49/month | 1,024 requests |
| Moderato | ¥99/month | 2,048 requests |
| Allegretto | ¥199/month | 7,168 requests |

All tiers have a rate limit of 200 requests per 5 hours.

## Troubleshooting

### "Kimi auth token is missing"
- Ensure "Cookie source" is set correctly
- If using Automatic mode, verify you're logged in to Kimi in your browser
- Grant Full Disk Access permission if using browser cookies
- Try Manual mode and paste your token directly

### "Kimi auth token is invalid or expired"
- Your token has expired. Paste a new token from your browser
- If using Automatic mode, log in to Kimi again in your browser

### "No Kimi session cookies found"
- You're not logged in to Kimi in any supported browser
- Grant Full Disk Access to CodexBar in System Settings

### "Failed to parse Kimi usage data"
- The API response format may have changed. Please report this issue.

## Implementation

- **Core files**: `Sources/CodexBarCore/Providers/Kimi/`
- **UI files**: `Sources/CodexBar/Providers/Kimi/`
- **Login flow**: `Sources/CodexBar/KimiLoginRunner.swift`
- **Tests**: `Tests/CodexBarTests/KimiProviderTests.swift`

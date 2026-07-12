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

- Displays weekly request quota (from membership tier)
- Shows current 5-hour rate limit usage
- API-key, Kimi Code CLI, automatic cookie, and manual cookie authentication methods
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
`KIMI_CODE_BASE_URL` only when testing a compatible HTTPS proxy or alternate host with an explicit API key.
CodexBar never forwards a Kimi Code CLI credential to an endpoint override.

### Method 2: Kimi Code CLI

If you are signed in with the official Kimi Code CLI, Auto mode can reuse its fresh access token from
`~/.kimi-code/credentials/kimi-code.json`. CodexBar sends the same device identity headers as the CLI,
including the local hostname, OS details, and stable `~/.kimi-code/device_id` value. If that device ID is
missing, CodexBar creates it with private file permissions to match the official client.

CodexBar treats CLI-owned authentication as read-only: it never uses the refresh token and never rewrites
the credential file. When the access token expires, sign in again with Kimi Code CLI or configure an API
key. Set `KIMI_CODE_HOME` only when the official CLI uses a non-default home directory.

Custom `KIMI_CODE_BASE_URL`, `KIMI_CODE_OAUTH_HOST`, and `KIMI_OAUTH_HOST` values disable CLI credential
reuse; use an explicit API key for endpoint-override testing.

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
2. Fresh Kimi Code CLI access token (`~/.kimi-code/credentials/kimi-code.json`)
3. Manual cookie/token (from Settings UI) when web fallback is used
4. Cookie environment variable (`KIMI_AUTH_TOKEN`)
5. Browser cookies (Arc → Chrome → Safari → Edge → Brave → Chromium)

**Note**: Browser cookie import requires Full Disk Access permission.

## API Details

### Kimi Code API key

**Endpoint**: `GET https://api.kimi.com/coding/v1/usages`

**Authentication**: Bearer token (from `providers[].apiKey`, `KIMI_CODE_API_KEY`, or a fresh Kimi Code CLI credential)

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

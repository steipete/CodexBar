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
- Automatic and manual authentication methods
- Automatic refresh countdown

## Setup

Choose one of two authentication methods:

### Method 1: Automatic Browser Import (Recommended)

**No setup needed!** If you're already logged in to Kimi in Arc, Chrome, Safari, Edge, Brave, or Chromium:

1. Open CodexBar settings → Providers → Kimi
2. Set "Cookie source" to "Automatic"
3. Enable the Kimi provider toggle
4. CodexBar will automatically find your session

**Note**: Requires Full Disk Access to read browser cookies (System Settings → Privacy & Security → Full Disk Access → CodexBar).

### Method 2: Manual Token Entry

For advanced users or when automatic import fails:

1. Open CodexBar settings → Providers → Kimi
2. Set "Cookie source" to "Manual"
3. Visit `https://www.kimi.com/code/console` in your browser
4. Open Developer Tools (F12 or Cmd+Option+I)
5. Go to **Application** → **Cookies**
6. Copy the `kimi-auth` cookie value (JWT token)
7. Paste it into the "Auth Token" field in CodexBar

### Method 3: Environment Variable

Alternatively, set the `KIMI_AUTH_TOKEN` environment variable:

```bash
export KIMI_AUTH_TOKEN="jwt-token-here"
```

## Authentication Priority

When multiple sources are available, CodexBar uses this order:

1. Manual token (from Settings UI)
2. Environment variable (`KIMI_AUTH_TOKEN`)
3. Browser cookies (Arc → Chrome → Safari → Edge → Brave → Chromium)

**Note**: Browser cookie import requires Full Disk Access permission.

## API Details

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

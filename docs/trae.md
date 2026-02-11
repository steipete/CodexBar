---
summary: "Trae provider data sources: Web API via JWT authentication, local usage tracking, and authentication details."
read_when:
  - Adding or modifying Trae usage/status parsing
  - Updating Trae web endpoints or JWT authentication
  - Reviewing local usage scanning
---

# Trae provider

Trae is ByteDance's AI-powered IDE (similar to Cursor), built on VS Code with integrated Claude 3.7 Sonnet and GPT-4o support. This provider tracks your fast request quota usage via the web API.

## Data source: Web API (JWT)

The Trae provider uses JWT authentication to fetch your current entitlement/usage data from the Trae API. Unlike other providers, the JWT is not stored in browser cookies or local storage - it exists only in HTTP headers during API requests.

### API Endpoint
- **Primary:** `https://api-sg-central.trae.ai/trae/api/v1/pay/user_current_entitlement_list`
- **Method:** GET
- **Authentication:** JWT token in `Authorization: Cloud-IDE-JWT <token>` header

### JWT Authentication (Manual Entry Required)

**Important:** The JWT token is not stored in browser cookies or localStorage. It only exists in the HTTP Authorization header during API requests. Therefore, **automatic browser import is not available** - you must manually copy the JWT from your browser's DevTools.

**How to obtain the JWT token:**

1. Open https://www.trae.ai in Chrome or Safari and log in to your account
2. Open browser DevTools (Cmd+Option+I on Mac)
3. Go to the **Network** tab
4. Refresh the page or click on the **Usage** menu in Trae
5. Look for a network request to `user_current_entitlement_list` in the list
6. Click on that request
7. In the right panel, find **Headers** → **Request Headers**
8. Locate the `Authorization` header (it starts with `Cloud-IDE-JWT`)
9. Copy the entire header value
10. Open CodexBar → Settings → Providers → Trae
11. Paste the copied value in the "JWT Token" field

**Token Format:**
- Full format: `Cloud-IDE-JWT eyJhbGciOiJSUzI1NiIs...`
- Or just the JWT payload: `eyJhbGciOiJSUzI1NiIs...`
- Both formats are accepted

**Session Duration:**
- The JWT typically expires after 24-48 hours
- When it expires, you'll see "Trae session expired" error
- Simply repeat the steps above to get a fresh JWT

### Response Structure
The API returns a list of user entitlements (`user_entitlement_pack_list`), each containing:

```json
{
  "user_entitlement_pack_list": [
    {
      "entitlement_base_info": {
        "quota": {
          "premium_model_fast_request_limit": 600
        },
        "end_time": 1772277112,
        "product_type": 1
      },
      "status": 1,
      "usage": {
        "premium_model_fast_amount": 91.26527
      }
    }
  ]
}
```

**Key Fields:**
- `premium_model_fast_request_limit`: Total fast request quota (-1 = unlimited)
- `premium_model_fast_amount`: Amount consumed (in credit units)
- `end_time`: Expiration timestamp (Unix seconds)
- `product_type`: 1 = Subscription, 2 = Package/Add-on
- `status`: 1 = Active, 0 = Inactive

### Usage Calculation
- **Primary Window:** Pro Plan entitlement (product_type=1)
- **Secondary Window:** Extra Package entitlements (product_type=2)
- **Tertiary Window:** Additional packages if present
- **Used Percent:** Based on `premium_model_fast_amount / premium_model_fast_request_limit`
- **Reset Time:** Pro plan uses `next_billing_time`, packages use `end_time`
- **Unlimited Plans:** When `premium_model_fast_request_limit` is -1, shows unlimited status

### Settings
- **Authentication:** Manual JWT entry only (no automatic browser import)
- **Dashboard URL:** `https://www.trae.ai/account-setting`
- **Default Enabled:** No (opt-in provider)

## Error Handling

Common error scenarios:
- **401/403:** JWT expired or invalid → Re-copy fresh JWT from browser
- **No JWT Token:** No token entered → Follow steps above to obtain JWT
- **Empty Entitlements:** No active plan → Check your Trae account has an active subscription
- **Network Errors:** Retry with exponential backoff

## Implementation Notes

- Uses JWT-based authentication (not cookie-based sessions)
- **No automatic browser import** - JWT is not stored in accessible browser storage
- Follows the same pattern as Amp and OpenCode providers
- JWT token cached in Keychain for performance (reused until invalid)
- No status page integration (Trae does not provide a public status API)
- No CLI integration (Trae does not expose usage via CLI)

## Key Files

- `Sources/CodexBarCore/Providers/Trae/TraeProviderDescriptor.swift` - Provider metadata
- `Sources/CodexBarCore/Providers/Trae/TraeUsageFetcher.swift` - HTTP client and JWT authentication
- `Sources/CodexBarCore/Providers/Trae/TraeUsageParser.swift` - API response parsing
- `Sources/CodexBarCore/Providers/Trae/TraeUsageSnapshot.swift` - Data model
- `Sources/CodexBar/Providers/Trae/TraeSettingsStore.swift` - Settings extensions
- `Sources/CodexBar/Providers/Trae/TraeProviderImplementation.swift` - UI hooks

## Testing

Tests mirror the pattern in `AmpUsageParserTests.swift`:
- Parse valid entitlement list responses
- Handle multiple entitlements (subscription + packages)
- Calculate usage percentages correctly
- Handle unlimited plans (-1 limit)
- Handle expired/inactive entitlements
- Error cases: 401, network failures, malformed JSON

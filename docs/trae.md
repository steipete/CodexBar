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

The Trae provider uses JWT authentication to fetch your current entitlement/usage data from the Trae API.

### API Endpoint
- **Primary:** `https://api-sg-central.trae.ai/trae/api/v1/pay/user_current_entitlement_list`
- **Method:** GET
- **Authentication:** JWT token in `Authorization: Cloud-IDE-JWT <token>` header

### JWT Authentication
- **Token Source:** Browser cookies (`X-Cloudide-Session` cookie contains the JWT)
- **Token Format:** `Cloud-IDE-JWT eyJhbGciOiJSUzI1NiIs...` or just the JWT payload
- **Browser Support:** Safari, Chrome, Chromium forks, Firefox (in that order by default)
- **Manual Mode:** Supports pasting the JWT token directly (with or without `Cloud-IDE-JWT` prefix)

### Cookie Import (for JWT extraction)
- **Domain:** `trae.ai`, `www.trae.ai`, `.byteoversea.com`
- **Required Cookie:** `X-Cloudide-Session` (contains the JWT authentication token)
- **Automatic Extraction:** The JWT is automatically extracted from the cookie value
- **Manual Mode:** Paste the JWT token directly in the settings

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
- **Authentication Source:** Automatic (browser JWT extraction) or Manual (paste token)
- **Dashboard URL:** `https://www.trae.ai/account-setting`
- **Default Enabled:** No (opt-in provider)

## Error Handling

Common error scenarios:
- **401/403:** JWT expired or invalid → Prompt to re-login at trae.ai
- **No JWT Token:** Browser not logged in → Guide to login first
- **Empty Entitlements:** No active plan → Show appropriate message
- **Network Errors:** Retry with exponential backoff

## Implementation Notes

- Uses JWT-based authentication (not cookie-based sessions)
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

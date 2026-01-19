---
summary: "Augment provider notes: cookie auth, keepalive, and credits parsing."
read_when:
  - Debugging Augment cookie import or keepalive
  - Updating Augment usage or credits parsing
  - Adjusting Augment menu labels or settings
---

# Augment Provider

The Augment provider tracks your Augment Code usage and credits through browser cookie-based authentication.

## Features

- **Credits Tracking**: Monitor your remaining credits and monthly limits
- **Usage Monitoring**: Track credits consumed in the current billing cycle
- **Plan Information**: Display your current subscription plan
- **CLI Integration**: Uses `auggie account status` when the Auggie CLI is installed (falls back to web)
- **Automatic Session Keepalive**: Prevents cookie expiration with proactive refresh
- **Multi-Browser Support**: Chrome, Chrome Beta, Chrome Canary, Arc, Safari

## Setup

### 1. Enable the Provider

1. Open **Settings → Providers**
2. Enable **Augment**
3. The app will automatically import cookies from your browser

### 2. Cookie Source Options

**Automatic (Recommended)**
- Automatically imports cookies from your browser
- Supports Chrome, Chrome Beta, Chrome Canary, Arc, and Safari
- Browser priority: Chrome Beta → Chrome → Chrome Canary → Arc → Safari

**Manual**
- Paste a cookie header from your browser's developer tools
- Useful for troubleshooting or custom browser configurations

**Off**
- Disables Augment provider entirely

### 3. Verify Connection

1. Check the menu bar for the Augment icon
2. Click the icon to see your current usage
3. If you see "Log in to Augment", visit [app.augmentcode.com](https://app.augmentcode.com) and sign in

## How It Works

### Cookie Import

The provider searches for Augment session cookies in this order:

1. **Chrome Beta** (if installed)
2. **Chrome** (if installed)
3. **Chrome Canary** (if installed)
4. **Arc** (if installed)
5. **Safari** (if installed)

Recognized cookie names:
- `_session` (legacy)
- `auth0`, `auth0.is.authenticated`, `a0.spajs.txs` (Auth0)
- `__Secure-next-auth.session-token`, `next-auth.session-token` (NextAuth)
- `__Host-authjs.csrf-token`, `authjs.session-token` (AuthJS)
- `session`, `web_rpc_proxy_session` (Augment-specific)

Cached cookies:
- Keychain cache `com.steipete.codexbar.cache` (account `cookie.augment`, source + timestamp). Reused before re-importing
  from browsers.

### Auggie CLI Integration

If the `auggie` CLI is installed, CodexBar will prefer `auggie account status` for usage data and avoid browser prompts.
When the CLI is unavailable or not authenticated, CodexBar falls back to browser cookies.

### Automatic Session Keepalive

The provider includes an automatic session keepalive system:

- **Check Interval**: Every 5 minutes
- **Refresh Buffer**: Refreshes 5 minutes before cookie expiration
- **Rate Limiting**: Minimum 2 minutes between refresh attempts
- **Session Cookies**: Refreshed every 30 minutes (no expiration date)

This ensures your session stays active without manual intervention.

### API Endpoints

The provider fetches data from:
- **Credits**: `https://app.augmentcode.com/api/credits`
- **Subscription**: `https://app.augmentcode.com/api/subscription`

## Troubleshooting

### "No session cookie found"

**Cause**: You're not logged into Augment in any supported browser.

**Solution**:
1. Open [app.augmentcode.com](https://app.augmentcode.com) in Chrome, Chrome Beta, or Arc
2. Sign in to your Augment account
3. Return to CodexBar and click "Refresh" in the menu

### "Session has expired"

**Cause**: Your browser session expired and automatic refresh failed.

**Solution**:
1. Visit [app.augmentcode.com](https://app.augmentcode.com)
2. Log out and log back in
3. Return to CodexBar - it will automatically import fresh cookies
4. If needed, use the menu action **Refresh Session** to force a re-import

### Cookies not importing from Chrome Beta

**Cause**: Chrome Beta might not be in the browser search order.

**Solution**: This fork includes Chrome Beta support by default. If issues persist:
1. Check that Chrome Beta is installed at `/Applications/Google Chrome Beta.app`
2. Verify you're logged into Augment in Chrome Beta
3. Try switching to regular Chrome temporarily

### Manual Cookie Import

If automatic import fails, you can manually paste cookies:

1. Open Chrome DevTools (⌘⌥I)
2. Go to **Application → Cookies → https://app.augmentcode.com**
3. Copy all cookie values
4. Format as: `cookie1=value1; cookie2=value2; ...`
5. In CodexBar: **Settings → Providers → Augment → Cookie Source → Manual**
6. Paste the cookie header

## Debug Mode

To see detailed cookie import logs:

1. Open **Settings → Debug**
2. Find **Augment** in the provider list
3. Click **Show Debug Info**

This displays:
- Cookie import attempts and results
- API request/response details
- Session keepalive activity
- Error messages with timestamps

## Privacy & Security

- Cookies are stored securely in macOS Keychain
- Only cookies for `*.augmentcode.com` domains are imported
- Cookies are filtered by domain before sending to API endpoints
- No cookies are sent to third-party services
- Session keepalive only runs when Augment is enabled

## Technical Details

### Cookie Domain Filtering

The provider implements RFC 6265 cookie semantics:

- ✅ Exact match: `app.augmentcode.com` → `app.augmentcode.com`
- ✅ Parent domain: `augmentcode.com` → `app.augmentcode.com`
- ✅ Wildcard: `.augmentcode.com` → `app.augmentcode.com`
- ❌ Different subdomain: `auth.augmentcode.com` ❌→ `app.augmentcode.com`

This prevents cookies from other subdomains being sent to the API.

### Session Refresh Mechanism

1. Keepalive checks cookie expiration every 5 minutes
2. If expiration is within 5 minutes, triggers refresh
3. Pings `/api/auth/session` to trigger cookie update
4. Waits 1 second for browser to update cookies
5. Re-imports fresh cookies from browser
6. Logs success/failure for debugging

## Related Documentation

- [Provider Authoring Guide](provider.md) - How to create new providers
- [Development Guide](DEVELOPMENT.md) - Build and test instructions

---
summary: "Factory/Droid support in CodexBar: WorkOS token-based API fetching and UX."
read_when:
  - Debugging Factory usage parsing
  - Adjusting Factory provider UI/menu behavior
  - Troubleshooting token import issues
---

# Factory (Droid) support (CodexBar)

Factory support is implemented: CodexBar can show Factory/Droid usage alongside other providers. Factory uses WorkOS-based authentication with refresh tokens stored in Chrome localStorage.

## UX
- Settings → Providers: toggle for "Show Droid usage".
- No CLI detection required; works if Chrome localStorage contains valid WorkOS tokens.
- Menu: shows standard and premium token usage with billing cycle reset time.

### Factory menu-bar icon
- Uses the same two-bar metaphor as other providers.
- Brand color: orange (#FF6B35).
- Icon style: 8-pointed asterisk pattern.

## Data path (Factory)

### How we fetch usage (WorkOS token-based)

1. **Primary: Stored refresh token**
   - Checks `~/Library/Application Support/CodexBar/factory-session.json` for previously stored token
   - WorkOS refresh tokens are single-use; each exchange returns a new token

2. **Fallback: Chrome localStorage import**
   - Reads Chrome LevelDB files from `~/Library/Application Support/Google/Chrome/Default/Local Storage/leveldb`
   - Searches for `workos:refresh-token` keys associated with `app.factory.ai`
   - Tries tokens in order (newest files first) until one succeeds
   - Files: `.ldb` (compacted) and `.log` (recent writes)

3. **Token exchange**
   - Exchanges refresh token via WorkOS API: `POST https://api.workos.com/user_management/authenticate`
   - Returns access token (for API calls) and new refresh token (stored for next use)
   - Client ID: `client_01HNM792M5G5G1A2THWPXKFMXB`

### API endpoints used
- `GET /api/app/auth/me` — organization, subscription tier, plan info
- `POST /api/organization/subscription/usage` — standard/premium token usage, billing cycle

### What we display
- **Standard tokens**: user token usage vs allowance (primary bar)
- **Premium tokens**: user token usage vs allowance (secondary bar)
- **Account**: email and organization name
- **Plan**: Factory tier (Enterprise, Team, etc.) and plan name

## Token handling details

### Chrome LevelDB parsing
- LevelDB stores localStorage as binary key-value pairs
- Files sorted by modification time (newest first)
- Token format: 20-35 alphanumeric characters after `workos:refresh-token` marker
- Multiple old/expired tokens may exist; tries each until one works

### WorkOS refresh token lifecycle
- Refresh tokens are **single-use**: once exchanged, they become invalid
- Each successful exchange returns a new refresh token
- New token is automatically stored for future use
- If all tokens fail, user must visit app.factory.ai in Chrome to get a fresh token

### Token storage
- Stored in `~/Library/Application Support/CodexBar/factory-session.json`
- JSON format: `{"refreshToken": "..."}`
- Cleared on auth failure; repopulated from Chrome on next fetch

## Notes
- No CLI required: Factory is entirely web-based.
- Chrome required: token import only works with Chrome localStorage (Safari/Firefox not supported).
- WorkOS tokens rotate: each successful API call updates the stored token.
- Provider identity stays siloed: Factory email/plan never leak into other providers.

## Debugging tips
- Check Chrome login: visit `https://app.factory.ai` in Chrome to ensure signed in.
- Token rotation: if fetch fails, visit app.factory.ai in Chrome to generate fresh token.
- Settings → Providers shows the last fetch error inline under the Droid toggle.
- "Add Account" opens app.factory.ai in default browser for manual login.

## Subscription types
| Tier | Display |
|------|---------|
| `enterprise` | Factory Enterprise |
| `team` | Factory Team |
| `pro` | Factory Pro |

## Widgets
Factory is not yet supported in macOS widgets (returns nil in widget provider).

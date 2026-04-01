# Copilot Multi-Account Support — 2026-04-01

## Problem Statement
CodexBar supports multi-account for 8 providers (Claude, Cursor, Zai, etc.) but not GitHub Copilot. Users who are contractors or work across multiple GitHub organizations need to monitor Copilot usage quotas for each account simultaneously. Currently, only one OAuth token can be stored at a time.

## What Makes This Cool
See all your Copilot quotas across client orgs in one glance. Each account is labeled with its GitHub org, so "Client A (Acme Corp)" vs "Personal" is obvious at a glance.

## Premises
1. Each GitHub account maps to one Copilot subscription.
2. Users switch between accounts by doing separate OAuth device flow logins (not org switching within one account).
3. The GitHub `/user` API returns username and `/user/orgs` returns org memberships, using the same OAuth token.
4. The existing cookie-paste multi-account pattern needs a small adapter to support OAuth device flow as the "add account" action.

## Scope

### IN
- Add `.copilot` to `TokenAccountSupportCatalog+Data.swift` with OAuth-based injection
- Extend the "Add Account" flow for Copilot to trigger OAuth Device Flow instead of a paste field
- After successful OAuth, fetch `GET /user` (username) and `GET /user/orgs` (org names) to auto-label the account
- Store each account's OAuth token in `ProviderTokenAccountData` via `FileTokenAccountStore`
- Populate `ProviderIdentitySnapshot.accountOrganization` with the primary org name
- Migrate existing single Keychain token to the new multi-account store on first run
- Per-account usage display in the menu via existing `ProviderTokenAccountSelection` UI

### OUT
- Keychain-based multi-account storage (using JSON file like all other providers)
- Custom account picker UI (reusing existing `ProviderTokenAccountSelection`)
- Token refresh / rotation (GitHub OAuth tokens don't expire unless revoked)
- Org-level Copilot admin API queries (only user-level quota)

## Approaches Considered

### Approach A: Bolt-on to existing token-account system
Add Copilot to `TokenAccountSupportCatalog`. After each OAuth Device Flow login, store the token as a `ProviderTokenAccount` in the JSON file. Fetch `/user` for username + `/user/orgs` for org label. Migrate existing single Keychain token on first run.

- Follows established pattern used by 8 other providers
- Reuses `ProviderTokenAccountSelection` UI and `FileTokenAccountStore`
- OAuth tokens in JSON file (0600 perms) instead of Keychain — acceptable tradeoff given all other providers do the same

### Approach B: Keychain-native multi-account
Extend `KeychainCopilotTokenStore` to support multiple accounts keyed by GitHub username. Build Copilot-specific account picker.

- More secure (Keychain), but diverges from every other multi-account provider
- More code, custom UI, harder to maintain

## Recommended Approach
**Approach A.** Consistent with the established multi-account pattern. Lower effort, reuses existing UI and storage. The security tradeoff (JSON file vs Keychain) is already accepted by 8 other providers.

## Key Implementation Details

### Files to modify
1. **`TokenAccountSupportCatalog+Data.swift`** — Add `.copilot` entry with a new injection type (`.oauthToken` or reuse `.environment`) that passes the token to `CopilotUsageFetcher`
2. **`CopilotUsageFetcher.swift`** — Add a `fetchUserInfo(token:)` method that calls `GET /user` and `GET /user/orgs` to retrieve username + org name for account labeling
3. **`CopilotProviderDescriptor.swift`** — Wire multi-account token override into the fetch strategy
4. **`CopilotProviderImplementation.swift`** — Update `runLoginFlow()` to support "Add Account" (triggers device flow, stores result as new `ProviderTokenAccount` with org label)
5. **`CopilotTokenStore.swift`** — Add migration: on first access, if Keychain has a token but token-accounts has none for Copilot, migrate it over
6. **`CopilotSettingsStore.swift`** — Wire account selection into settings UI

### GitHub API calls (per account add)
- `GET /user` with `Authorization: token {oauth_token}` — returns `login` (username)
- `GET /user/orgs` with same token — returns array of orgs with `login` (org name)
- Label format: `"{username} ({org})"` or just `"{username}"` if no org

### Migration path
- On app launch, check if Keychain has a Copilot token but `token-accounts.json` has no `.copilot` entry
- If so, fetch user info for that token, create a `ProviderTokenAccount`, store it
- Clear the Keychain entry after successful migration
- If Keychain access fails, no-op (user re-authenticates via device flow)

## Open Questions
1. If a user belongs to multiple GitHub orgs, which org name to show? **Proposed:** Use the first org, or let the user pick during account add.
2. Should the old Keychain-only code path be removed entirely after migration, or kept as fallback? **Proposed:** Keep as read-only fallback for one release cycle, then remove.

## Next Steps
1. Add `.copilot` to `TokenAccountSupportCatalog+Data.swift`
2. Add GitHub user/org info fetching to `CopilotUsageFetcher`
3. Wire OAuth device flow as the "add account" action in `CopilotProviderImplementation`
4. Implement Keychain-to-file migration in `CopilotTokenStore`
5. Update fetch strategy to use active account's token from token-account store
6. Test with multiple GitHub accounts

## NOT in Scope
- Org-level admin dashboards — only user-level Copilot quota
- Automatic token refresh — GitHub OAuth tokens are long-lived
- Copilot for Business API management endpoints
- Custom account labeling UI (org name is auto-detected)

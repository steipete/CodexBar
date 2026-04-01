# Review: Copilot Multi-Account Support — 2026-04-01

## Spec Reviewed
`specs/2026-04-01-copilot-multi-account.md`

## Scope Verdict
- **Accepted with minor reduction:** Org context dropped. Account labels use `"username (plan)"` instead of `"username (org)"`. Removes `/user/orgs` API call, avoids OAuth scope concerns (`read:user` doesn't reveal private org memberships), one fewer failure path.
- **Complexity:** 5 files modified, 0 new classes/abstractions. Well under thresholds.
- **No new injection type needed.** The spec mentions `.oauthToken` — use `.environment(key: "COPILOT_API_TOKEN")` instead, matching the Zai pattern.

## Architecture

### Approved patterns
- Token storage via `FileTokenAccountStore` + `ProviderTokenAccountData` (established by 8 providers)
- Token injection via `TokenAccountSupportCatalog.envOverride()` → `env["COPILOT_API_TOKEN"]`
- Fetch override via `TokenAccountOverride` → `ProviderRegistry.makeEnvironment()`
- Account label via `UsageStore.applyAccountLabel()` reading `ProviderTokenAccount.label`
- `CopilotAPIFetchStrategy` reads from `context.env` — **no changes needed to descriptor or fetch strategy**

### Token flow diagram
```
ADD ACCOUNT:
  CopilotLoginFlow.run()
    → CopilotDeviceFlow (OAuth device flow)
    → GET /user → github username
    → settings.addTokenAccount(.copilot, label: "user (plan)", token: oauthToken)
    → FileTokenAccountStore (token-accounts.json, 0600 perms)

FETCH (PER-ACCOUNT):
  UsageStore.refreshTokenAccounts(.copilot, accounts)
    → for each account:
      → TokenAccountOverride(.copilot, account)
      → ProviderRegistry.makeEnvironment(override:)
        1. ProviderConfigEnvironment: env["COPILOT_API_TOKEN"] = config.apiKey  (base)
        2. TokenAccountSupportCatalog.envOverride: env["COPILOT_API_TOKEN"] = account.token  (wins)
      → CopilotAPIFetchStrategy.fetch(context)
        → ProviderTokenResolver.copilotToken(env:)
        → CopilotUsageFetcher(token:).fetch()
```

### Migration: config apiKey → token account
- **Trigger:** `copilotAPIToken` non-empty AND no `.copilot` entries in token accounts
- **Action:** Fetch `GET /user` for username, create `ProviderTokenAccount` with label `"username (plan)"`, clear config `apiKey`
- **Failure:** If `/user` call fails, config token continues working via `ProviderConfigEnvironment`. Migration retries on next app launch.
- **Precedence is safe:** `makeEnvironment()` applies config first, then token account override. Token accounts always win. No data loss during partial migration.

### Failure scenarios
| Scenario | Impact | Handling |
|---|---|---|
| `/user` fails during account add | No username for label | Fall back to "Account N" label |
| `/user` fails during migration | Old config token still works | Migration retries next launch |
| Token revoked between adds | Fetch returns 401 | Existing error display in `resolveAccountOutcome()` |
| `token-accounts.json` write fails | Account not stored | `FileTokenAccountStore` throws; surface error in login flow |

## Code Quality

### Existing code to reuse (with file paths)
| Component | File | Notes |
|---|---|---|
| Token account data model | `Sources/CodexBarCore/TokenAccounts.swift` | No changes needed |
| Account catalog | `Sources/CodexBarCore/TokenAccountSupportCatalog+Data.swift` | Add `.copilot` entry |
| Catalog + env override | `Sources/CodexBarCore/TokenAccountSupport.swift:38-53` | Works as-is for `.environment(key:)` |
| Account selection | `Sources/CodexBar/Providers/Shared/ProviderTokenAccountSelection.swift` | Reuse directly |
| Settings store methods | `Sources/CodexBar/SettingsStore+TokenAccounts.swift` | `addTokenAccount()`, `tokenAccounts()`, etc. |
| Token override in fetch | `Sources/CodexBar/ProviderRegistry.swift:87-122` | Works as-is |
| Multi-account refresh | `Sources/CodexBar/UsageStore+TokenAccounts.swift:31-70` | Works as-is |
| Account label in menu | `Sources/CodexBar/UsageStore+TokenAccounts.swift:216-232` | Works as-is |
| OAuth device flow | `Sources/CodexBarCore/Providers/Copilot/CopilotDeviceFlow.swift` | Reuse directly |
| Login UI | `Sources/CodexBar/Providers/Copilot/CopilotLoginFlow.swift` | Modify to store to token accounts |
| Config env mapping | `Sources/CodexBarCore/Config/ProviderConfigEnvironment.swift:14-15` | Already maps `.copilot` → `COPILOT_API_TOKEN` |
| Token resolver | `Sources/CodexBarCore/Providers/ProviderTokenResolver.swift:86-89` | Already reads `env["COPILOT_API_TOKEN"]` |

### DRY concerns
- After migration, `CopilotLoginFlow.run()` must ONLY write to token accounts — stop calling `settings.copilotAPIToken = token` (line 83 of `CopilotLoginFlow.swift`)
- The `copilotAPIToken` property should remain for config compat and migration reads, but not be written to from new code paths

### Error handling gaps
- None. All new failure paths have graceful degradation (fallback labels, retry migration, existing error display).

### Key implementation notes
1. **Catalog entry:** `requiresManualCookieSource: false`, `cookieName: nil`. Copilot is OAuth, not cookies. Setting this wrong would trigger `applyTokenAccountCookieSource()` hook incorrectly.
2. **No changes to `CopilotProviderDescriptor.swift`** — the fetch strategy already reads from `context.env`, which the override chain populates correctly.
3. **No changes to `CopilotTokenStore.swift`** — Keychain migration to config already handled by `CodexBarConfigMigrator:88`. The new migration is config → token accounts.
4. **Duplicate account handling:** When adding an account, check if a token account with the same GitHub username already exists. If so, update the token rather than creating a duplicate.

## Test Requirements

| Codepath | What to assert | Type | Priority |
|---|---|---|---|
| Catalog entry exists | `TokenAccountSupportCatalog.support(for: .copilot)` returns non-nil with `.environment(key: "COPILOT_API_TOKEN")` and `requiresManualCookieSource == false` | Unit | High |
| GitHub username fetch: happy | Mock 200 `{"login": "testuser"}` → returns `"testuser"` | Unit | High |
| GitHub username fetch: 401 | Mock 401 → throws auth error | Unit | Medium |
| GitHub username fetch: network fail | Mock network error → throws | Unit | Medium |
| Login stores token account | After OAuth, `settings.tokenAccounts(for: .copilot)` contains 1 entry with label `"testuser (Pro)"` and correct token | Unit | High |
| Login username fail fallback | `/user` fails → account created with fallback label | Unit | Medium |
| Duplicate account detection | OAuth same user twice → updates existing, no duplicate | Unit | Medium |
| Settings snapshot with override | `copilotSettingsSnapshot(tokenOverride:)` resolves correct account | Unit | High |
| Migration: token + no accounts | Creates token account from config API key, clears config | Unit | High |
| Migration: already migrated | Config empty, accounts exist → no-op | Unit | Medium |
| Migration: no token | Config empty, no accounts → no-op | Unit | Low |
| Env precedence for Copilot | Token account's `COPILOT_API_TOKEN` overrides config `apiKey` in `makeEnvironment()` | Unit | High |

### Coverage diagram
```
CODE PATH COVERAGE (AFTER IMPLEMENTATION)
═════════════════════════════════════════

[+] TokenAccountSupportCatalog+Data.swift
    └── .copilot entry
        └── [NEED] Catalog lookup returns correct config

[+] CopilotUsageFetcher.swift — fetchGitHubUsername(token:)
    ├── [NEED] 200 → username
    ├── [NEED] 401/403 → auth error
    └── [NEED] Network fail → error

[+] CopilotLoginFlow.swift — run() multi-account path
    ├── [EXISTING ★★★] OAuth device flow
    ├── [NEED] Stores to token accounts with correct label
    ├── [NEED] Username fetch failure → fallback label
    └── [NEED] Duplicate account → update not duplicate

[+] CopilotSettingsStore.swift — snapshot with override
    └── [NEED] Resolves correct account token

[+] Migration (config → token accounts)
    ├── [NEED] Has token, no accounts → migrates
    ├── [NEED] Already migrated → no-op
    └── [NEED] No token → no-op

[+] Environment precedence
    └── [NEED] Token account overrides config apiKey

────────────────────────────
TARGET: 12/12 paths tested
────────────────────────────
```

## Performance
No concerns. `GET /user` happens once per account add (not per refresh). Refresh frequency unchanged. 6-account cap in `limitedTokenAccounts()` prevents excess parallel fetches.

## Critical Gaps
None. All failure modes have either:
- Graceful degradation (fallback labels, retry migration)
- Existing error handling (fetch errors surfaced via `resolveAccountOutcome()`)

## NOT in Scope
- Org context labels — dropped; username + plan name is sufficient
- OAuth scope changes — `read:user` is sufficient for `GET /user`
- Keychain-native multi-account — using file-based store like all other providers
- Token refresh/rotation — GitHub OAuth tokens don't expire unless revoked
- Copilot for Business admin API — user-level quota only
- Custom account labeling UI — auto-detected from GitHub username + plan
- Removing `KeychainCopilotTokenStore` — can be cleaned up in a follow-up; still used by `CodexBarConfigMigrator`

## Unresolved Questions
1. **[RESOLVED]** OAuth scope for org visibility → Dropped org context. Labels use `"username (plan)"`.
2. **[RESOLVED]** Migration strategy → Auto-migrate with retry on failure.
3. **Duplicate account UX:** When a user OAuth's the same GitHub account twice, should we silently update the token, or show a message? **Recommendation:** Silently update the existing token account and show "Token refreshed for {username}" in the success alert.

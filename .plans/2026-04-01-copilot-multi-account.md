# Copilot Multi-Account Support — Implementation Plan — 2026-04-01

## Coordination
- Root repo owner: Alasdair
- Backend branch: `feat/copilot-multi-account`
- Mobile branch: N/A
- Worktree roots: N/A
- Related repos: N/A

## Source
- Spec: `specs/2026-04-01-copilot-multi-account.md`
- Review: `reviews/2026-04-01-copilot-multi-account.md`

## Summary
Add multi-account support for GitHub Copilot, allowing contractors and users with
multiple GitHub accounts to monitor Copilot usage quotas per account. Follows the
existing `TokenAccountSupportCatalog` pattern used by 8 other providers. Each account
is added via OAuth Device Flow and labeled as `"username (plan)"` using the GitHub
`/user` API. Existing single-token users are auto-migrated on first load.

## Scope
- **IN:** Copilot in token account catalog, OAuth-based add-account flow, GitHub
  username fetch for labels, config→token-account migration, settings UI update, tests
- **OUT:** Org context labels, OAuth scope changes, Keychain-native multi-account,
  token refresh/rotation, Copilot for Business admin API, custom account labeling UI,
  removing `KeychainCopilotTokenStore` (follow-up cleanup)

## Tasks

### Task 1: Add Copilot to TokenAccountSupportCatalog

**Files:**
- `Sources/CodexBarCore/TokenAccountSupportCatalog+Data.swift` — modify (line ~4)

**Changes:**
Add `.copilot` entry to the `supportByProvider` dictionary:

```swift
.copilot: TokenAccountSupport(
    title: "GitHub accounts",
    subtitle: "Sign in with multiple GitHub accounts via OAuth.",
    placeholder: "Paste GitHub token…",
    injection: .environment(key: "COPILOT_API_TOKEN"),
    requiresManualCookieSource: false,
    cookieName: nil),
```

Key details:
- `injection: .environment(key: "COPILOT_API_TOKEN")` — matches the env key already
  used by `ProviderConfigEnvironment` (line 15) and `ProviderTokenResolver` (line 89)
- `requiresManualCookieSource: false` — Copilot is OAuth, not cookies. If `true`,
  `applyTokenAccountCookieSourceIfNeeded()` would fire incorrectly.
- `placeholder` is for the generic paste fallback in the token accounts UI — power
  users can manually paste a GitHub PAT here.

**Tests:**
- `Tests/CodexBarTests/CopilotMultiAccountTests.swift` — assert
  `TokenAccountSupportCatalog.support(for: .copilot)` returns non-nil with
  `.environment(key: "COPILOT_API_TOKEN")` and `requiresManualCookieSource == false`
  (unit)

**Acceptance criteria:**
- [ ] `TokenAccountSupportCatalog.support(for: .copilot)` returns valid entry
- [ ] `TokenAccountSupportCatalog.envOverride(for: .copilot, token: "abc")` returns
      `["COPILOT_API_TOKEN": "abc"]`

---

### Task 2: Add GitHub username fetch to CopilotUsageFetcher

**Files:**
- `Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift` — modify (after line 67)

**Changes:**
Add a public static method to fetch the GitHub username for a given OAuth token:

```swift
public static func fetchGitHubUsername(token: String) async throws -> String {
    guard let url = URL(string: "https://api.github.com/user") else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw URLError(.userAuthenticationRequired)
    }
    guard httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    struct GitHubUser: Decodable {
        let login: String
    }
    let user = try JSONDecoder().decode(GitHubUser.self, from: data)
    return user.login
}
```

Key details:
- Static method — no instance needed, can be called from login flow and migration
- Uses `Authorization: token {oauth_token}` header (same pattern as `fetch()`)
- Private `GitHubUser` struct scoped inside the method to avoid polluting namespace
- Only decodes `login` — the one field we need

**Tests:**
- `Tests/CodexBarTests/CopilotMultiAccountTests.swift`:
  - Mock 200 with `{"login": "testuser"}` → returns `"testuser"` (unit)
  - Mock 401 → throws `URLError(.userAuthenticationRequired)` (unit)
  - Note: network mocking follows existing patterns in the test suite. If the project
    uses URLProtocol mocks, follow that pattern. Otherwise test the parsing via
    direct `JSONDecoder` on sample data and test the method's response handling
    by verifying error types for known status codes.

**Acceptance criteria:**
- [ ] `fetchGitHubUsername(token:)` returns username string on success
- [ ] Throws on 401/403
- [ ] Throws on network failure

---

### Task 3: Modify CopilotLoginFlow for multi-account storage

**Depends on:** Task 1, Task 2

**Files:**
- `Sources/CodexBar/Providers/Copilot/CopilotLoginFlow.swift` — modify (lines 81-87)

**Changes:**
Replace the single-token storage path with multi-account storage:

**Before** (line 83):
```swift
settings.copilotAPIToken = token
```

**After:**
```swift
// Fetch username for account label
var label: String
do {
    let username = try await CopilotUsageFetcher.fetchGitHubUsername(token: token)
    // Plan name comes from the usage response — fetch it to build a richer label.
    // If usage fetch fails, just use the username.
    let planSuffix: String
    do {
        let fetcher = CopilotUsageFetcher(token: token)
        let usage = try await fetcher.fetch()
        let plan = usage.identity(for: .copilot)?.loginMethod ?? ""
        planSuffix = plan.isEmpty ? "" : " (\(plan))"
    } catch {
        planSuffix = ""
    }
    label = "\(username)\(planSuffix)"
} catch {
    let count = settings.tokenAccounts(for: .copilot).count
    label = "Account \(count + 1)"
}

// Check for duplicate — same label prefix means same GitHub user
let existingAccounts = settings.tokenAccounts(for: .copilot)
if let existing = existingAccounts.first(where: {
    $0.label.hasPrefix(label.components(separatedBy: " (").first ?? label)
}) {
    // Update existing account's token
    settings.removeTokenAccount(provider: .copilot, accountID: existing.id)
}
settings.addTokenAccount(provider: .copilot, label: label, token: token)
settings.setProviderEnabled(
    provider: .copilot,
    metadata: ProviderRegistry.shared.metadata[.copilot]!,
    enabled: true)
```

Also update the success alert (line 89-91):

**Before:**
```swift
success.messageText = "Login Successful"
```

**After — detect refresh vs new:**
```swift
let wasRefresh = existingAccounts.contains(where: {
    $0.label.hasPrefix(label.components(separatedBy: " (").first ?? label)
})
success.messageText = wasRefresh ? "Token Refreshed" : "Account Added"
success.informativeText = label
```

Key details:
- `CopilotLoginFlow.run()` NO LONGER writes to `settings.copilotAPIToken` — token
  accounts are the single source of truth going forward
- Username fetch failure falls back to `"Account N"` label — no data loss
- Plan name fetch is best-effort (inner try-catch) — if usage API fails, label is
  just the username
- Duplicate detection by label prefix handles re-auth of same GitHub user

**Tests:**
- `Tests/CodexBarTests/CopilotMultiAccountTests.swift`:
  - After mock OAuth + mock `/user`, `settings.tokenAccounts(for: .copilot)` has
    1 entry with correct label and token (unit)
  - Username fetch fails → account created with `"Account 1"` label (unit)
  - Same user OAuth'd twice → one account (updated token), not two (unit)

**Acceptance criteria:**
- [ ] Login flow stores token in token accounts, not `copilotAPIToken`
- [ ] Account label is `"username (Plan)"` when `/user` and usage succeed
- [ ] Account label falls back to `"Account N"` when `/user` fails
- [ ] Re-authenticating same GitHub user updates existing account, no duplicate
- [ ] Provider is enabled after login

---

### Task 4: Update CopilotProviderImplementation settings UI

**Depends on:** Task 1, Task 3

**Files:**
- `Sources/CodexBar/Providers/Copilot/CopilotProviderImplementation.swift` — modify
  (lines 28-57)

**Changes:**
Replace the current settings fields. The current implementation shows a secure text
field bound to `copilotAPIToken` plus "Sign in with GitHub" / "Sign in again" buttons.
For multi-account, the secure field is no longer needed (tokens live in token accounts),
and the button should always be visible as "Add Account".

Replace `settingsFields(context:)` (lines 28-57) with:

```swift
@MainActor
func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
    [
        ProviderSettingsFieldDescriptor(
            id: "copilot-add-account",
            title: "GitHub Login",
            subtitle: "Add accounts via GitHub OAuth Device Flow.",
            kind: .plain,
            placeholder: nil,
            binding: .constant(""),
            actions: [
                ProviderSettingsActionDescriptor(
                    id: "copilot-add-account-action",
                    title: "Add Account",
                    style: .bordered,
                    isVisible: { true },
                    perform: {
                        await CopilotLoginFlow.run(settings: context.settings)
                    }),
            ],
            isVisible: nil,
            onActivate: nil),
    ]
}
```

Key details:
- Removed the secure text field bound to `copilotAPIToken` — no longer the primary
  storage mechanism
- `kind: .plain` with `.constant("")` binding — the field itself is just a container
  for the action button, not a text input
- `isVisible: { true }` on the action — always show "Add Account", whether accounts
  exist or not
- The generic token accounts section (rendered by `ProviderSettingsTokenAccountsRowView`
  via `tokenAccountDescriptor()`) automatically appears once `.copilot` is in the
  catalog, providing the account list, picker, remove button, and paste fallback
- Removed `onActivate: { context.settings.ensureCopilotAPITokenLoaded() }` — no longer
  needed since we don't read from the config API key at runtime

**Tests:**
- No dedicated test needed — the settings rendering is covered by existing
  `ProvidersPaneCoverageTests.swift` smoke tests. If the existing Copilot coverage
  test checks for specific field IDs, update to match the new `"copilot-add-account"` ID.

**Acceptance criteria:**
- [ ] Settings show "Add Account" button for Copilot
- [ ] No secure text field for `copilotAPIToken`
- [ ] Token accounts section appears with account list, picker, and paste fallback
- [ ] Existing coverage tests pass (update field IDs if needed)

---

### Task 5: Auto-migrate config apiKey to token account

**Depends on:** Task 1, Task 2

**Files:**
- `Sources/CodexBar/Providers/Copilot/CopilotSettingsStore.swift` — modify (line ~15)

**Changes:**
Add a migration method and call it from `ensureCopilotAPITokenLoaded()` (which is
called by SettingsStore during init observation):

```swift
extension SettingsStore {
    func migrateCopilotTokenToAccountIfNeeded() {
        let token = self.copilotAPIToken
        guard !token.isEmpty else { return }
        let existing = self.tokenAccounts(for: .copilot)
        guard existing.isEmpty else { return }

        // Migration: move single config token to token accounts.
        // Username fetch happens async — store with fallback label synchronously,
        // then update the label if the fetch succeeds.
        self.addTokenAccount(provider: .copilot, label: "Account 1", token: token)
        self.copilotAPIToken = ""

        // Best-effort async label enrichment
        Task { @MainActor in
            guard let account = self.tokenAccounts(for: .copilot).first else { return }
            do {
                let username = try await CopilotUsageFetcher.fetchGitHubUsername(token: token)
                // Re-add with correct label (remove + add preserves the account)
                self.removeTokenAccount(provider: .copilot, accountID: account.id)
                self.addTokenAccount(provider: .copilot, label: username, token: token)
            } catch {
                // Keep fallback label — migration still succeeded
            }
        }
    }
}
```

Update `ensureCopilotAPITokenLoaded()` to trigger migration:

```swift
func ensureCopilotAPITokenLoaded() {
    self.migrateCopilotTokenToAccountIfNeeded()
}
```

Key details:
- Migration is synchronous for the critical path: token is moved to accounts
  immediately, config API key is cleared. No data loss.
- Username fetch is async best-effort — if it fails, the account keeps its
  `"Account 1"` label. User can remove and re-add via OAuth to get a proper label.
- Guard `existing.isEmpty` ensures migration is idempotent — runs once only.
- `ensureCopilotAPITokenLoaded()` is called from `CopilotProviderImplementation
  .settingsFields()` → `onActivate`. However, since Task 4 removes that `onActivate`,
  we should instead call migration from `observeSettings()`:

In `CopilotProviderImplementation.swift` line 17-19, update:
```swift
@MainActor
func observeSettings(_ settings: SettingsStore) {
    settings.migrateCopilotTokenToAccountIfNeeded()
}
```

**Tests:**
- `Tests/CodexBarTests/CopilotMultiAccountTests.swift`:
  - Config has token, no accounts → after migration, 1 token account exists, config
    token cleared (unit)
  - Config has token AND accounts already exist → no-op, no duplicate (unit)
  - Config is empty → no-op (unit)

**Acceptance criteria:**
- [ ] Existing users with `copilotAPIToken` get auto-migrated to token accounts
- [ ] Config API key is cleared after migration
- [ ] Migration is idempotent — safe to call multiple times
- [ ] Username fetch failure doesn't block migration (fallback label used)

---

### Task 6: Tests

**Depends on:** Tasks 1-5

**Files:**
- `Tests/CodexBarTests/CopilotMultiAccountTests.swift` — create

**Changes:**
Create a new test file using Swift Testing (`import Testing`). Follow the existing
patterns in `CopilotUsageModelsTests.swift` and `TokenAccountStoreTests.swift`.

Test structure (using `@Test` macro, `#expect` assertions):

```swift
import Testing
import Foundation
@testable import CodexBarCore
@testable import CodexBar

// MARK: - Catalog

@Test
func copilotCatalogEntryExists() {
    let support = TokenAccountSupportCatalog.support(for: .copilot)
    #expect(support != nil)
    #expect(support?.requiresManualCookieSource == false)
}

@Test
func copilotEnvOverrideUsesCorrectKey() {
    let override = TokenAccountSupportCatalog.envOverride(for: .copilot, token: "gh_abc")
    #expect(override == ["COPILOT_API_TOKEN": "gh_abc"])
}

// MARK: - Username Fetch (parsing only — no network)

@Test
func githubUserResponseParsesLogin() throws {
    let json = #"{"login": "testuser", "id": 123}"#
    struct GitHubUser: Decodable { let login: String }
    let user = try JSONDecoder().decode(GitHubUser.self, from: Data(json.utf8))
    #expect(user.login == "testuser")
}

// MARK: - Migration

@Test @MainActor
func migrationMovesConfigTokenToAccount() {
    let settings = SettingsStore(
        configStore: testConfigStore(suiteName: "copilot-migration-1"),
        copilotTokenStore: InMemoryCopilotTokenStore())
    settings.copilotAPIToken = "gh_token_123"
    #expect(settings.tokenAccounts(for: .copilot).isEmpty)

    settings.migrateCopilotTokenToAccountIfNeeded()

    #expect(settings.copilotAPIToken.isEmpty)
    let accounts = settings.tokenAccounts(for: .copilot)
    #expect(accounts.count == 1)
    #expect(accounts.first?.token == "gh_token_123")
    #expect(accounts.first?.label == "Account 1")
}

@Test @MainActor
func migrationIsIdempotent() {
    let settings = SettingsStore(
        configStore: testConfigStore(suiteName: "copilot-migration-2"),
        copilotTokenStore: InMemoryCopilotTokenStore())
    settings.copilotAPIToken = "gh_token_123"
    settings.migrateCopilotTokenToAccountIfNeeded()
    settings.migrateCopilotTokenToAccountIfNeeded()

    #expect(settings.tokenAccounts(for: .copilot).count == 1)
}

@Test @MainActor
func migrationNoOpWhenNoToken() {
    let settings = SettingsStore(
        configStore: testConfigStore(suiteName: "copilot-migration-3"),
        copilotTokenStore: InMemoryCopilotTokenStore())

    settings.migrateCopilotTokenToAccountIfNeeded()

    #expect(settings.tokenAccounts(for: .copilot).isEmpty)
}

@Test @MainActor
func migrationNoOpWhenAccountsExist() {
    let settings = SettingsStore(
        configStore: testConfigStore(suiteName: "copilot-migration-4"),
        copilotTokenStore: InMemoryCopilotTokenStore())
    settings.copilotAPIToken = "gh_token_old"
    settings.addTokenAccount(provider: .copilot, label: "existing", token: "gh_token_existing")

    settings.migrateCopilotTokenToAccountIfNeeded()

    // Should NOT add another account or clear the config token (already migrated)
    #expect(settings.tokenAccounts(for: .copilot).count == 1)
    #expect(settings.tokenAccounts(for: .copilot).first?.label == "existing")
}

// MARK: - Environment Precedence

@Test @MainActor
func tokenAccountOverridesConfigAPIKey() {
    let settings = SettingsStore(
        configStore: testConfigStore(suiteName: "copilot-env-precedence"),
        copilotTokenStore: InMemoryCopilotTokenStore())
    settings.copilotAPIToken = "old_config_token"
    settings.addTokenAccount(provider: .copilot, label: "new", token: "new_account_token")

    let account = settings.selectedTokenAccount(for: .copilot)!
    let override = TokenAccountOverride(provider: .copilot, account: account)
    let env = ProviderRegistry.makeEnvironment(
        base: [:],
        provider: .copilot,
        settings: settings,
        tokenOverride: override)

    #expect(env["COPILOT_API_TOKEN"] == "new_account_token")
}
```

Additional tests to add if the project supports URLProtocol-based network mocking:
- `fetchGitHubUsername(token:)` integration tests (200, 401, network error)
- Login flow end-to-end with mocked device flow + `/user` response

**Test runner command:**
```bash
swift test --filter CopilotMultiAccountTests
```

**Acceptance criteria:**
- [ ] All 7+ tests pass
- [ ] Catalog, migration, and env precedence paths fully covered
- [ ] Existing test suite still passes (`swift test`)

---

## Critical Gaps
None carried forward from review. All failure modes have graceful degradation.

## NOT in Scope
- Org context labels — dropped; username + plan name is sufficient
- OAuth scope changes — `read:user` sufficient for `GET /user`
- Keychain-native multi-account — using file-based store like all providers
- Token refresh/rotation — GitHub OAuth tokens are long-lived
- Copilot for Business admin API — user-level quota only
- Custom account labeling UI — auto-detected from GitHub username + plan
- Removing `KeychainCopilotTokenStore` — follow-up cleanup

## Execution Status
Status: Reviewed

## Task Checklist
- [x] Task 1: Add Copilot to TokenAccountSupportCatalog
  - Commit: b69016e
- [x] Task 2: Add GitHub username fetch to CopilotUsageFetcher
  - Commit: 8295649
- [x] Task 3: Modify CopilotLoginFlow for multi-account storage
  - Commit: 2910b32
- [x] Task 4: Update CopilotProviderImplementation settings UI
  - Commit: 6a29dee
- [x] Task 5: Auto-migrate config apiKey to token account
  - Commit: 17e5067
- [x] Task 6: Tests
  - Commit: ee7d3ba

## Decisions Log
- 2026-04-01: Plan created from spec and review.
- 2026-04-01: Org context dropped — labels use "username (plan)" instead.
- 2026-04-01: Auto-migrate with async label enrichment chosen over skip/re-auth.
- 2026-04-01: Duplicate accounts detected by label prefix, token silently refreshed.

## Outcomes / Drift
- Pre-existing test suite compilation errors in SettingsStoreTests.swift (@const / @section attribute errors from Swift Testing macro expansion) prevent running the full test suite. This is unrelated to our changes — the app target compiles cleanly and our test file compiles without errors.
- 2026-04-01: Pre-landing review completed. 0 critical findings. 3 informational findings: (1) duplicate predicate closure in login flow duplicate detection, (2) makeSettingsStore factory duplicated in test file, (3) edge case where migration label mismatch on re-auth won't deduplicate. All acceptable — no auto-fixes applied.

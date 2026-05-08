import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// MARK: - Catalog

@Test
func `copilot catalog entry exists`() {
    let support = TokenAccountSupportCatalog.support(for: .copilot)
    #expect(support != nil)
    #expect(support?.requiresManualCookieSource == false)
    #expect(support?.cookieName == nil)
}

@Test
func `copilot catalog entry uses environment injection`() {
    let support = TokenAccountSupportCatalog.support(for: .copilot)
    guard let support else {
        Issue.record("Copilot catalog entry missing")
        return
    }
    if case let .environment(key) = support.injection {
        #expect(key == "COPILOT_API_TOKEN")
    } else {
        Issue.record("Expected .environment injection, got cookieHeader")
    }
}

@Test
func `copilot env override uses correct key`() {
    let override = TokenAccountSupportCatalog.envOverride(for: .copilot, token: "gh_abc")
    #expect(override == ["COPILOT_API_TOKEN": "gh_abc"])
}

// MARK: - Username Fetch (parsing only)

@Test
func `GitHub user response parses stable id and login`() throws {
    let json = #"{"login": "testuser", "id": 123, "name": "Test User"}"#
    let user = try JSONDecoder().decode(CopilotUsageFetcher.GitHubUserIdentity.self, from: Data(json.utf8))
    #expect(user.id == 123)
    #expect(user.login == "testuser")
}

@Test
func `GitHub user response requires stable id`() throws {
    let json = #"{"login": "minimaluser"}"#
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CopilotUsageFetcher.GitHubUserIdentity.self, from: Data(json.utf8))
    }
}

// MARK: - API Key Fallback

@MainActor
struct CopilotAPIKeyFallbackTests {
    @Test
    func `ensure loader preserves config token`() {
        let settings = Self.makeSettingsStore(suite: "copilot-api-key-loader")
        settings.copilotAPIToken = "gh_token_123"

        settings.ensureCopilotAPITokenLoaded()

        #expect(settings.copilotAPIToken == "gh_token_123")
        #expect(settings.tokenAccounts(for: .copilot).isEmpty)
    }

    @Test
    func `token accounts clear legacy config token`() {
        let settings = Self.makeSettingsStore(suite: "copilot-api-key-with-accounts")
        settings.copilotAPIToken = "gh_token_old"
        settings.addTokenAccount(provider: .copilot, label: "existing", token: "gh_token_existing")

        settings.ensureCopilotAPITokenLoaded()

        #expect(settings.tokenAccounts(for: .copilot).count == 1)
        #expect(settings.copilotAPIToken.isEmpty)
        #expect(settings.copilotSettingsSnapshot(tokenOverride: nil).apiToken == "gh_token_existing")
        #expect(settings.tokenAccounts(for: .copilot).first?.label == "existing")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        SettingsStore(
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}

// MARK: - Environment Precedence

@MainActor
struct CopilotEnvironmentPrecedenceTests {
    @Test
    func `token account overrides config API key`() throws {
        let settings = Self.makeSettingsStore(suite: "copilot-env-override")
        settings.copilotAPIToken = "old_config_token"
        settings.addTokenAccount(provider: .copilot, label: "new", token: "new_account_token")

        let account = try #require(settings.selectedTokenAccount(for: .copilot))
        let override = TokenAccountOverride(provider: .copilot, account: account)
        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .copilot,
            settings: settings,
            tokenOverride: override)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: override)

        #expect(env["COPILOT_API_TOKEN"] == "new_account_token")
        #expect(snapshot.copilot?.apiToken == "new_account_token")
    }

    @Test
    func `selected token account is included in copilot settings snapshot`() {
        let settings = Self.makeSettingsStore(suite: "copilot-settings-snapshot-account")
        settings.copilotAPIToken = "old_config_token"
        settings.addTokenAccount(provider: .copilot, label: "new", token: "new_account_token")

        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)

        #expect(snapshot.copilot?.apiToken == "new_account_token")
    }

    @Test
    func `config API key used when no token accounts`() {
        let settings = Self.makeSettingsStore(suite: "copilot-env-config-only")
        settings.copilotAPIToken = "config_token"

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .copilot,
            settings: settings,
            tokenOverride: nil)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)

        #expect(env["COPILOT_API_TOKEN"] == "config_token")
        #expect(snapshot.copilot?.apiToken == "config_token")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        SettingsStore(
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}

// MARK: - External Identifier Dedup

@MainActor
struct CopilotExternalIdentifierTests {
    @Test
    func `addTokenAccount persists external identifier`() throws {
        let settings = Self.makeSettingsStore(suite: "copilot-ext-id-add")
        settings.addTokenAccount(
            provider: .copilot,
            label: "octocat (Pro)",
            token: "gh_token_1",
            externalIdentifier: "octocat")

        let account = try #require(settings.tokenAccounts(for: .copilot).first)
        #expect(account.externalIdentifier == "octocat")
    }

    @Test
    func `updateTokenAccount preserves identifier when not provided`() throws {
        let settings = Self.makeSettingsStore(suite: "copilot-ext-id-preserve")
        settings.addTokenAccount(
            provider: .copilot,
            label: "octocat (Pro)",
            token: "gh_token_1",
            externalIdentifier: "octocat")
        let original = try #require(settings.tokenAccounts(for: .copilot).first)

        settings.updateTokenAccount(
            provider: .copilot,
            accountID: original.id,
            label: "octocat (Business)",
            token: "gh_token_2")

        let updated = try #require(settings.tokenAccounts(for: .copilot).first)
        #expect(updated.id == original.id)
        #expect(updated.token == "gh_token_2")
        #expect(updated.externalIdentifier == "octocat")
    }

    @Test
    func `updateTokenAccount writes identifier back for legacy accounts`() throws {
        let settings = Self.makeSettingsStore(suite: "copilot-ext-id-backfill")
        // Legacy account: no externalIdentifier (pre-feature).
        settings.addTokenAccount(provider: .copilot, label: "octocat (Pro)", token: "gh_legacy")
        let legacy = try #require(settings.tokenAccounts(for: .copilot).first)
        #expect(legacy.externalIdentifier == nil)

        settings.updateTokenAccount(
            provider: .copilot,
            accountID: legacy.id,
            label: "octocat (Pro)",
            token: "gh_refreshed",
            externalIdentifier: .some("octocat"))

        let updated = try #require(settings.tokenAccounts(for: .copilot).first)
        #expect(updated.id == legacy.id)
        #expect(updated.externalIdentifier == "octocat")
    }

    @Test
    func `legacy Account N account matches reauth by stored token identity`() async {
        let legacy = Self.makeAccount(label: "Account 1", token: "old-token", externalIdentifier: nil)
        let matched = await CopilotLoginFlow.matchExistingAccount(
            existingAccounts: [legacy],
            identity: Self.identity(id: 123, login: "octocat"),
            label: "octocat (Pro)",
            legacyIdentityResolver: { account in
                account.token == "old-token" ? Self.identity(id: 123, login: "octocat") : nil
            })

        #expect(matched?.id == legacy.id)
    }

    @Test
    func `user renamed legacy account matches reauth by stored token identity`() async {
        let legacy = Self.makeAccount(label: "Work GitHub", token: "old-token", externalIdentifier: nil)
        let matched = await CopilotLoginFlow.matchExistingAccount(
            existingAccounts: [legacy],
            identity: Self.identity(id: 123, login: "octocat"),
            label: "octocat (Pro)",
            legacyIdentityResolver: { account in
                account.token == "old-token" ? Self.identity(id: 123, login: "OctoCat") : nil
            })

        #expect(matched?.id == legacy.id)
    }

    @Test
    func `stable external identifier match is preferred`() async {
        let identified = Self.makeAccount(
            label: "Personal",
            token: "identified",
            externalIdentifier: "github:user:123")
        let legacy = Self.makeAccount(label: "octocat", token: "legacy", externalIdentifier: nil)
        let matched = await CopilotLoginFlow.matchExistingAccount(
            existingAccounts: [legacy, identified],
            identity: Self.identity(id: 123, login: "octocat"),
            label: "octocat (Pro)",
            legacyIdentityResolver: { _ in
                Issue.record("Resolver should not run when externalIdentifier matches")
                return nil
            })

        #expect(matched?.id == identified.id)
    }

    @Test
    func `legacy login external identifier still matches and can be backfilled`() async {
        let identified = Self.makeAccount(label: "Personal", token: "identified", externalIdentifier: "OctoCat")
        let matched = await CopilotLoginFlow.matchExistingAccount(
            existingAccounts: [identified],
            identity: Self.identity(id: 123, login: "octocat"),
            label: "octocat (Pro)",
            legacyIdentityResolver: { _ in
                Issue.record("Resolver should not run when legacy externalIdentifier matches")
                return nil
            })

        #expect(matched?.id == identified.id)
        #expect(CopilotLoginFlow.externalIdentifier(for: Self.identity(id: 123, login: "octocat")) == "github:user:123")
    }

    @Test
    func `decoding legacy token account JSON yields nil identifier`() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "label": "octocat",
          "token": "gh_legacy",
          "addedAt": 1700000000.0
        }
        """
        let account = try JSONDecoder().decode(ProviderTokenAccount.self, from: Data(json.utf8))
        #expect(account.label == "octocat")
        #expect(account.externalIdentifier == nil)
        #expect(account.lastUsed == nil)
    }

    private nonisolated static func identity(id: Int64, login: String) -> CopilotUsageFetcher.GitHubUserIdentity {
        CopilotUsageFetcher.GitHubUserIdentity(id: id, login: login)
    }

    private static func makeAccount(
        label: String,
        token: String,
        externalIdentifier: String?) -> ProviderTokenAccount
    {
        ProviderTokenAccount(
            id: UUID(),
            label: label,
            token: token,
            addedAt: 1_700_000_000,
            lastUsed: nil,
            externalIdentifier: externalIdentifier)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        SettingsStore(
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}

// MARK: - Token Account Snapshot Error Messages

@MainActor
struct TokenAccountSnapshotErrorMessageTests {
    @Test
    func `cancellation is suppressed for global error path`() {
        let store = Self.makeUsageStore()
        #expect(store.tokenAccountErrorMessage(CancellationError()) == nil)
        #expect(store.tokenAccountErrorMessage(URLError(.cancelled)) == nil)
    }

    @Test
    func `cancellation-like localized errors are suppressed`() {
        let store = Self.makeUsageStore()
        struct Cancelled: LocalizedError {
            var errorDescription: String? {
                "cancelled"
            }
        }
        #expect(store.tokenAccountErrorMessage(Cancelled()) == nil)
    }

    @Test
    func `non-cancellation error preserves localized message`() {
        let store = Self.makeUsageStore()
        struct Boom: LocalizedError {
            var errorDescription: String? {
                "kaboom"
            }
        }
        #expect(store.tokenAccountSnapshotErrorMessage(Boom()) == "kaboom")
        #expect(store.tokenAccountErrorMessage(Boom()) == "kaboom")
    }

    private static func makeUsageStore() -> UsageStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "copilot-snapshot-error-\(UUID().uuidString)"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}

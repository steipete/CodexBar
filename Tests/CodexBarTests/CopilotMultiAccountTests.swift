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
func `GitHub user response parses login`() throws {
    let json = #"{"login": "testuser", "id": 123, "name": "Test User"}"#
    struct GitHubUser: Decodable { let login: String }
    let user = try JSONDecoder().decode(GitHubUser.self, from: Data(json.utf8))
    #expect(user.login == "testuser")
}

@Test
func `GitHub user response parses login with minimal fields`() throws {
    let json = #"{"login": "minimaluser"}"#
    struct GitHubUser: Decodable { let login: String }
    let user = try JSONDecoder().decode(GitHubUser.self, from: Data(json.utf8))
    #expect(user.login == "minimaluser")
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
    func `config token remains when token accounts already exist`() {
        let settings = Self.makeSettingsStore(suite: "copilot-api-key-with-accounts")
        settings.copilotAPIToken = "gh_token_old"
        settings.addTokenAccount(provider: .copilot, label: "existing", token: "gh_token_existing")

        settings.ensureCopilotAPITokenLoaded()

        #expect(settings.tokenAccounts(for: .copilot).count == 1)
        #expect(settings.copilotAPIToken == "gh_token_old")
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

        #expect(env["COPILOT_API_TOKEN"] == "new_account_token")
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

        #expect(env["COPILOT_API_TOKEN"] == "config_token")
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

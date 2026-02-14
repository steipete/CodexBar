import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
@Suite
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func tokenAccountEnvironmentOverridesConfigAPIKey_inAppEnvironmentBuilder() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-app")
        settings.zaiAPIToken = "config-token"
        settings.addTokenAccount(provider: .zai, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .zai,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func tokenAccountEnvironmentOverridesConfigAPIKey_inCLIEnvironmentBuilder() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(id: .zai, apiKey: "config-token"),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Account 1",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)

        let env = tokenContext.environment(base: [:], provider: .zai, account: account)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
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

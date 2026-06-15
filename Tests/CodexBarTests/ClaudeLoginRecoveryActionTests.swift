import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeLoginRecoveryActionTests {
    @Test
    func `fully unconfigured Claude surfaces a recovery action instead of only the generic error`() {
        let store = Self.makeStore(suite: "ClaudeLoginRecoveryActionTests-no-strategy")
        store._setErrorForTesting(
            ProviderFetchError.noAvailableStrategy(.claude).localizedDescription,
            provider: .claude)

        let context = ProviderMenuLoginContext(
            provider: .claude,
            store: store,
            settings: store.settings,
            account: store.accountInfo(for: .claude))

        let action = ClaudeProviderImplementation().loginMenuAction(context: context)
        #expect(action?.label == "Re-login at claude.ai")
        #expect(action?.action == .loginToProvider(url: "https://claude.ai/"))
    }

    @Test
    func `no Claude error does not force a recovery action`() {
        let store = Self.makeStore(suite: "ClaudeLoginRecoveryActionTests-no-error")

        let context = ProviderMenuLoginContext(
            provider: .claude,
            store: store,
            settings: store.settings,
            account: store.accountInfo(for: .claude))

        #expect(ClaudeProviderImplementation().loginMenuAction(context: context) == nil)
    }

    @Test
    func `no-strategy detection only matches the generic Claude empty-plan error`() {
        #expect(ClaudeProviderImplementation.isNoAvailableStrategyError(
            ProviderFetchError.noAvailableStrategy(.claude).localizedDescription))
        #expect(!ClaudeProviderImplementation.isNoAvailableStrategyError("Some other error"))
        #expect(!ClaudeProviderImplementation.isNoAvailableStrategyError(nil))
    }

    private static func makeStore(suite: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
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

        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct FactoryProviderImplementationTests {
    @Test
    func `extra usage balance respects optional usage setting`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 0)),
            updatedAt: Date(timeIntervalSince1970: 0))

        var hiddenEntries: [ProviderMenuEntry] = []
        let hiddenContext = try Self.context(snapshot: snapshot, showOptionalUsage: false)
        FactoryProviderImplementation().appendUsageMenuEntries(
            context: hiddenContext,
            entries: &hiddenEntries)
        #expect(hiddenEntries.isEmpty)

        var visibleEntries: [ProviderMenuEntry] = []
        let visibleContext = try Self.context(snapshot: snapshot, showOptionalUsage: true)
        FactoryProviderImplementation().appendUsageMenuEntries(
            context: visibleContext,
            entries: &visibleEntries)

        guard case let .text(title, style) = try #require(visibleEntries.first) else {
            Issue.record("Expected Factory extra usage balance menu text")
            return
        }
        #expect(title == "Extra usage balance: $25.00")
        #expect(style == .primary)
    }

    private static func context(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool) throws -> ProviderMenuUsageContext
    {
        let suite = "FactoryProviderImplementationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
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
        settings.showOptionalCreditsAndExtraUsage = showOptionalUsage
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        return ProviderMenuUsageContext(
            provider: .factory,
            store: store,
            settings: settings,
            metadata: FactoryProviderDescriptor.descriptor.metadata,
            snapshot: snapshot)
    }
}

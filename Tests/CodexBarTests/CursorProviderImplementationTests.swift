import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CursorProviderImplementationTests {
    @Test
    func `on demand usage respects optional usage setting`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 12,
                limit: 60,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date(timeIntervalSince1970: 0)),
            updatedAt: Date(timeIntervalSince1970: 0))

        var hiddenEntries: [ProviderMenuEntry] = []
        let hiddenContext = try Self.context(snapshot: snapshot, showOptionalUsage: false)
        CursorProviderImplementation().appendUsageMenuEntries(
            context: hiddenContext,
            entries: &hiddenEntries)
        #expect(hiddenEntries.isEmpty)

        var visibleEntries: [ProviderMenuEntry] = []
        let visibleContext = try Self.context(snapshot: snapshot, showOptionalUsage: true)
        CursorProviderImplementation().appendUsageMenuEntries(
            context: visibleContext,
            entries: &visibleEntries)

        guard case let .text(title, style) = try #require(visibleEntries.first) else {
            Issue.record("Expected Cursor on-demand usage menu text")
            return
        }
        #expect(title == "On-demand: $12.00 / $60.00")
        #expect(style == .primary)
    }

    private static func context(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool) throws -> ProviderMenuUsageContext
    {
        let suite = "CursorProviderImplementationTests-\(UUID().uuidString)"
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
            provider: .cursor,
            store: store,
            settings: settings,
            metadata: CursorProviderDescriptor.descriptor.metadata,
            snapshot: snapshot)
    }
}

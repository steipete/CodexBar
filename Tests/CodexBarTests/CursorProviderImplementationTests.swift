import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CursorProviderImplementationTests {
    @Test
    func `menu descriptor shows on demand usage only when optional usage is enabled`() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 12,
                limit: 60,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date(timeIntervalSince1970: 0)),
            updatedAt: Date(timeIntervalSince1970: 0))

        let hiddenLines = try Self.menuLines(snapshot: snapshot, showOptionalUsage: false)
        #expect(!hiddenLines.contains("On-demand: $12.00 / $60.00"))
        #expect(hiddenLines.contains(where: { $0.hasPrefix("Total:") }))

        let visibleLines = try Self.menuLines(snapshot: snapshot, showOptionalUsage: true)
        #expect(visibleLines.contains("On-demand: $12.00 / $60.00"))
        #expect(visibleLines.contains(where: { $0.hasPrefix("Total:") }))
    }

    private static func menuLines(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool) throws -> [String]
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
        store._setSnapshotForTesting(snapshot, provider: .cursor)

        let descriptor = MenuDescriptor.build(
            provider: .cursor,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        return descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
    }
}

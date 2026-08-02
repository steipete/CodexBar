import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeProviderImplementationTests {
    @Test
    func `prepaid balance respects optional usage setting`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        var hiddenEntries: [ProviderMenuEntry] = []
        try ClaudeProviderImplementation().appendUsageMenuEntries(
            context: Self.context(snapshot: snapshot, showOptionalUsage: false),
            entries: &hiddenEntries)
        #expect(hiddenEntries.isEmpty)

        var visibleEntries: [ProviderMenuEntry] = []
        try ClaudeProviderImplementation().appendUsageMenuEntries(
            context: Self.context(snapshot: snapshot, showOptionalUsage: true),
            entries: &visibleEntries)

        guard case let .text(extraUsageTitle, extraUsageStyle) = try #require(visibleEntries.first),
              case let .text(balanceTitle, balanceStyle) = try #require(visibleEntries.last)
        else {
            Issue.record("Expected Claude extra usage and prepaid balance menu text")
            return
        }
        #expect(extraUsageTitle == "Extra usage: $5.00 / $20.00")
        #expect(extraUsageStyle == .primary)
        #expect(balanceTitle == "Balance: $100.00")
        #expect(balanceStyle == .primary)
        #expect(visibleEntries.count == 2)
    }

    @Test
    func `prepaid balance without monthly cap stays a compact credits entry`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Usage credits",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        var entries: [ProviderMenuEntry] = []
        try ClaudeProviderImplementation().appendUsageMenuEntries(
            context: Self.context(snapshot: snapshot, showOptionalUsage: true),
            entries: &entries)

        guard case let .text(title, style) = try #require(entries.first) else {
            Issue.record("Expected Claude prepaid balance menu text")
            return
        }
        #expect(title == "Credits: $100.00")
        #expect(style == .primary)
        #expect(entries.count == 1)
    }

    private static func context(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool) throws -> ProviderMenuUsageContext
    {
        let suite = "ClaudeProviderImplementationTests-\(UUID().uuidString)"
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
            provider: .claude,
            store: store,
            settings: settings,
            metadata: ClaudeProviderDescriptor.descriptor.metadata,
            snapshot: snapshot)
    }
}

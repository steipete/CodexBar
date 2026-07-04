import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorSakanaTests {
    @Test
    func `sakana pay as you go rows render when optional usage is enabled`() throws {
        let lines = try Self.menuLines(showOptionalUsage: true)

        #expect(lines.contains("Balance: $12.34"))
        #expect(lines.contains("Recent usage: $5.67"))
    }

    @Test
    func `sakana pay as you go rows are hidden when optional usage is disabled`() throws {
        // Regression for the render-path staleness gap: toggling "Show optional credits and extra
        // usage" off only rebuilds the menu, it does not immediately refetch, so a
        // previously-populated sakanaPayAsYouGo lingers in the cached snapshot. The rows must be
        // gated on the setting, not only on the presence of the (possibly stale) snapshot field.
        let lines = try Self.menuLines(showOptionalUsage: false)

        #expect(!lines.contains(where: { $0.hasPrefix("Balance:") }))
        #expect(!lines.contains(where: { $0.hasPrefix("Recent usage:") }))
        // The required quota windows must still render regardless of the optional-usage setting.
        #expect(lines.contains(where: { $0.hasPrefix("5-hour") }))
        #expect(lines.contains(where: { $0.hasPrefix("Weekly") }))
    }

    private static func menuLines(showOptionalUsage: Bool) throws -> [String] {
        let suite = "MenuDescriptorSakanaTests-\(showOptionalUsage)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = showOptionalUsage

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = SakanaUsageSnapshot(
            planName: "Standard",
            priceLabel: "$20/mo",
            fiveHour: .init(usedPercent: 10, resetsAt: nil),
            weekly: .init(usedPercent: 20, resetsAt: nil),
            payAsYouGo: SakanaPayAsYouGoSnapshot(
                creditBalance: 12.34,
                periodUsageTotal: 5.67,
                periodLabel: "Jun 02, 2026 - Jul 01, 2026"))
        store._setSnapshotForTesting(snapshot.toUsageSnapshot(), provider: .sakana)

        let descriptor = MenuDescriptor.build(
            provider: .sakana,
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

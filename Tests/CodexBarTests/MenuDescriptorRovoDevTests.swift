import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct RovoDevMenuPresentationTests {
    @Test
    func `Rovo Dev model renders credit summary as detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.rovodev])
        let snapshot = Self.snapshot(now: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .rovodev,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText == nil)
        #expect(primary.detailText == "847 / 2000 credits")
    }

    @Test
    func `Rovo Dev credits detail does not render as reset line`() throws {
        let suite = "RovoDevMenuPresentationTests-detail"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(Self.snapshot(now: Date()), provider: .rovodev)

        let descriptor = MenuDescriptor.build(
            provider: .rovodev,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let usageEntries = try #require(descriptor.sections.first?.entries)
        let textLines = usageEntries.compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }

        #expect(textLines.contains("847 / 2000 credits"))
        #expect(!textLines.contains(where: { $0.contains("Resets 847 / 2000 credits") }))
    }

    private static func snapshot(now: Date) -> UsageSnapshot {
        RovoDevUsageSnapshot(
            status: "OK",
            balance: RovoDevBalance(
                dailyTotal: nil,
                dailyRemaining: nil,
                dailyUsed: nil,
                monthlyTotal: 2000,
                monthlyRemaining: 1153,
                monthlyUsed: 847),
            message: nil,
            updatedAt: now).toUsageSnapshot()
    }
}

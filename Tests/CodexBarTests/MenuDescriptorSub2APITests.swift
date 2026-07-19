import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorSub2APITests {
    @Test
    func `subscription labels and per key totals reach descriptor output`() throws {
        let suite = "MenuDescriptorSub2APITests-usage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: nil, resetDescription: "$1 / $10"),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "$2 / $10"),
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 43200,
                resetsAt: nil,
                resetDescription: "$3 / $10"),
            sub2APIUsage: Sub2APIUsageDetails(
                kind: .subscription,
                balance: 42.5,
                unit: "USD",
                today: .init(requests: 4, totalTokens: 1200, actualCostUSD: 1.25),
                total: .init(requests: 40, totalTokens: 12000, actualCostUSD: 25)),
            updatedAt: Date(timeIntervalSince1970: 1),
            identity: ProviderIdentitySnapshot(
                providerID: .sub2api,
                accountEmail: nil,
                accountOrganization: "Enterprise",
                loginMethod: "Enterprise"))
        store._setSnapshotForTesting(snapshot, provider: .sub2api)

        let descriptor = MenuDescriptor.build(
            provider: .sub2api,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }

        #expect(lines.contains(where: { $0.hasPrefix("Daily quota:") }))
        #expect(lines.contains(where: { $0.hasPrefix("Weekly quota:") }))
        #expect(lines.contains(where: { $0.hasPrefix("Monthly quota:") }))
        #expect(lines.contains("Balance: $42.50"))
        #expect(lines.contains("Today: 4 requests · 1.2K tokens · $1.25"))
        #expect(lines.contains("Total: 40 requests · 12K tokens · $25.00"))
        #expect(lines.contains("Plan: Enterprise"))
    }
}

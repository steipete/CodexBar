import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct PiWidgetFreshnessTests {
    @Test
    func `Pi widget keeps the history measurement age after an empty local usage refresh`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = testSettingsStore(
            suiteName: "PiWidgetFreshnessTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.pi])
        settings.setProviderEnabled(provider: .pi, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        let measuredAt = Date().addingTimeInterval(-3600)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        store.publishTokenSnapshot(
            CostUsageTokenSnapshot(
                sessionTokens: 100,
                sessionCostUSD: 1,
                last30DaysTokens: 100,
                last30DaysCostUSD: 1,
                historyCoverageIsEstablished: false,
                daily: [],
                updatedAt: measuredAt),
            for: .pi,
            accounting: .piOnly(scope: "synthetic-source"))

        for refresh in [Date(), Date().addingTimeInterval(60)] {
            store._setSnapshotForTesting(
                UsageSnapshot(primary: nil, secondary: nil, updatedAt: refresh),
                provider: .pi)
            store.persistWidgetSnapshot(reason: "pi-history-age")
            await store.widgetSnapshotPersistTask?.value
            let entry = try #require(saved?.entries.first { $0.provider == .pi })
            #expect(entry.updatedAt == measuredAt)
            #expect(entry.tokenUsage?.updatedAt == measuredAt)
            #expect(entry.tokenUsage?.last30DaysTokens == 100)
        }
    }
}

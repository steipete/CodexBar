import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokXAISpendCatalogTests {
    @Test
    func `grok and xai publish through the snapshot-backed spend catalog`() {
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.grok))
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.xai))
        #expect(ProviderDescriptorRegistry.descriptor(for: .grok).tokenCost.supportsTokenCost)
        #expect(ProviderDescriptorRegistry.descriptor(for: .xai).tokenCost.supportsTokenCost)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["CODEXBAR_LIVE_GROK_CATALOG_PROOF"] == "1",
        "Set CODEXBAR_LIVE_GROK_CATALOG_PROOF=1 to scan local Grok sessions."))
    func `writes redacted live Grok catalog proof`() throws {
        let summary = GrokLocalSessionScanner.summarize(lookbackDays: SpendDashboardSource.scanDays)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: SpendDashboardSource.scanDays))
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .grok, displayName: "Grok", snapshot: snapshot)],
            requestedDays: 30,
            now: summary.scannedAt)
        let grokRow = try #require(model.groups.flatMap(\.providers).first { $0.id == UsageProvider.grok.rawValue })

        #expect(model.availableSources.map(\.id) == [UsageProvider.grok.rawValue])
        #expect(grokRow.totalTokens == snapshot.last30DaysTokens)
        #expect(model.tokenActivity.contains { $0.totalTokens != nil })

        print("catalog_source=grok")
        print("today_tokens=\(snapshot.sessionTokens ?? 0)")
        print("last_30_days_tokens=\(grokRow.totalTokens ?? 0)")
        print("daily_buckets=\(snapshot.daily.count)")
        print("available_sources=\(model.availableSources.map(\.id).joined(separator: ","))")
    }
}

import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokXAISpendCatalogTests {
    @Test
    func `grok and xai publish through the snapshot-backed spend catalog`() {
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.grok))
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.xai))
        let grokTokenCost = ProviderDescriptorRegistry.descriptor(for: .grok).tokenCost
        #expect(grokTokenCost.supportsTokenCost)
        #expect(ProviderDescriptorRegistry.descriptor(for: .xai).tokenCost.supportsTokenCost)
        #expect(grokTokenCost.noDataMessage() ==
            "Grok totals come from local Grok CLI session logs. Costs use the spend the CLI recorded, "
            + "or public list prices where it recorded none. Neither is a bill.")
        #expect(grokTokenCost.menuHintLines == [.estimate])
        #expect(grokTokenCost.showsHintInProviderDetails)
        #expect(grokTokenCost
            .estimateDisclaimer == "Grok CLI-recorded spend, list price where unrecorded · not a bill.")
        #expect(grokTokenCost.chartEstimateDisclaimer == .estimate)
    }

    @MainActor
    @Test
    func `populated Grok surfaces disclose that the cost is not a bill`() throws {
        let now = Date(timeIntervalSince1970: 1_787_587_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1100,
            sessionCostUSD: 0.0023,
            last30DaysTokens: 1100,
            last30DaysCostUSD: 0.0023,
            historyDays: 7,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-24",
                    inputTokens: 1000,
                    outputTokens: 100,
                    totalTokens: 1100,
                    costUSD: 0.0023,
                    modelsUsed: ["grok-4.6"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .grok,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .grok, displayName: "Grok", snapshot: snapshot)],
            requestedDays: 7,
            now: now)
        let row = try #require(dashboard.groups.first?.providers.first)

        #expect(section.hintLine == "Grok CLI-recorded spend, list price where unrecorded · not a bill.")
        #expect(row.totalCost == 0.0023)
        #expect(row.costDisclaimer == "Grok CLI-recorded spend, list price where unrecorded · not a bill.")
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
        let tokenDayCount = snapshot.daily.count { ($0.totalTokens ?? 0) > 0 }
        let pricedDayCount = snapshot.daily.count { $0.costUSD != nil }

        #expect(model.availableSources.map(\.id) == [UsageProvider.grok.rawValue])
        #expect(grokRow.totalTokens == snapshot.last30DaysTokens)
        #expect(model.tokenActivity.contains { $0.totalTokens != nil })
        #expect(snapshot.historyDays == SpendDashboardSource.scanDays)
        // Which source priced the corpus depends on what the CLI recorded, so assert the contract that
        // holds for every corpus: a priced window names a source, an unpriced one claims none.
        if pricedDayCount > 0 {
            #expect([.vendorMetered, .mixed, .listPriceEstimate].contains(snapshot.costProvenance))
        } else {
            #expect(snapshot.costProvenance == .unknown)
        }
        #expect(pricedDayCount <= tokenDayCount)
        if tokenDayCount > 0 {
            if pricedDayCount > 0 {
                let windowCostUSD = try #require(snapshot.last30DaysCostUSD)
                #expect(windowCostUSD > 0)
            } else {
                #expect(snapshot.last30DaysCostUSD == nil)
            }
        }

        print("catalog_source=grok")
        print("today_tokens=\(snapshot.sessionTokens ?? 0)")
        print("last_30_days_tokens=\(grokRow.totalTokens ?? 0)")
        print("today_cost_usd=\(snapshot.sessionCostUSD.map { String($0) } ?? "nil")")
        print("window_cost_usd=\(snapshot.last30DaysCostUSD.map { String($0) } ?? "nil")")
        print("cost_provenance=\(snapshot.costProvenance.rawValue)")
        print("history_days=\(snapshot.historyDays)")
        print("priced_days=\(pricedDayCount)")
        print("token_days=\(tokenDayCount)")
        print("daily_buckets=\(snapshot.daily.count)")
        print("available_sources=\(model.availableSources.map(\.id).joined(separator: ","))")
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardGrokFreshnessTests {
    @Test
    func `dashboard capture prefers newer local publication over preserved remote snapshot`() async throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardGrokFreshnessTests-preserved-remote")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .grok)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        let staleRemote = Self.snapshot(tokens: 77, cost: 0.77, updatedAt: now.addingTimeInterval(-60))
        let newerLocal = Self.snapshot(tokens: 100, cost: 1, updatedAt: now)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, costUsage: staleRemote, updatedAt: staleRemote.updatedAt),
            provider: .grok)
        store._setTokenSnapshotForTesting(newerLocal, provider: .grok)

        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)
        let captured = try #require(request.capturedInputs.first(where: { $0.provider == .grok }))

        #expect(captured.snapshot.last30DaysTokens == 100)
        #expect(captured.snapshot.last30DaysCostUSD == 1)
        #expect(captured.snapshot.updatedAt == now)
    }

    private static func snapshot(
        tokens: Int,
        cost: Double,
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        let date = Calendar.current.dateComponents([.year, .month, .day], from: updatedAt)
        let day = String(format: "%04d-%02d-%02d", date.year ?? 1970, date.month ?? 1, date.day ?? 1)
        return CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            daily: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: ["grok-4"],
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }
}

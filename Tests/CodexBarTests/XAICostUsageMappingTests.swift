import Foundation
import Testing
@testable import CodexBarCore

struct XAICostUsageMappingTests {
    @Test
    func `daily spend chart becomes vendor-metered catalog input`() throws {
        let snapshot = try self.snapshot(
            points: [("2026-08-17", 0.50), ("2026-08-18", 1.26)],
            confidence: .exact)
        let mapped = try #require(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30))
        #expect(mapped.last30DaysCostUSD == 1.76)
        #expect(mapped.last30DaysTokens == nil)
        #expect(mapped.sessionCostUSD == 1.26)
        #expect(mapped.costProvenance == .vendorMetered)
        #expect(mapped.daily.map(\.date) == ["2026-08-17", "2026-08-18"])
        #expect(mapped.daily.map(\.costUSD) == [0.50, 1.26])
        #expect(mapped.historyCoverageIsEstablished)
    }

    @Test
    func `prepaid balance alone is not spend`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 10,
                limit: 0,
                currencyCode: "USD",
                period: "Prepaid credits",
                updatedAt: Date()),
            updatedAt: Date())
        #expect(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30) == nil)
    }

    @Test
    func `partial history stays estimated`() throws {
        let snapshot = try self.snapshot(points: [("2026-08-18", 1.0)], confidence: .estimated)
        let mapped = try #require(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30))
        #expect(mapped.historyCoverageIsEstablished == false)
        #expect(mapped.historyLabel == "Last 30 days (partial)")
    }

    private func snapshot(
        points: [(String, Double)],
        confidence: UsageDataConfidence) throws -> UsageSnapshot
    {
        let chart = try ProviderDetailSection.Chart(
            kind: .bars,
            title: "Daily spend",
            unit: "USD",
            points: points.map { try ProviderDetailSection.Chart.Point(label: $0.0, value: $0.1) })
        let details = try [ProviderDetailSection(
            title: "Billing summary",
            rows: [ProviderDetailSection.Row(label: "Last 30 days", value: "$1.76")],
            chart: chart)]
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: details,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            dataConfidence: confidence)
    }
}

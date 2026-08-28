import Foundation
import Testing
@testable import CodexBarCore

struct CostProvenanceTests {
    @Test
    func `cost figures are never billing receipts`() {
        for provenance in [CostProvenance.listPriceEstimate, .vendorMetered, .mixed, .unknown] {
            #expect(!provenance.isBillingReceipt)
        }
    }

    @Test
    func `coverage ratio ignores missing categories instead of collapsing them`() {
        let empty = CostUsageCoverageCounts()
        #expect(empty.coverageRatio == nil)

        let mixed = CostUsageCoverageCounts(priced: 2, unpriced: 1, unmetered: 1, estimated: 2)
        #expect(mixed.total == 6)
        #expect(mixed.coverageRatio == 4.0 / 6.0)
    }

    @Test
    func `token mix keeps nil distinct from zero`() {
        var mix = CostUsageTokenMix(inputTokens: 10, outputTokens: nil)
        #expect(mix.inputTokens == 10)
        #expect(mix.outputTokens == nil)
        mix.merge(CostUsageTokenMix(outputTokens: 4, reasoningTokens: 0))
        #expect(mix.outputTokens == 4)
        #expect(mix.reasoningTokens == 0)
        mix.merge(CostUsageTokenMix(inputTokens: 5))
        #expect(mix.inputTokens == 15)
        #expect(mix.cacheReadTokens == nil)
    }

    @Test
    func `day rows without request counts still expose priced or unpriced coverage`() {
        let priced = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 10,
            outputTokens: 2,
            totalTokens: 12,
            costUSD: 1.25,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(priced.coverageCounts == CostUsageCoverageCounts(priced: 1))

        let unpriced = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 10,
            outputTokens: 2,
            totalTokens: 12,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(unpriced.coverageCounts == CostUsageCoverageCounts(unpriced: 1))

        let unmetered = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unmeteredRequestCount: 2)
        #expect(unmetered.coverageCounts == CostUsageCoverageCounts(unmetered: 2))
    }

    @Test
    func `vendor reported snapshots stay vendor metered without meteredCostUSD`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1.25,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1.25,
            historyDays: 30,
            costProvenance: .vendorMetered,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-01",
                    inputTokens: 8,
                    outputTokens: 2,
                    totalTokens: 10,
                    costUSD: 1.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_782_864_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let summary = snapshot.summary(forLastDays: 7, calendar: calendar)
        #expect(summary.provenance == .vendorMetered)
        #expect(summary.totalCostUSD == 1.25)
        #expect(summary.meteredCostUSD == nil)
    }

    @Test
    func `shorter summaries omit snapshot-wide metered spend`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10,
            historyDays: 30,
            meteredCostUSD: 4.5,
            costProvenance: .mixed,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-01",
                    inputTokens: 8,
                    outputTokens: 2,
                    totalTokens: 10,
                    costUSD: 1,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_782_864_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let week = snapshot.summary(forLastDays: 7, calendar: calendar)
        let month = snapshot.summary(forLastDays: 30, calendar: calendar)
        #expect(week.meteredCostUSD == nil)
        #expect(week.provenance == .listPriceEstimate)
        #expect(month.meteredCostUSD == 4.5)
        #expect(month.provenance == .mixed)
    }

    @Test
    func `cached previous reports round-trip coverage counters`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 10,
            outputTokens: 2,
            totalTokens: 12,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: 1,
            unmeteredRequestCount: 2,
            estimatedRequestCount: 3)
        let cached = CostUsageCodexPreviousReport.Entry(entry)
        let restored = cached.dailyReportValue
        #expect(restored.unpricedRequestCount == 1)
        #expect(restored.unmeteredRequestCount == 2)
        #expect(restored.estimatedRequestCount == 3)
        let data = try JSONEncoder().encode(cached)
        let decoded = try JSONDecoder().decode(CostUsageCodexPreviousReport.Entry.self, from: data)
        #expect(decoded.dailyReportValue.unmeteredRequestCount == 2)
        #expect(decoded.dailyReportValue.estimatedRequestCount == 3)
    }
}

struct CostUsageBucketTimeZoneTests {
    @Test
    func `pins a valid IANA identifier and rejects junk`() {
        #expect(CostUsageBucketTimeZone.isValidIdentifier("America/Los_Angeles"))
        #expect(!CostUsageBucketTimeZone.isValidIdentifier("Not/AZone"))
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "America/Los_Angeles")
        #expect(calendar.timeZone.identifier == "America/Los_Angeles")
        #expect(calendar.identifier == .gregorian)
    }

    @Test
    func `a pinned zone keeps midnight-adjacent events on the same local day`() throws {
        let timestamp = "2026-07-16T06:30:00Z"
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let westKey = try #require(CostUsageScanner.dayKeyFromTimestamp(timestamp, calendar: losAngeles))
        let eastKey = try #require(CostUsageScanner.dayKeyFromTimestamp(timestamp, calendar: shanghai))
        #expect(westKey == "2026-07-15")
        #expect(eastKey == "2026-07-16")

        let pinned = CostUsageBucketTimeZone.calendar(identifier: "America/Los_Angeles")
        #expect(CostUsageScanner.dayKeyFromTimestamp(timestamp, calendar: pinned) == westKey)
        #expect(CostUsageScanner.dayKeyFromTimestamp(timestamp, calendar: pinned) != eastKey)
    }
}

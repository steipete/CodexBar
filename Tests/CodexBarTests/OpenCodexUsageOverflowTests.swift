import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodexUsageOverflowTests {
    @Test
    func `derived token totals reject an unrepresentable sum`() {
        let usage = OpenCodexTokenUsage(inputTokens: Int.max, outputTokens: 1)
        #expect(usage.resolvedTotalTokens == nil)
        #expect(usage.inputTokens == Int.max)
        #expect(usage.outputTokens == 1)
        #expect(OpenCodexTokenUsage().resolvedTotalTokens == nil)
        #expect(OpenCodexTokenUsage(inputTokens: 0).resolvedTotalTokens == 0)
        #expect(OpenCodexTokenUsage(inputTokens: Int.max, outputTokens: 1, totalTokens: 0).resolvedTotalTokens == 0)
    }

    @Test(arguments: [[0, 0, 0], [-2, -1, 0], [-1, -1, 0]])
    func `OpenCodex bucket sums keep overflow unavailable after later contributions`(_ dayOffsets: [Int]) throws {
        let now = Date(timeIntervalSince1970: 1_784_222_400)
        let entries = [Int.max, 1, 5].enumerated().map { index, value in
            OpenCodexUsageEntry(
                requestID: "row-\(index)",
                timestamp: now.addingTimeInterval(Double(dayOffsets[index]) * 86400 + Double(index - 2)),
                provider: "openai",
                model: "fixture-model",
                usageStatus: .unreported,
                conversationID: "shared-session",
                usage: OpenCodexTokenUsage(
                    inputTokens: value,
                    outputTokens: 2,
                    cacheReadInputTokens: value,
                    cacheCreationInputTokens: value,
                    reasoningOutputTokens: value,
                    totalTokens: value))
        }
        let result = Self.snapshot(entries: entries, now: now)
        #expect(result.last30DaysTokens == nil)
        #expect(result.sessionTokens == (dayOffsets[0] == 0 ? nil : 5))
        let session = try #require(result.sessions.first)
        #expect(session.totalTokens == nil)
        #expect(session.inputTokens == nil)
        #expect(session.cachedInputTokens == nil)
        #expect(session.reasoningTokens == nil)
        #expect(session.outputTokens == 6)
        #expect(session.requestCount == 3)
        #expect(session.modelBreakdowns.first?.totalTokens == nil)
        if dayOffsets[0] == 0 {
            let day = try #require(result.daily.first)
            #expect(day.totalTokens == nil)
            #expect(day.inputTokens == nil)
            #expect(day.cacheReadTokens == nil)
            #expect(day.cacheCreationTokens == nil)
            #expect(day.reasoningTokens == nil)
            #expect(day.outputTokens == 6)
            #expect(day.modelBreakdowns?.first?.totalTokens == nil)
            #expect(result.hourly.allSatisfy { $0.totalTokens == nil })
        }
    }

    @Test
    func `an overflowing derived entry is not reported as zero today`() {
        let now = Date(timeIntervalSince1970: 1_784_222_400)
        let entry = OpenCodexUsageEntry(
            requestID: "derived",
            timestamp: now,
            provider: "openai",
            model: "fixture-model",
            usageStatus: .unreported,
            usage: OpenCodexTokenUsage(inputTokens: Int.max, outputTokens: 1))
        let result = Self.snapshot(entries: [entry], now: now)
        #expect(result.sessionTokens == nil)
        #expect(result.last30DaysTokens == nil)
        #expect(result.daily.first?.inputTokens == Int.max)
        #expect(result.daily.first?.outputTokens == 1)
        #expect(result.sessions.first?.totalTokens == nil)
        #expect(result.hourly.first?.totalTokens == nil)
    }

    @Test(arguments: [[0, 0, 0], [-2, -1, 0], [-1, -1, 0]])
    func `daily report token sums use the established sticky overflow contract`(_ dayOffsets: [Int]) throws {
        let reports = [Int.max, 1, 5].enumerated().map { index, value in
            CostUsageDailyReport(data: [Self.entry(
                date: "2026-07-\(16 + dayOffsets[index])", value: value)], summary: nil)
        }
        let merged = CostUsageDailyReport.merged(reports)
        #expect(merged.summary?.totalTokens == nil)
        #expect(merged.summary?.totalInputTokens == nil)
        #expect(merged.summary?.cacheReadTokens == nil)
        #expect(merged.summary?.cacheCreationTokens == nil)
        #expect(merged.summary?.reasoningTokens == nil)
        #expect(merged.summary?.totalOutputTokens == 6)
        let modelTotals = try #require(CostUsageDailyReport.modelCostSummaries(from: merged.data).first)
        // A new pass sums known materialized rows; nil has no serialized overflow provenance.
        let materializedTotal: Int? = dayOffsets == [-1, -1, 0] ? 5 : nil
        #expect(modelTotals.totalTokens == materializedTotal)
        #expect(modelTotals.standardTokens == materializedTotal)
        #expect(modelTotals.priorityTokens == materializedTotal)
        if dayOffsets[0] == 0 {
            let day = try #require(merged.data.first)
            #expect(day.totalTokens == nil)
            #expect(day.inputTokens == nil)
            #expect(day.outputTokens == 6)
        }
    }

    @Test
    func `derived daily totals and native OpenCodex merges reject overflow`() {
        let derived = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: Int.max,
            outputTokens: 1,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let report = CostUsageDailyReport.merged([.init(data: [derived], summary: nil)])
        #expect(report.data.first?.totalTokens == nil)
        #expect(report.summary?.totalTokens == nil)
        let now = Date(timeIntervalSince1970: 1_784_222_400)
        let base = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [Self.entry(date: "2026-07-16", value: Int.max)], summary: nil),
            now: now,
            calendar: Self.calendar)
        let supplement = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [Self.entry(date: "2026-07-16", value: 1)], summary: nil),
            now: now,
            calendar: Self.calendar)
        let merged = OpenCodexUsageFanOut.mergeSnapshots(
            base, supplement, now: now, historyDays: 7, calendar: Self.calendar)
        #expect(merged.sessionTokens == nil)
        #expect(merged.last30DaysTokens == nil)
        #expect(merged.daily.first?.inputTokens == nil)
        #expect(merged.daily.first?.outputTokens == 4)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func snapshot(entries: [OpenCodexUsageEntry], now: Date) -> CostUsageTokenSnapshot {
        OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: self.calendar,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            customPricingOverlay: .empty)
    }

    private static func entry(date: String, value: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: value,
            outputTokens: 2,
            cacheReadTokens: value,
            cacheCreationTokens: value,
            reasoningTokens: value,
            totalTokens: value,
            costUSD: nil,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: [.init(
                modelName: "fixture-model",
                costUSD: nil,
                totalTokens: value,
                standardTokens: value,
                priorityTokens: value)])
    }
}

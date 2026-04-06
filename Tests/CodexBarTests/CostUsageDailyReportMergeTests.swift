import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageDailyReportMergeTests {
    @Test
    func `merged report sums overlapping day totals and model breakdowns`() {
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 10,
                    cacheCreationTokens: nil,
                    totalTokens: 130,
                    costUSD: 1.25,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 1.25, totalTokens: 130),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 100,
                totalOutputTokens: 20,
                cacheReadTokens: 10,
                cacheCreationTokens: nil,
                totalTokens: 130,
                totalCostUSD: 1.25))
        let pi = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 50,
                    outputTokens: 10,
                    cacheReadTokens: 5,
                    cacheCreationTokens: 2,
                    totalTokens: 67,
                    costUSD: 0.75,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 0.75, totalTokens: 67),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 50,
                totalOutputTokens: 10,
                cacheReadTokens: 5,
                cacheCreationTokens: 2,
                totalTokens: 67,
                totalCostUSD: 0.75))

        let merged = native.merged(with: pi)
        #expect(merged.data.count == 1)
        #expect(merged.data.first?.inputTokens == 150)
        #expect(merged.data.first?.outputTokens == 30)
        #expect(merged.data.first?.cacheReadTokens == 15)
        #expect(merged.data.first?.cacheCreationTokens == 2)
        #expect(merged.data.first?.totalTokens == 197)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 2.0) < 0.000001)
        #expect(merged.data.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 2.0, totalTokens: 197),
        ])
        #expect(merged.summary?.totalTokens == 197)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 2.0) < 0.000001)
    }

    @Test
    func `merged report unions days and orders model breakdowns deterministically`() {
        let first = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 30,
                    costUSD: 0.30,
                    modelsUsed: ["gpt-5.3-codex"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.3-codex", costUSD: 0.30, totalTokens: 30),
                    ]),
            ],
            summary: nil)
        let second = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-05",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 40,
                    costUSD: 0.40,
                    modelsUsed: ["gpt-5.4", "gpt-5.3-codex"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 0.40, totalTokens: 40),
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.3-codex", costUSD: 0.00, totalTokens: 0),
                    ]),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([first, second])
        #expect(merged.data.map(\.date) == ["2026-04-04", "2026-04-05"])
        #expect(merged.data.last?.modelBreakdowns?.map(\.modelName) == ["gpt-5.4", "gpt-5.3-codex"])
        #expect(merged.summary?.totalTokens == 70)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 0.70) < 0.000001)
    }
}

import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageDailyReportMergeTests {
    @Test(arguments: [nil, 0, 7] as [Int?])
    func `single report merge preserves known zero and missing token classes`(_ value: Int?) throws {
        let mix = CostUsageTokenMix(
            inputTokens: value,
            outputTokens: value,
            cacheReadTokens: value,
            cacheCreationTokens: value,
            reasoningTokens: value)
        let original = Self.tokenDetailReport(mix: mix, totalTokens: 50)
        let merged = CostUsageDailyReport.merged([original])
        let entry = try #require(merged.data.first)
        #expect(entry == original.data.first)
        #expect(CostUsageTokenMix.from(entry: entry) == mix)
        #expect(try Self.mix(#require(entry.modelBreakdowns?.first)) == mix)
        #expect(entry.coverageCounts == original.data.first?.coverageCounts)
        #expect(merged.summary?.reasoningTokens == value)
        #expect(merged.summary?.totalTokens == 50)
    }

    @Test
    func `merged token details sum without adding reasoning to total tokens`() throws {
        let first = Self.tokenDetailReport(
            mix: .init(inputTokens: 100, outputTokens: 20, cacheReadTokens: 10, reasoningTokens: 8),
            totalTokens: 120)
        let second = Self.tokenDetailReport(
            mix: .init(
                inputTokens: 50,
                outputTokens: 10,
                cacheReadTokens: 5,
                cacheCreationTokens: 0,
                reasoningTokens: 2),
            totalTokens: 60)
        let merged = CostUsageDailyReport.merged([first, second])
        let expectedMix = CostUsageTokenMix(
            inputTokens: 150, outputTokens: 30, cacheReadTokens: 15, cacheCreationTokens: 0, reasoningTokens: 10)
        let entry = try #require(merged.data.first)
        #expect(CostUsageTokenMix.from(entry: entry) == expectedMix)
        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(Self.mix(breakdown) == expectedMix)
        #expect(entry.totalTokens == 180)
        #expect(breakdown.totalTokens == 180)
        #expect(merged.summary?.totalTokens == 180)
        #expect(merged.summary?.reasoningTokens == 10)
    }

    @Test(arguments: [false, true])
    func `merged token detail overflow remains unknown after later contributions`(_ separateDays: Bool) throws {
        let values = [Int.max, 1, 5]
        let reports = values.enumerated().map { index, value in
            CostUsageDailyReport(
                data: [.init(
                    date: separateDays ? "2026-08-\(10 + index)" : "2026-08-10",
                    inputTokens: nil,
                    outputTokens: nil,
                    reasoningTokens: value,
                    totalTokens: 0,
                    costUSD: nil,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [.init(
                        modelName: "gpt-5.4",
                        costUSD: nil,
                        totalTokens: 0,
                        inputTokens: value,
                        outputTokens: value,
                        cacheReadTokens: value,
                        cacheCreationTokens: value,
                        reasoningTokens: value)])],
                summary: nil)
        }
        let merged = CostUsageDailyReport.merged(reports)
        #expect(merged.summary?.reasoningTokens == nil)
        #expect(merged.summary?.totalTokens == 0)
        if !separateDays {
            let entry = try #require(merged.data.first)
            #expect(entry.reasoningTokens == nil)
            #expect(try Self.mix(#require(entry.modelBreakdowns?.first)) == CostUsageTokenMix())
        }
    }

    private static func tokenDetailReport(mix: CostUsageTokenMix, totalTokens: Int) -> CostUsageDailyReport {
        CostUsageDailyReport(
            data: [.init(
                date: "2026-08-30",
                inputTokens: mix.inputTokens,
                outputTokens: mix.outputTokens,
                cacheReadTokens: mix.cacheReadTokens,
                cacheCreationTokens: mix.cacheCreationTokens,
                reasoningTokens: mix.reasoningTokens,
                totalTokens: totalTokens,
                costUSD: 1,
                modelsUsed: ["gpt-5.4"],
                modelBreakdowns: [.init(
                    modelName: "gpt-5.4",
                    costUSD: 1,
                    totalTokens: totalTokens,
                    inputTokens: mix.inputTokens,
                    outputTokens: mix.outputTokens,
                    cacheReadTokens: mix.cacheReadTokens,
                    cacheCreationTokens: mix.cacheCreationTokens,
                    reasoningTokens: mix.reasoningTokens)])],
            summary: nil)
    }

    private static func mix(_ breakdown: CostUsageDailyReport.ModelBreakdown) -> CostUsageTokenMix {
        .init(
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheReadTokens: breakdown.cacheReadTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            reasoningTokens: breakdown.reasoningTokens)
    }

    @Test
    func `merge preserves input coverage before combining costs and requests`() throws {
        let inferred = Self.coverageEntry(cost: 1, requests: 3, unpriced: 1)
        let unmetered = Self.coverageEntry(cost: nil, requests: nil, unmetered: 2)
        let explicit = Self.coverageEntry(cost: 1, requests: 4, unpriced: 1, estimated: 3, priced: 0)
        let merged = CostUsageDailyReport.merged([
            .init(data: [inferred], summary: nil),
            .init(data: [unmetered], summary: nil),
            .init(data: [explicit], summary: nil),
        ])
        let entry = try #require(merged.data.first)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 2, unpriced: 2, unmetered: 2, estimated: 3))
        #expect(entry.requestCount == 7)
        #expect(entry.costUSD == 2)

        let explicitOnly = CostUsageDailyReport.merged([.init(data: [explicit], summary: nil)])
        #expect(explicitOnly.data.first?.pricedRequestCount == 0)
        #expect(explicitOnly.data.first?.coverageCounts == explicit.coverageCounts)
        let unmeteredOnly = CostUsageDailyReport.merged([.init(data: [unmetered], summary: nil)])
        #expect(unmeteredOnly.data.first?.coverageCounts == unmetered.coverageCounts)
        #expect(unmeteredOnly.data.first?.requestCount == nil)
    }

    @Test(arguments: [nil, 0, 3] as [Int?])
    func `merge retains known request counts without inventing unknown requests`(_ count: Int?) throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-08-30",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 0,
            requestCount: count,
            costUSD: nil,
            modelsUsed: ["gpt-5.4"],
            modelBreakdowns: [.init(modelName: "gpt-5.4", costUSD: nil, totalTokens: 0, requestCount: count)])
        let report = CostUsageDailyReport(data: [entry], summary: nil)
        let merged = CostUsageDailyReport.merged([report, report])
        let result = try #require(merged.data.first)
        #expect(result.requestCount == count.map { $0 * 2 })
        #expect(result.modelBreakdowns?.first?.requestCount == count.map { $0 * 2 })
    }

    @Test
    func `overflowed request counts stay unknown after a later known count`() {
        let reports = [Int.max, 1, 3].map { count in
            CostUsageDailyReport(
                data: [.init(
                    date: "2026-08-30",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 0,
                    requestCount: count,
                    costUSD: nil,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [.init(
                        modelName: "gpt-5.4", costUSD: nil, totalTokens: 0, requestCount: count)],
                    pricedRequestCount: 0)],
                summary: nil)
        }
        let merged = CostUsageDailyReport.merged(reports)
        #expect(merged.data.first?.requestCount == nil)
        #expect(merged.data.first?.modelBreakdowns?.first?.requestCount == nil)
    }

    private static func coverageEntry(
        cost: Double?,
        requests: Int?,
        unpriced: Int? = nil,
        unmetered: Int? = nil,
        estimated: Int? = nil,
        priced: Int? = nil) -> CostUsageDailyReport.Entry
    {
        .init(
            date: "2026-08-30",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: unpriced,
            unmeteredRequestCount: unmetered,
            estimatedRequestCount: estimated,
            pricedRequestCount: priced)
    }

    @Test(arguments: [false, true])
    func `unrepresentable merged coverage retains row fallback without trapping`(_ acrossCategories: Bool) throws {
        let first = Self.coverageEntry(cost: 1, requests: nil, priced: Int.max)
        let second = Self.coverageEntry(
            cost: 1,
            requests: nil,
            unmetered: acrossCategories ? 1 : nil,
            priced: acrossCategories ? 0 : 1)
        let later = Self.coverageEntry(cost: 1, requests: nil, priced: 1)
        let merged = CostUsageDailyReport.merged([
            .init(data: [first], summary: nil),
            .init(data: [second], summary: nil),
            .init(data: [later], summary: nil),
        ])
        let entry = try #require(merged.data.first)
        #expect(entry.pricedRequestCount == nil)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.estimatedRequestCount == nil)
        #expect(entry.requestCount == nil)
        #expect(entry.costUSD == 3)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 1))
        #expect(entry.coverageCounts.total == 1)
        #expect(entry.coverageCounts.coverageRatio == 1)
    }

    @Test(arguments: [nil, 7] as [Int?])
    func `unrepresentable source coverage retains inferred fallback without trapping`(_ requests: Int?) throws {
        let source = Self.coverageEntry(cost: 1, requests: requests, unpriced: Int.max, unmetered: 1)
        let merged = CostUsageDailyReport.merged([.init(data: [source], summary: nil)])
        let entry = try #require(merged.data.first)
        #expect(entry.pricedRequestCount == nil)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.estimatedRequestCount == nil)
        #expect(entry.requestCount == requests)
        #expect(entry.costUSD == 1)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: requests ?? 1))
        #expect(entry.coverageCounts.total == requests ?? 1)
        #expect(entry.coverageCounts.coverageRatio == 1)
    }

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
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 1.25,
                            totalTokens: 130,
                            standardCostUSD: 0.75,
                            priorityCostUSD: 0.50,
                            standardTokens: 80,
                            priorityTokens: 50),
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
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.75,
                            totalTokens: 67,
                            standardCostUSD: 0.25,
                            priorityCostUSD: 0.50,
                            standardTokens: 20,
                            priorityTokens: 47),
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
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.4",
                costUSD: 2.0,
                totalTokens: 197,
                standardCostUSD: 1.0,
                priorityCostUSD: 1.0,
                standardTokens: 100,
                priorityTokens: 97),
        ])
        #expect(merged.summary?.totalTokens == 197)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 2.0) < 0.000001)
    }

    @Test
    func `merged model breakdowns drop cost when one source is unpriced`() {
        let priced = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 130,
                    costUSD: 1.25,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 1.25,
                            totalTokens: 130),
                    ]),
            ],
            summary: nil)
        let unpriced = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 50,
                    requestCount: 1,
                    costUSD: nil,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: nil,
                            totalTokens: 50,
                            requestCount: 1),
                    ]),
            ],
            summary: nil)

        let merged = priced.merged(with: unpriced)
        #expect(merged.data.first?.costUSD == nil)
        #expect(merged.data.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(merged.data.first?.modelBreakdowns?.first?.totalTokens == 180)
    }

    @Test
    func `merged report keeps priced model subtotal beside unpriced models`() throws {
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-31",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 600,
                    costUSD: 4.5,
                    modelsUsed: ["codex-auto-review", "gpt-5.6-sol"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.6-sol",
                            costUSD: 4.5,
                            totalTokens: 400),
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "codex-auto-review",
                            costUSD: nil,
                            totalTokens: 200),
                    ]),
            ],
            summary: nil)
        let emptyPi = CostUsageDailyReport(data: [], summary: nil)
        let merged = CostUsageDailyReport.merged([native, emptyPi])
        let entry = try #require(merged.data.first)
        #expect(abs((entry.costUSD ?? 0) - 4.5) < 0.000001)
        #expect(entry.totalTokens == 600)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "gpt-5.6-sol" }?.costUSD == 4.5)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "codex-auto-review" }?.costUSD == nil)
        #expect(merged.summary?.totalCostUSD == 4.5)
    }

    @Test
    func `merged report keeps native priced subtotal when another model is unpriced`() throws {
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-31",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 400,
                    costUSD: 4.5,
                    modelsUsed: ["gpt-5.6-sol"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.6-sol",
                            costUSD: 4.5,
                            totalTokens: 400),
                    ]),
            ],
            summary: nil)
        let pi = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-31",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 80,
                    costUSD: nil,
                    modelsUsed: ["pi-unpriced"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "pi-unpriced",
                            costUSD: nil,
                            totalTokens: 80),
                    ]),
            ],
            summary: nil)
        let merged = native.merged(with: pi)
        let entry = try #require(merged.data.first)
        #expect(abs((entry.costUSD ?? 0) - 4.5) < 0.000001)
        #expect(entry.totalTokens == 480)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "gpt-5.6-sol" }?.costUSD == 4.5)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "pi-unpriced" }?.costUSD == nil)
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

    @Test
    func `merged report includes derived totals when another same day entry has explicit total`() {
        let explicit = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 70,
                    outputTokens: 30,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil)
        let derived = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 3,
                    cacheCreationTokens: 2,
                    totalTokens: nil,
                    costUSD: 0.25,
                    modelsUsed: ["gpt-5.3-codex"],
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([explicit, derived])
        #expect(merged.data.first?.totalTokens == 120)
        #expect(merged.summary?.totalTokens == 120)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 1.25) < 0.000001)
    }
}

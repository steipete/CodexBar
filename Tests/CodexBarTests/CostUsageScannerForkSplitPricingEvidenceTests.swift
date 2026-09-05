import Foundation
#if canImport(SQLite3)
import Testing
@testable import CodexBarCore

extension CostUsageScannerForkSplitTests {
    @Test
    func `copied cost only prefix does not survive exact token ownership`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.4-mini"
        let copiedCost = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "copied-cost",
            eventIndex: 0,
            input: 0,
            cached: 0,
            output: 0,
            knownCostNanos: 42_000_000_000)
        let child = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "child",
            eventIndex: 1,
            input: 100_000,
            cached: 0,
            output: 10)
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [100_000, 0, 10]]],
            parsedBytes: 1,
            codexRows: [copiedCost, child],
            codexScanComplete: true)
        let reconciled = CostUsageScanner.codexCanonicalPricingRows(usage)
        #expect(reconciled.rows.isEmpty)
        #expect(reconciled.unresolvedGroups == [CostUsageScanner.CodexDayModelKey(day: dayKey, model: model)])

        var zeroOwnedUsage = usage
        zeroOwnedUsage.days = [dayKey: [model: [0, 0, 0]]]
        zeroOwnedUsage.codexRows = [copiedCost]
        let zeroOwned = CostUsageScanner.codexCanonicalPricingRows(zeroOwnedUsage)
        #expect(zeroOwned.rows.isEmpty)
        #expect(zeroOwned.unresolvedGroups.isEmpty)

        var cache = CostUsageCache()
        cache.files = ["/copied-cost-prefix.jsonl": usage]
        cache.days = usage.days
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
    }

    @Test
    func `unresolved rows preserve incomplete pricing evidence`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.4-mini"
        let priced = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "priced-prefix",
            eventIndex: 0,
            input: 150_000,
            cached: 0,
            output: 10,
            pricingModel: model)
        let unpriced = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "unpriced-suffix",
            eventIndex: 1,
            input: 100_000,
            cached: 0,
            output: 10,
            pricingModel: "unpriced-test-model")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [200_000, 0, 20]]],
            parsedBytes: 1,
            codexRows: [priced, unpriced],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/unresolved-unpriced.jsonl": usage]
        cache.days = usage.days

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
    }

    @Test
    func `trace priority turns keep row ownership for rows persisted as standard`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.5"
        let inputPerRow = 150_000
        let outputPerRow = 10
        let tokensPerRow = inputPerRow + outputPerRow
        // The rollout only ever labelled these rows standard; the trace database is the sole
        // source that knows the second turn was served on the priority tier.
        let standardRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "standard-turn",
            eventIndex: 0,
            input: inputPerRow,
            cached: 0,
            output: outputPerRow,
            pricingModel: model,
            pricingMode: "standard")
        let tracePriorityRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "trace-priority-turn",
            eventIndex: 1,
            input: inputPerRow,
            cached: 0,
            output: outputPerRow,
            pricingModel: model,
            pricingMode: "standard")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [inputPerRow * 2, 0, outputPerRow * 2]]],
            parsedBytes: 1,
            codexStandardTokens: [dayKey: [model: tokensPerRow * 2]],
            codexPriorityTokens: [dayKey: [model: 0]],
            codexRows: [standardRow, tracePriorityRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/trace-priority.jsonl": usage]
        cache.days = usage.days

        let priorityTurns = [
            "trace-priority-turn": CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: nil,
                turnID: "trace-priority-turn",
                model: nil,
                timestamp: nil),
        ]
        let evidence = CostUsageScanner.codexPricingModeEvidence(
            usage: usage,
            reconciledRows: CostUsageScanner.codexCanonicalPricingRows(usage).rows,
            range: range,
            priorityTurns: priorityTurns)
        #expect(evidence.mismatchGroups.isEmpty)

        // The day aggregate crosses the long-context threshold, so the aggregate fallback cannot
        // price this group: only the retained rows can, and distrusting them blanks the whole day.
        #expect(CostUsagePricing.codexAggregateCostUSD(
            model: model,
            inputTokens: inputPerRow * 2,
            cachedInputTokens: 0,
            outputTokens: outputPerRow * 2) == nil)

        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            priorityTurns: priorityTurns)
        let standardCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: inputPerRow,
            cachedInputTokens: 0,
            outputTokens: outputPerRow))
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: model,
            inputTokens: inputPerRow,
            outputTokens: outputPerRow))
        let entry = try #require(report.data.first)
        let cost = try #require(entry.costUSD)
        #expect(abs(cost - (standardCost + priorityCost)) < 0.000000001)
        #expect(report.summary?.totalCostUSD != nil)
        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(breakdown.priorityTokens == tokensPerRow)
        #expect(breakdown.standardTokens == tokensPerRow)
    }

    @Test
    func `stale persisted mode split still invalidates row ownership`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.5"
        let inputPerRow = 150_000
        let outputPerRow = 10
        let tokensPerRow = inputPerRow + outputPerRow
        let rows = (0..<2).map { index in
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: model,
                turnID: "turn-\(index)",
                eventIndex: index,
                input: inputPerRow,
                cached: 0,
                output: outputPerRow,
                pricingModel: model,
                pricingMode: "standard")
        }
        // A copied fork prefix can leave a mode split that no classification of the retained rows
        // reproduces; that evidence must keep distrusting the rows.
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [inputPerRow * 2, 0, outputPerRow * 2]]],
            parsedBytes: 1,
            codexStandardTokens: [dayKey: [model: tokensPerRow]],
            codexPriorityTokens: [dayKey: [model: tokensPerRow]],
            codexRows: rows,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/stale-mode-split.jsonl": usage]
        cache.days = usage.days

        let evidence = CostUsageScanner.codexPricingModeEvidence(
            usage: usage,
            reconciledRows: CostUsageScanner.codexCanonicalPricingRows(usage).rows,
            range: range,
            priorityTurns: [:])
        #expect(evidence.mismatchGroups == [CostUsageScanner.CodexDayModelKey(day: dayKey, model: model)])

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
    }
}
#endif

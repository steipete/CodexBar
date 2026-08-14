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
}
#endif

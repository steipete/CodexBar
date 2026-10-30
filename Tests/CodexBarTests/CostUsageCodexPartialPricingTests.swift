import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexPartialPricingTests {
    /// One request with unknown historical pricing must not erase the estimate for the other requests of the same
    /// model and day. Quota windows already price those requests and flag the window incomplete.
    @Test
    func `an unpriced request keeps the priced subtotal of its model day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try Self.writeSession(env: env, day: day, id: "partial", model: "gpt-5.4")
        let cache = try Self.scannedCache(day: day, env: env)

        let report = try Self.report(Self.marking(cache, path: file.path, rows: [0]), day: day)
        let entry = try #require(report.data.first)
        let windowSubtotal: Double = report.quotaSlices.compactMap(\.costUSD).reduce(0, +)
        let breakdown = try #require(entry.modelBreakdowns?.first)

        #expect(windowSubtotal > 0)
        #expect(abs((entry.costUSD ?? -1) - windowSubtotal) < 1e-9)
        #expect(abs((breakdown.costUSD ?? -1) - windowSubtotal) < 1e-9)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 2)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 2, unpriced: 1))
        // The marked request's tier is unknown, so the group does not claim a standard/priority split.
        #expect(breakdown.standardCostUSD == nil)
        #expect(breakdown.priorityCostUSD == nil)
        #expect(entry.totalTokens == Self.report(cache, day: day).data.first?.totalTokens)
    }

    /// A day whose second model has no estimate is a partial day, not a fully priced one.
    @Test
    func `a day with an unpriced model reports incomplete coverage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        _ = try Self.writeSession(env: env, day: day, id: "priced", model: "gpt-5.4", inputs: [100_000])
        let other = try Self.writeSession(env: env, day: day, id: "unknown", model: "gpt-5.5", inputs: [100_000])
        let cache = try Self.scannedCache(day: day, env: env)
        let pricedOnly = try #require(Self.report(cache, day: day).data.first?.modelBreakdowns?
            .first { $0.modelName == "gpt-5.4" }?.costUSD)

        let entry = try #require(Self.report(Self.marking(cache, path: other.path, rows: [0]), day: day).data.first)
        let unpricedModel = try #require(entry.modelBreakdowns?.first { $0.modelName == "gpt-5.5" })

        #expect(unpricedModel.costUSD == nil)
        #expect(abs((entry.costUSD ?? -1) - pricedOnly) < 1e-9)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.coverageCounts.unpriced == 1)
    }

    /// Every request unknown: the group stays unpriced, and current list prices are not used as a fallback.
    @Test
    func `a fully marked model day stays unpriced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try Self.writeSession(env: env, day: day, id: "unknown", model: "gpt-5.4")
        let cache = try Self.scannedCache(day: day, env: env)

        let report = try Self.report(Self.marking(cache, path: file.path, rows: [0, 1, 2]), day: day)
        let entry = try #require(report.data.first)

        #expect(entry.costUSD == nil)
        #expect(entry.modelBreakdowns?.first?.costUSD == nil)
        #expect(entry.unpricedRequestCount == 3)
        #expect(entry.pricedRequestCount == nil)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(report.summary?.totalTokens == Self.report(cache, day: day).summary?.totalTokens)
    }

    /// Fully priced groups keep their existing result, including their day-level coverage fields.
    @Test
    func `a fully priced model day is unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        _ = try Self.writeSession(env: env, day: day, id: "priced", model: "gpt-5.4")
        let entry = try #require(Self.report(Self.scannedCache(day: day, env: env), day: day).data.first)

        // 100K and 200K requests at the standard rate; 300K crosses the long-context threshold.
        #expect(abs((entry.costUSD ?? -1) - 2.25) < 1e-9)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.pricedRequestCount == nil)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 1))
    }

    /// Priced Priority requests keep their Fast rate in a partial subtotal, but the group has no mode split
    /// because the unknown request's tier is unproven.
    @Test
    func `a partial subtotal keeps priority pricing without a mode split`() throws {
        let day = Date(timeIntervalSince1970: 1_789_560_000)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let rows = [
            Self.row(day: range.sinceKey, index: 0, input: 100_000, pricingMode: "priority"),
            Self.row(day: range.sinceKey, index: 1, input: 50000, pricingMode: "priority", marked: true),
        ]
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: Self.cache(rows: rows, day: range.sinceKey, packed: [150_000, 0, 20]),
            range: range,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let entry = try #require(report.data.first)
        let breakdown = try #require(entry.modelBreakdowns?.first)
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.4",
            inputTokens: 100_000,
            outputTokens: 10))

        #expect(abs((entry.costUSD ?? -1) - priorityCost) < 1e-12)
        #expect(breakdown.standardCostUSD == nil)
        #expect(breakdown.priorityCostUSD == nil)
        #expect(breakdown.priorityTokens == nil)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 1)
    }

    /// Rows that do not account for the canonical tokens (for example fork-inflated rows) prove nothing about the
    /// group, so a marker there keeps the whole group unknown instead of reporting a row subtotal.
    @Test
    func `rows that exceed the canonical totals keep a marked group unpriced`() throws {
        let day = Date(timeIntervalSince1970: 1_789_560_000)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let rows = [
            Self.row(day: range.sinceKey, index: 0, input: 100_000, pricingMode: "standard"),
            Self.row(day: range.sinceKey, index: 1, input: 100_000, pricingMode: "standard", marked: true),
        ]
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: Self.cache(rows: rows, day: range.sinceKey, packed: [150_000, 0, 20]),
            range: range,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let entry = try #require(report.data.first)

        #expect(entry.costUSD == nil)
        #expect(entry.modelBreakdowns?.first?.costUSD == nil)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == nil)
    }

    private static func row(
        day: String,
        index: Int,
        input: Int,
        pricingMode: String,
        marked: Bool = false) -> CostUsageScanner.CodexUsageRow
    {
        CostUsageScanner.CodexUsageRow(
            day: day,
            model: "gpt-5.4",
            turnID: "turn-\(index)",
            eventIndex: index,
            input: input,
            cached: 0,
            output: 10,
            unpricedTokens: marked ? input + 10 : nil,
            pricingModel: "gpt-5.4",
            pricingMode: pricingMode)
    }

    private static func cache(rows: [CostUsageScanner.CodexUsageRow], day: String, packed: [Int]) -> CostUsageCache {
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [day: ["gpt-5.4": packed]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/partial-pricing.jsonl": usage]
        cache.days = usage.days
        return cache
    }

    private static func writeSession(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        model: String,
        inputs: [Int] = [100_000, 200_000, 300_000]) throws -> URL
    {
        let timestamp = env.isoString(for: day)
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": id]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "\(id)-turn"]],
        ]
        for input in inputs {
            records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]],
            ]])
        }
        return try env.writeCodexSessionFile(day: day, filename: "\(id).jsonl", contents: env.jsonl(records))
    }

    private static func scannedCache(day: Date, env: CostUsageTestEnvironment) throws -> CostUsageCache {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        return CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
    }

    /// Marks rows as retained history whose pricing could not be recovered, as source recovery stores them.
    private static func marking(_ cache: CostUsageCache, path: String, rows marked: Set<Int>) throws -> CostUsageCache {
        var cache = cache
        var usage = try #require(cache.files[path])
        usage.codexRows = usage.codexRows?.enumerated().map { index, row in
            var row = row
            if marked.contains(index) { row.unpricedTokens = row.input + row.output }
            return row
        }
        cache.files[path] = usage
        return cache
    }

    private static func report(_ cache: CostUsageCache, day: Date) -> CostUsageDailyReport {
        CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: .init(since: day, until: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
    }
}

import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeOverflowTests {
    @Test
    func `raw rows retain overflowing groups and independent token totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let nextDay = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        let rows = [
            self.row(input: 1 << 62, output: 2),
            self.row(input: 1 << 62, output: 3),
            self.row(input: 1, output: 4),
            self.row(input: 10, output: 5, model: "fixture/other"),
            self.row(input: 20, output: 6, day: "2026-07-02"),
        ]
        var cache = CostUsageCache()
        cache.files["fixture.jsonl"] = CostUsageFileUsage(mtimeUnixMs: 0, size: 0, days: [:], claudeRows: rows)
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: nextDay),
            now: day,
            modelsDevCacheRoot: env.cacheRoot)
        let entry = try #require(report.data.first)
        #expect(entry.modelsUsed == ["fixture/other", "fixture/overflow"])
        #expect(entry.inputTokens == nil)
        #expect(entry.outputTokens == 14)
        #expect(entry.totalTokens == nil)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "fixture/overflow" }?.totalTokens == nil)
        #expect(report.summary?.totalInputTokens == nil)
        #expect(report.summary?.totalOutputTokens == 20)
        #expect(report.summary?.cacheReadTokens == 0)
        #expect(report.summary?.totalTokens == nil)
        #expect(report.summary?.totalCostUSD == 5)
        _ = try JSONEncoder().encode(report)
    }

    @Test
    func `a combined total overflow does not hide representable components`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        var cache = CostUsageCache()
        cache.days["2026-07-01"] = ["fixture/overflow": [Int.max, 0, 0, 7, 0, 1, 0, 0]]
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            now: day,
            modelsDevCacheRoot: env.cacheRoot)
        #expect(report.summary?.totalTokens == nil)
        #expect(report.summary?.totalInputTokens == Int.max)
        #expect(report.summary?.totalOutputTokens == 7)
        #expect(report.summary?.cacheReadTokens == 0)
    }

    @Test(arguments: [false, true])
    func `missing legacy rows retain packed totals while complete empty rows are authoritative`(
        complete: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        var cache = CostUsageCache()
        cache.days["2026-07-01"] = ["fixture/overflow": [30, 0, 0, 3, 0, 2, 0, 0]]
        cache.files["known"] = CostUsageFileUsage(
            mtimeUnixMs: 0, size: 0, days: [:], claudeRows: [self.row(input: 10, output: 1)])
        cache.files["legacy"] = CostUsageFileUsage(
            mtimeUnixMs: 0, size: 0, days: [:], claudeRows: complete ? [] : nil)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache, range: range, now: day, modelsDevCacheRoot: env.cacheRoot)
        #expect(report.summary?.totalTokens == (complete ? 11 : 33))
        #expect(report.summary?.totalInputTokens == (complete ? 10 : 30))
        #expect(report.summary?.totalOutputTokens == (complete ? 1 : 3))
        #expect(report.summary?.totalCostUSD == (complete ? 1 : nil))
        if complete {
            cache.files["known"]?.claudeRows = []
            let empty = CostUsageScanner.buildClaudeReportFromCache(
                cache: cache, range: range, now: day, modelsDevCacheRoot: env.cacheRoot)
            #expect(empty.data.isEmpty)
            #expect(empty.summary == nil)
        }
    }

    @Test
    func `transcript aggregation preserves overflowing rows through reload and later contributions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let nextDay = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        let model = "fixture/overflow"
        var incomplete = self.event(env: env, day: day, input: 1, output: 0, model: model)
        var message = try #require(incomplete["message"] as? [String: Any])
        message["stop_reason"] = NSNull()
        incomplete["message"] = message
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl([
            self.event(env: env, day: day, input: 1 << 62, output: 2, model: model),
            self.event(env: env, day: day, input: 1 << 62, output: 3, model: model),
            self.event(env: env, day: day, input: 7, output: 4, model: model),
            incomplete,
            self.event(env: env, day: day, input: 11, output: 5, model: "fixture/other"),
            self.event(env: env, day: nextDay, input: 13, output: 6, model: model),
        ]))
        let report = try self.load(env: env, since: day, until: nextDay)
        #expect(report.data.count == 2)
        let entry = try #require(report.data.first)
        #expect(entry.inputTokens == nil)
        #expect(entry.outputTokens == 14)
        #expect(entry.totalTokens == nil)
        #expect(entry.modelsUsed == ["fixture/other", model])
        #expect(entry.modelBreakdowns?.first { $0.modelName == model }?.incompleteRequestCount == 1)
        #expect(entry.modelBreakdowns?.first { $0.modelName == "fixture/other" }?.totalTokens == 16)
        #expect(entry.unpricedRequestCount == 4)
        #expect(report.data.last?.totalTokens == 19)
        #expect(report.summary?.totalInputTokens == nil)
        #expect(report.summary?.totalOutputTokens == 20)
        #expect(report.summary?.totalTokens == nil)

        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cache.usage.files.values.flatMap { $0.claudeRows ?? [] }.count == 6)
        #expect(cache.usage.days["2026-07-01"]?[model] == nil)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        CostUsageScanner.evictPersistedClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let reloaded = try self.load(env: env, since: day, until: nextDay)
        #expect(reloaded.data == report.data)
        #expect(reloaded.summary == report.summary)
        #expect(reloaded.hourly == report.hourly)
        #expect(reloaded.quotaSlices == report.quotaSlices)
        _ = try JSONEncoder().encode(reloaded)
    }

    @Test(arguments: [false, true])
    func `finite dollars survive row and packed nanodollar overflow`(packedOverflow: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let input = packedOverflow ? 2_000_000_000_000_000 : 1 << 62
        let count = packedOverflow ? 2 : 1
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl(
            (0..<count).map { _ in
                self.event(env: env, day: day, input: input, output: 0, model: "claude-sonnet-4-6")
            }))
        let report = try self.load(env: env, since: day, until: day)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        let rows = cache.usage.files.values.flatMap { $0.claudeRows ?? [] }
        #expect(rows.count == count)
        #expect(rows.allSatisfy { $0.costPriced == packedOverflow })
        #expect(rows.allSatisfy { packedOverflow ? $0.costNanos > 0 : $0.costNanos == 0 })
        #expect(report.summary?.totalInputTokens == input * count)
        #expect(report.summary?.totalTokens == input * count)
        let cost = try #require(report.summary?.totalCostUSD)
        let expected = Double(input) * Double(count) * 3e-6
        #expect(abs(cost - expected) <= expected * 1e-12)
        _ = try JSONEncoder().encode(report)
    }

    @Test
    func `nonfinite computed prices remain unavailable in encodable reports`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let model = "claude-test-extreme-price"
        let catalog = try CostUsageClaudeResolverTests.simpleCatalog([model: 1e308])
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl([
            self.event(env: env, day: day, input: 1 << 62, output: 0, model: model),
        ]))
        let report = try self.load(env: env, since: day, until: day)
        #expect(report.summary?.totalTokens == 1 << 62)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(report.data.first?.modelBreakdowns?.first?.costUSD == nil)
        _ = try JSONEncoder().encode(report)
    }

    private func load(env: CostUsageTestEnvironment, since: Date, until: Date) throws -> CostUsageDailyReport {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: options,
            checkCancellation: nil)
    }

    private func event(
        env: CostUsageTestEnvironment, day: Date, input: Int, output: Int, model: String) -> [String: Any]
    {
        ["type": "assistant", "timestamp": env.isoString(for: day), "message": [
            "model": model, "usage": ["input_tokens": input, "output_tokens": output],
        ]]
    }

    private func row(
        input: Int,
        output: Int,
        day: String = "2026-07-01",
        model: String = "fixture/overflow") -> CostUsageScanner.ClaudeUsageRow
    {
        CostUsageScanner.ClaudeUsageRow(
            dayKey: day,
            model: model,
            sessionId: nil,
            messageId: nil,
            requestId: nil,
            timestampUnixMs: nil,
            isSidechain: false,
            pathRole: .parent,
            input: input,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: 0,
            output: output,
            costNanos: 1_000_000_000,
            costPriced: true)
    }
}

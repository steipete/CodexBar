import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostReliabilityTests {
    @Test
    func `explicit zero token usage remains measured zero in reports and snapshots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        _ = try env.writePiSessionFile(
            relativePath: "zero.jsonl",
            contents: env.jsonl([self.row(env, day, id: "zero", input: 0)]))
        let result = try self.scan(day, options: options)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 0)
        #expect(result.report.data.first?.totalTokens == 0)
        #expect(result.report.data.first?.modelBreakdowns?.first?.totalTokens == 0)
        #expect(result.report.data.first?.requestCount == 1)
        let snapshot = CostUsageFetcher.tokenSnapshot(from: result.report, now: day, historyDays: 1)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.last30DaysTokens == 0)
    }

    @Test(arguments: [false, true])
    func `atomic replacement reparses the prefix even when metadata matches or the file grows`(
        grows: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        let first = try env.jsonl([self.row(env, day, id: "first", input: 10, output: 5)])
        let replacement = try env.jsonl([self.row(env, day, id: "first", input: 90, output: 5)])
        #expect(first.utf8.count == replacement.utf8.count)
        let file = try env.writePiSessionFile(relativePath: "replacement.jsonl", contents: first)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        #expect(try self.scan(day, options: options).report.summary?.totalTokens == 15)
        let oldIdentity = try #require(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
            .files.values.first?.fileIdentity)
        let suffix = grows ? try env.jsonl([self.row(env, day, id: "second", input: 20, output: 10)]) : ""
        try (replacement + suffix).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let cachedReplacement = PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot,
            options: options)
        #expect(cachedReplacement?.isComplete == false)
        #expect(cachedReplacement?.report.summary?.totalTokens == 15)

        let warmed = try self.scan(day.addingTimeInterval(1), options: options)
        #expect(warmed.isComplete)
        #expect(warmed.report.summary?.totalTokens == (grows ? 125 : 95))
        let newIdentity = try #require(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
            .files.values.first?.fileIdentity)
        #expect(newIdentity != oldIdentity)
        var forcedOptions = options
        forcedOptions.forceRescan = true
        #expect(try self.scan(day, options: forcedOptions).report.data == warmed.report.data)
    }

    @Test
    func `missing file identity rejects hydration and bypasses the fresh cache debounce`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        var options = try self.options(env)
        options.refreshMinIntervalSeconds = 3600
        let file = try env.writePiSessionFile(
            relativePath: "migration.jsonl",
            contents: env.jsonl([self.row(env, day, id: "first", input: 10)]))
        #expect(try self.scan(day, options: options).isComplete)
        var cache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        for path in cache.files.keys {
            cache.files[path]?.fileIdentity = nil
        }
        PiSessionCostCacheIO.save(cache: cache, cacheRoot: env.cacheRoot)
        #expect(PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .pi,
            since: day,
            until: day,
            cacheRoot: env.cacheRoot,
            options: options) == nil)
        try env.jsonl([self.row(env, day, id: "first", input: 90)])
            .write(to: file, atomically: true, encoding: .utf8)
        let rebuilt = try self.scan(day.addingTimeInterval(1), options: options)
        #expect(rebuilt.isComplete)
        #expect(rebuilt.report.summary?.totalTokens == 90)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).files.values
            .allSatisfy { $0.fileIdentity != nil })
    }

    @Test
    func `narrow cache reads validate the full stored inventory and unscoped reads stay unverified`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let oldDay = day.addingTimeInterval(-90 * 86400)
        let options = try self.options(env)
        let oldFile = try env.writePiSessionFile(
            relativePath: "old.jsonl",
            contents: env.jsonl([self.row(env, oldDay, id: "old", input: 20)]))
        try FileManager.default.setAttributes([.modificationDate: oldDay], ofItemAtPath: oldFile.path)
        _ = try env.writePiSessionFile(
            relativePath: "current.jsonl",
            contents: env.jsonl([self.row(env, day, id: "current", input: 10)]))
        #expect(try self.scan(day, since: oldDay, options: options).report.summary?.totalTokens == 30)
        let narrow = PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot,
            options: options)
        #expect(narrow?.isComplete == true)
        #expect(narrow?.report.summary?.totalTokens == 10)
        try FileManager.default.moveItem(at: env.piSessionsRoot, to: env.root.appendingPathComponent("offline"))
        let unverified = PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot)
        #expect(unverified?.isComplete == false)
        #expect(unverified?.report.summary?.totalTokens == 10)
        #expect(unverified?.lastScanAt == day)
    }

    @Test(arguments: [false, true])
    func `unsupported backends stay incomplete across cached reads and recover after a growing rewrite`(
        mixed: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        var rows = [self.row(env, day, id: "unsupported", input: 30, provider: "openrouter")]
        if mixed { rows.append(self.row(env, day, id: "supported", input: 10)) }
        let path = try env.writePiSessionFile(relativePath: "coverage.jsonl", contents: env.jsonl(rows))
        let first = try self.scan(day, options: options)
        #expect(!first.isComplete)
        #expect(first.report.summary?.totalTokens == (mixed ? 10 : nil))
        #expect(first.lastScanAt == day)
        #expect(PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot,
            options: options,
            allowEstablishedEmpty: true) == nil)
        let native = try self.scan(day, options: options, provider: .codex)
        #expect(native.isComplete)
        #expect(native.report.summary?.totalTokens == (mixed ? 10 : nil))

        rows[0] = self.row(env, day, id: "unsupported", input: 30)
        rows.append(self.row(env, day, id: "appended", input: 7))
        try env.jsonl(rows).write(to: path, atomically: true, encoding: .utf8)
        let restored = try self.scan(day.addingTimeInterval(1), options: options)
        #expect(restored.isComplete)
        #expect(restored.report.summary?.totalTokens == (mixed ? 47 : 37))
    }

    @Test
    func `unsupported model change context survives an append without poisoning native partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        let change: [String: Any] = ["type": "model_change", "provider": "google", "modelId": "gemini-2.5-pro"]
        let message: [String: Any] = [
            "type": "message", "timestamp": env.isoString(for: day),
            "message": ["role": "assistant", "usage": ["input": 10, "output": 1]],
        ]
        let file = try env.writePiSessionFile(relativePath: "context.jsonl", contents: env.jsonl([change, message]))
        #expect(try !self.scan(day, options: options).isComplete)
        try self.append(env.jsonl([message]), to: file)
        #expect(try !self.scan(day.addingTimeInterval(1), options: options).isComplete)
        #expect(try self.scan(day, options: options, provider: .claude).isComplete)
    }

    @Test(arguments: [UsageProvider.pi, .claude])
    func `mixed pricing keeps known subtotal and explicit unpriced coverage`(provider: UsageProvider) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        _ = try env.writePiSessionFile(relativePath: "pricing.jsonl", contents: env.jsonl([
            self.row(env, day, id: "priced", input: 100, provider: "anthropic", model: "claude-sonnet-4-6"),
            self.row(env, day, id: "unknown", input: 100, provider: "anthropic", model: "fictional-unpriced-model"),
        ]))
        let result = try self.scan(day, options: options, provider: provider)
        let entry = try #require(result.report.data.first)
        #expect(entry.totalTokens == 200)
        #expect((entry.costUSD ?? 0) > 0)
        #expect(entry.coverageCounts.estimated == 1)
        #expect(entry.coverageCounts.unpriced == 1)
        #expect(entry.coverageCounts.priced == 0)
        let cached = try #require(PiSessionCostScanner.loadCachedDailyReportResult(
            provider: provider,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot,
            options: options))
        #expect(cached.report.data == result.report.data)
    }

    @Test
    func `an unrepresentable monetary amount retains valid tokens as unpriced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        _ = try env.writePiSessionFile(relativePath: "money.jsonl", contents: env.jsonl([
            self.row(env, day, id: "large", input: 10_000_000_000_000_000),
        ]))
        let result = try self.scan(day, options: options)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 10_000_000_000_000_000)
        #expect(result.report.summary?.totalCostUSD == nil)
        #expect(result.report.data.first?.coverageCounts.unpriced == 1)
    }

    @Test(arguments: ["row", "money", "model", "day", "boolean"])
    func `invalid numeric appends retain the previous cache and its original age`(failure: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        let large = 1 << 62
        let firstInput = failure == "money" ? 1_000_000_000_000_000 : failure == "row" || failure == "boolean" ? 5 :
            large
        let model = failure == "money" || failure == "row" || failure == "boolean" ? "gpt-5.4" : "fictional-unpriced-a"
        let file = try env.writePiSessionFile(relativePath: "append.jsonl", contents: env.jsonl([
            self.row(env, day, id: "first", input: firstInput, model: model),
        ]))
        let first = try self.scan(day, options: options)
        #expect(first.isComplete)
        let cacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let saved = try Data(contentsOf: cacheURL)
        let nextDay = failure == "day" ? day.addingTimeInterval(86400) : day
        let badInput: Any = failure == "boolean" ? true : failure == "row" ? large : firstInput
        try self.append(env.jsonl([self.row(
            env,
            nextDay,
            id: "second",
            input: badInput,
            output: failure == "row" ? large : 0,
            model: failure == "model" ? "fictional-unpriced-b" : model)]), to: file)
        let failed = try self.scan(nextDay, since: day, options: options)
        #expect(!failed.isComplete)
        #expect(failed.report.summary == first.report.summary)
        #expect(failed.lastScanAt == first.lastScanAt)
        #expect(try Data(contentsOf: cacheURL) == saved)
    }

    private func options(_ env: CostUsageTestEnvironment) throws -> PiSessionCostScanner.Options {
        let omp = env.root.appendingPathComponent("empty-omp")
        try FileManager.default.createDirectory(at: omp, withIntermediateDirectories: true)
        return .init(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: omp,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
    }

    private func scan(
        _ day: Date,
        since: Date? = nil,
        options: PiSessionCostScanner.Options,
        provider: UsageProvider = .pi) throws -> PiSessionCostScanner.DailyReportResult
    {
        try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: provider,
            since: since ?? day,
            until: day,
            now: day,
            options: options,
            checkCancellation: nil)
    }

    private func row(
        _ env: CostUsageTestEnvironment,
        _ day: Date,
        id: String,
        input: Any,
        output: Int = 0,
        provider: String = "openai-codex",
        model: String = "gpt-5.4") -> [String: Any]
    {
        [
            "type": "message",
            "id": id,
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": provider,
                "model": model,
                "usage": ["input": input, "output": output],
            ],
        ]
    }

    private func append(_ contents: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data(contents.utf8))
    }
}

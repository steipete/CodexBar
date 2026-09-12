import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerClaudePricingMemoTests {
    @Test(arguments: [40, 80])
    func `full append and report parsing share two model lookups across files`(rowsPerFile: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let known = "claude-test-known"
        let unknown = "claude-test-unknown"
        try self.save([known: 10], day: day, env: env)
        var files: [URL] = []
        for file in 0..<3 {
            let events = (0..<rowsPerFile).map { index in
                self.event(
                    day: day,
                    env: env,
                    id: "\(file)-\(index)",
                    model: index.isMultiple(of: 2) ? known : unknown,
                    input: index + 1)
            }
            try files.append(env.writeClaudeProjectFile(
                relativePath: "project/\(file).jsonl", contents: env.jsonl(events)))
        }
        let (cold, work, reads) = try self.load(env: env, day: day)
        #expect(work.transcriptParses == 3)
        #expect(work.repricedRows == 3 * rowsPerFile)
        #expect(work.normalizationCacheMisses == 2)
        #expect(work.catalogModelLookups == 2)
        #expect(work.catalogModelHits == 1)
        #expect(work.catalogModelMisses == 1)
        #expect(reads == 1)
        let (warm, warmWork, warmReads) = try self.load(env: env, day: day)
        #expect(warm.data == cold.data)
        #expect(warm.summary == cold.summary)
        #expect(warmWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(warmReads == 0)

        for (index, file) in files.enumerated() {
            let content = try env.jsonl([
                self.event(day: day, env: env, id: "append-known-\(index)", model: known, input: 7),
                self.event(day: day, env: env, id: "append-unknown-\(index)", model: unknown, input: 9),
            ])
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
            try handle.close()
        }
        let (appended, appendWork, appendReads) = try self.load(env: env, day: day)
        #expect(appended.summary?.totalInputTokens == (cold.summary?.totalInputTokens ?? 0) + 48)
        #expect(appendWork.transcriptParses == 3)
        #expect(appendWork.repricedRows == 3 * rowsPerFile + 6)
        #expect(appendWork.normalizationCacheMisses == 2)
        #expect(appendWork.catalogModelLookups == 2)
        #expect(appendWork.catalogModelHits == 1)
        #expect(appendWork.catalogModelMisses == 1)
        #expect(appendReads == 1)

        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let cacheData = try Data(contentsOf: cacheURL)
        let cacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let sourceStamps = files.map { CostUsageClaudeFileStamp.read(at: $0) }
        let sourceData = try files.map { try Data(contentsOf: $0) }
        try self.save([known: 20, unknown: 30], day: day, env: env)
        let (repriced, repriceWork, repriceReads) = try self.load(env: env, day: day)
        #expect(repriced.summary?.totalTokens == appended.summary?.totalTokens)
        #expect(repriced.summary?.totalCostUSD != appended.summary?.totalCostUSD)
        #expect(repriceWork.transcriptParses == 0)
        #expect(repriceWork.cacheEncodes == 0)
        #expect(repriceWork.repricedRows == 3 * rowsPerFile + 6)
        #expect(repriceWork.catalogModelLookups == 2)
        #expect(repriceWork.catalogModelHits == 2)
        #expect(repriceWork.catalogModelMisses == 0)
        #expect(repriceWork.normalizationCacheMisses == 2)
        #expect(repriceReads == 1)
        #expect(try Data(contentsOf: cacheURL) == cacheData)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
        #expect(files.map { CostUsageClaudeFileStamp.read(at: $0) } == sourceStamps)
        #expect(try files.map { try Data(contentsOf: $0) } == sourceData)
        let (repricedWarm, lastWork, lastReads) = try self.load(env: env, day: day)
        #expect(repricedWarm.data == repriced.data)
        #expect(repricedWarm.summary == repriced.summary)
        #expect(lastWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(lastReads == 0)
    }

    @Test(arguments: ["empty", "nonqualifying", "historical"])
    func `catalog preparation retains empty and historical loading boundaries`(kind: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        if kind == "nonqualifying" {
            _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: "{\"type\":\"user\"}\n")
        } else if kind == "historical" {
            _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl([
                self.event(day: day, env: env, id: "historical", model: "claude-sonnet-4-6", input: 210_000),
            ]))
        }
        let (_, work, reads) = try self.load(env: env, day: day)
        #expect(reads == (kind == "empty" ? 0 : 1))
        #expect(work.transcriptParses == (kind == "empty" ? 0 : 1))
        #expect(work.catalogModelLookups == 0)
        #expect(work.repricedRows == (kind == "historical" ? 1 : 0))
        let (_, warmWork, warmReads) = try self.load(env: env, day: day)
        #expect(warmWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(warmReads == 0)
    }

    @Test(arguments: ["missing", "corrupt", "unsupported"])
    func `unavailable catalog has one snapshot and caches negative models`(kind: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        if kind != "missing" {
            let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let content = kind == "corrupt" ? "corrupt fixture" :
                #"{"version":-1,"fetchedAt":0,"catalog":{"providers":{}}}"#
            try Data(content.utf8).write(to: url)
        }
        for index in 0..<2 {
            _ = try env.writeClaudeProjectFile(relativePath: "project/\(index).jsonl", contents: env.jsonl([
                self.event(day: day, env: env, id: "a-\(index)", model: "claude-test-absent-a", input: 10),
                self.event(day: day, env: env, id: "b-\(index)", model: "claude-test-absent-b", input: 20),
            ]))
        }
        let (report, work, reads) = try self.load(env: env, day: day)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(reads == 1)
        #expect(work.catalogModelLookups == 2)
        #expect(work.catalogModelHits == 0)
        #expect(work.catalogModelMisses == 2)
        #expect(work.repricedRows == 4)
        try self.save(["claude-test-absent-a": 10], day: day, env: env)
        let (retried, retriedWork, retriedReads) = try self.load(env: env, day: day)
        #expect(retried.summary?.totalCostUSD != nil)
        #expect(retriedWork.catalogModelHits == 1)
        #expect(retriedWork.catalogModelMisses == 1)
        #expect(retriedWork.transcriptParses == 0)
        #expect(retriedReads == 1)
    }

    @Test
    func `report repricing preserves known zero persisted fallback and newly priced rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let models = ["claude-test-zero", "claude-test-known", "claude-test-unknown"]
        try self.save([models[0]: 0, models[1]: 10], day: day, env: env)
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl(
            models.map { self.event(day: day, env: env, id: $0, model: $0, input: 100) }))
        _ = try self.load(env: env, day: day)
        try self.save([models[0]: 90, models[2]: 30], day: day, env: env)
        let (report, work, _) = try self.load(env: env, day: day)
        let breakdown = try #require(report.data.first?.modelBreakdowns)
        #expect(breakdown.first { $0.modelName == models[0] }?.costUSD == 0)
        #expect(breakdown.first { $0.modelName == models[1] }?.costUSD == 0.001)
        #expect(breakdown.first { $0.modelName == models[2] }?.costUSD == 0.003)
        #expect(report.summary?.totalCostUSD == 0.004)
        #expect(work.catalogModelHits == 2)
        #expect(work.catalogModelMisses == 1)
        #expect(work.repricedRows == 3)
        #expect(work.transcriptParses == 0)
        #expect(work.cacheEncodes == 0)
    }

    @Test
    func `pricing replacement after report construction cannot publish a stale report memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let model = "claude-test-known"
        try self.save([model: 10], day: day, env: env)
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl([
            self.event(day: day, env: env, id: "first", model: model, input: 100),
        ]))
        _ = try self.load(env: env, day: day)
        try self.save([model: 20], day: day, env: env)
        let replacement = try CostUsageClaudeResolverTests.simpleCatalog([model: 30])
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        var replaced = false
        let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
            try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude,
                since: day,
                until: day,
                now: day,
                options: self.options(env: env),
                checkCancellation: {
                    if !replaced, work.snapshot().repricedRows > 0 {
                        #expect(ModelsDevCache.save(catalog: replacement, fetchedAt: day, cacheRoot: env.cacheRoot))
                        replaced = true
                    }
                })
        }
        #expect(replaced)
        #expect(report.summary?.totalCostUSD == 0.002)
        let (fresh, freshWork, _) = try self.load(env: env, day: day)
        #expect(fresh.summary?.totalCostUSD == 0.003)
        #expect(freshWork.repricedRows == 1)
        #expect(freshWork.catalogModelLookups == 1)
        #expect(freshWork.transcriptParses == 0)
    }

    private func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func load(env: CostUsageTestEnvironment, day: Date) throws
        -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics, Int)
    {
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        let reads = ModelsDevCache.MetadataReadRecorder()
        let report = try ModelsDevCache.withMetadataReadRecorderForTesting(reads) {
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
                try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: day,
                    until: day,
                    now: day,
                    options: self.options(env: env),
                    checkCancellation: nil)
            }
        }
        return (report, work.snapshot(), reads.snapshot())
    }

    private func save(_ rates: [String: Double], day: Date, env: CostUsageTestEnvironment) throws {
        #expect(try ModelsDevCache.save(
            catalog: CostUsageClaudeResolverTests.simpleCatalog(rates), fetchedAt: day, cacheRoot: env.cacheRoot))
    }

    private func event(
        day: Date,
        env: CostUsageTestEnvironment,
        id: String,
        model: String,
        input: Int) -> [String: Any]
    {
        [
            "type": "assistant", "timestamp": env.isoString(for: day), "requestId": id,
            "message": ["id": id, "model": model, "usage": ["input_tokens": input, "output_tokens": 0]],
        ]
    }
}

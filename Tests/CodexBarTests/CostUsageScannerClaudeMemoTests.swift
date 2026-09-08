import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerClaudeMemoTests {
    @Test(arguments: [false, true])
    func `atomic transcript replacement discards prior rows in warm and cold processes`(cold: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "old", input: 1000)
        let options = self.options(env: env)
        #expect(self.load(day: day, options: options).summary?.totalInputTokens == 1000)
        let original = try #require(CostUsageClaudeFileStamp.read(at: file))
        var first = self.event(env: env, day: day, id: "replacement-first", input: 7)
        first["fixturePadding"] = String(repeating: "x", count: Int(original.size) + 32)
        let replacement = try env.jsonl([first, self.event(env: env, day: day, id: "replacement-last", input: 17)])
        try Data(replacement.utf8).write(to: file, options: .atomic)
        let changed = try #require(CostUsageClaudeFileStamp.read(at: file))
        #expect(changed.fileID != original.fileID)
        #expect(changed.size > original.size)
        if cold {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        }

        let (normal, work) = self.recordedLoad(day: day, options: options)
        #expect(work.incrementalTranscriptParses == 0)
        var forced = options
        forced.forceRescan = true
        let oracle = self.load(day: day, options: forced)
        #expect(oracle.summary?.totalInputTokens == 24)
        #expect(normal.data == oracle.data)
        #expect(normal.summary == oracle.summary)
    }

    @Test(arguments: [false, true])
    func `replacement with unchanged size and modification time is still reparsed`(cold: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "same", input: 1000)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let original = try #require(CostUsageClaudeFileStamp.read(at: file))
        let replacement = try env.jsonl([self.event(env: env, day: day, id: "same", input: 2000)])
        try Data(replacement.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: file.path)
        let changed = try #require(CostUsageClaudeFileStamp.read(at: file))
        #expect(changed.fileID != original.fileID)
        #expect(changed.size == original.size)
        #expect(changed.mtimeUnixMs == original.mtimeUnixMs)
        if cold {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        }

        let (report, work) = self.recordedLoad(day: day, options: options)
        #expect(report.summary?.totalInputTokens == 2000)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
    }

    @Test
    func `cache identities round trip with empty parsed rows and prune removed files`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try env.writeClaudeProjectFile(relativePath: "project/empty.jsonl", contents: "{}\n")
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let artifact = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        let path = try #require(artifact.usage.files.keys.first)
        #expect(artifact.usage.files[path]?.claudeRows == [])
        #expect(artifact.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(self.recordedLoad(day: day, options: options).1.transcriptParses == 0)
        try FileManager.default.removeItem(at: file)
        _ = self.load(day: day, options: options)
        let pruned = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(pruned.usage.files.isEmpty)
        #expect(pruned.sourceFileIDs.isEmpty)
    }

    @Test
    func `legacy cache without file identity is rebuilt once before append reuse`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "same", input: 10)
        var options = self.options(env: env)
        options.refreshMinIntervalSeconds = 60
        _ = self.load(day: day, options: options)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cache.usage.files.count == 1)
        let path = try #require(cache.usage.files.keys.first)
        #expect(cache.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        cache.sourceFileIDs[path] = nil
        let legacyData = try JSONEncoder().encode(cache.usage)
        try legacyData.write(to: CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot))
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)

        let (report, work) = self.recordedLoad(day: day, options: options)
        #expect(report.summary?.totalInputTokens == 10)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        let refreshed = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(refreshed.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(self.recordedLoad(day: day, options: options).1.transcriptParses == 0)
    }

    @Test
    func `identical warm refresh only inventories sources`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let cacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)

        let (warm, metrics) = self.recordedLoad(day: day, options: options)

        #expect(warm.data == initial.data)
        #expect(warm.summary == initial.summary)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
    }

    @Test
    func `cold process reuses unchanged files from the persisted cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/first.jsonl", id: "first", input: 10)
        _ = try self.writeEvent(env: env, day: day, path: "project/second.jsonl", id: "second", input: 20)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)

        let (restarted, metrics) = self.recordedLoad(day: day, options: options)

        #expect(restarted.data == initial.data)
        #expect(restarted.summary == initial.summary)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
    }

    @Test
    func `nested source addition invalidates the memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/nested/deeper/session.jsonl",
            id: "nested",
            input: 20)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 30)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `source append invalidates the memo and parses the delta`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 3)
        let fileURL = try self.writeEvent(
            env: env,
            day: day,
            path: "project/session.jsonl",
            id: "first",
            input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let appended = try env.jsonl([self.event(env: env, day: day, id: "second", input: 20)])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 30)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.incrementalTranscriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `individual source deletion invalidates the memo and removes its rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 4)
        let deletedURL = try self.writeEvent(
            env: env,
            day: day,
            path: "project/deleted.jsonl",
            id: "deleted",
            input: 10)
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/retained.jsonl",
            id: "retained",
            input: 20)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        try FileManager.default.removeItem(at: deletedURL)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 20)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `missing source root invalidates the memo and deletes cached rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 4)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        try FileManager.default.removeItem(at: env.claudeProjectsRoot)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.data.isEmpty)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `external atomic cache replacement invalidates the memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 5)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let originalStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        let cacheData = try Data(contentsOf: cacheURL)
        try cacheData.write(to: cacheURL, options: [.atomic])
        let replacementStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        #expect(replacementStamp.fileID != originalStamp.fileID)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.data == initial.data)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `force rescan bypasses an exact memo hit`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 6)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var options = self.options(env: env)
        _ = self.load(day: day, options: options)
        options.forceRescan = true

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 10)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
        #expect(metrics.repricedRows == 1)
    }

    @Test
    func `pricing replacement reprices without parsing or rewriting the claude cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 7)
        let model = "claude-test-memo-pricing"
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/session.jsonl",
            id: "first",
            input: 100,
            model: model)
        #expect(try ModelsDevCache.save(
            catalog: self.catalog(model: model, inputRate: 10),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let options = self.options(env: env)
        let first = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let cacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        #expect(abs((first.summary?.totalCostUSD ?? 0) - 0.001) < 0.000000001)
        #expect(try ModelsDevCache.save(
            catalog: self.catalog(model: model, inputRate: 20),
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))

        let (repriced, metrics) = self.recordedLoad(day: day, options: options)

        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - 0.002) < 0.000000001)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 0)
        #expect(metrics.repricedRows == 1)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
    }

    @Test
    func `timezone change invalidates the memo and rebuilds the cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 8)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var options = self.options(env: env, calendar: utc)
        _ = self.load(day: day, options: options)
        var shifted = Calendar(identifier: .gregorian)
        shifted.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        options.calendar = shifted

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 10)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `cancellation preserves disk and the prior memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 9)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let diskBefore = try Data(contentsOf: cacheURL)
        let stampBefore = CostUsageClaudeFileStamp.read(at: cacheURL)
        options.forceRescan = true
        var checks = 0

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options,
                checkCancellation: {
                    checks += 1
                    if checks == 4 {
                        throw CancellationError()
                    }
                })
        }
        #expect(try Data(contentsOf: cacheURL) == diskBefore)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == stampBefore)

        options.forceRescan = false
        let (_, metrics) = self.recordedLoad(day: day, options: options)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    private func options(
        env: CostUsageTestEnvironment,
        calendar: Calendar = .current) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func load(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    private func recordedLoad(
        day: Date,
        options: CostUsageScanner.Options) -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
    {
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            self.load(day: day, options: options)
        }
        return (report, recorder.snapshot())
    }

    private func writeEvent(
        env: CostUsageTestEnvironment,
        day: Date,
        path: String,
        id: String,
        input: Int,
        model: String = "claude-sonnet-4-20250514") throws -> URL
    {
        try env.writeClaudeProjectFile(
            relativePath: path,
            contents: env.jsonl([self.event(env: env, day: day, id: id, input: input, model: model)]))
    }

    private func event(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        input: Int,
        model: String = "claude-sonnet-4-20250514") -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "session-\(id)",
            "requestId": "request-\(id)",
            "message": [
                "id": "message-\(id)",
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
        ]
    }

    private func catalog(model: String, inputRate: Double) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": { "input": \(inputRate), "output": 1 }
              }
            }
          }
        }
        """.utf8))
    }

    private func cacheURL(env: CostUsageTestEnvironment) -> URL {
        CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
    }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

/// Regression gates for the two cost-usage scan-storm classes that have shipped before:
/// re-parsing unchanged session files on every refresh (#1387, #1392) and re-running the
/// full trace-database scan on every refresh (#1392, the pre-memo priority-turns path).
@Suite(.serialized)
struct CostUsagePerformanceGateTests {
    @Test
    func `warm codex refresh over an unchanged session corpus must not re-parse it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let fileURLs = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 2, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let changedFile = try #require(fileURLs.first)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: changedFile.path)
        let originalModificationDate = try #require(originalAttributes[.modificationDate] as? Date)
        let original = try String(contentsOf: changedFile, encoding: .utf8)
        let modified = original.replacingOccurrences(
            of: #""input_tokens":100,"#,
            with: #""input_tokens":900,"#)
        #expect(modified != original)
        #expect(modified.utf8.count == original.utf8.count)
        try modified.write(to: changedFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: changedFile.path)

        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(cold.data.count == 1)
        #expect(warm.data.first?.totalTokens == cold.data.first?.totalTokens)
    }

    @Test
    func `priority turns refresh must scan only appended trace rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)

        let epoch: Int64 = 1_760_000_000
        var rows: [(epochSeconds: Int64, body: String)] = (0..<50).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        let full = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(full.keys.sorted() == ["turn-a"])
        let scanned = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        try Self.replaceTraceBody(
            dbURL: dbURL,
            rowID: 1,
            body: "thread_id=mutated turn.id=mutated-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)])

        let refreshed = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(refreshed.keys.sorted() == ["turn-a", "turn-b"])
        let advanced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
    }

    @Test
    func `cached daily report resolves and uses the pricing catalog once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let model = "perf-custom-model"
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 3,
            turnsPerFile: 4,
            model: model)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let catalogJSON = """
        {
          "openai": {
            "id": "openai",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": { "input": 10, "output": 50, "cache_read": 1 }
              }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogJSON.utf8))
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let cachedUsage = try #require(cache.files.values.first { !($0.codexRows?.isEmpty ?? true) })
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(!CostUsageScanner.needsCodexCostCache(cachedUsage, range: range))
        var catalogLoadCount = 0
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return catalog
            })

        #expect(report.summary?.totalCostUSD != nil)
        #expect(catalogLoadCount == 1)
    }

    @Test
    func `cached daily report uses complete aggregates without loading pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        var catalogLoadCount = 0
        let cached = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return ModelsDevCatalog(providers: [:])
            })

        #expect(cached.data.map(\.totalTokens) == scanned.data.map(\.totalTokens))
        #expect(cached.summary?.totalTokens == scanned.summary?.totalTokens)
        #expect(abs((cached.summary?.totalCostUSD ?? 0) - (scanned.summary?.totalCostUSD ?? 0)) < 0.000000001)
        #expect(catalogLoadCount == 0)
    }

    @Test
    func `legacy missing aggregate cost backfills rows before threshold pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 2,
            turnsPerFile: 1,
            model: "openai/gpt-5.5",
            inputTokensPerTurn: 200_000)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var legacy = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        for path in legacy.files.keys {
            legacy.files[path]?.codexCostCacheComplete = nil
            legacy.files[path]?.codexCostNanos = nil
            legacy.files[path]?.codexStandardCostNanos = nil
            legacy.files[path]?.codexPriorityCostNanos = nil
        }
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(legacy.files.values.allSatisfy { CostUsageScanner.needsCodexCostCache($0, range: range) })

        let backfilled = CostUsageScanner.buildCodexReportFromCache(cache: legacy, range: range)

        #expect(abs((backfilled.summary?.totalCostUSD ?? 0) - (scanned.summary?.totalCostUSD ?? 0)) < 0.000000001)

        var mixed = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let mixedPaths = mixed.files.keys.sorted()
        let legacyPath = try #require(mixedPaths.first)
        let rowlessPath = try #require(mixedPaths.last)
        #expect(legacyPath != rowlessPath)
        mixed.files[legacyPath]?.codexCostCacheComplete = nil
        mixed.files[legacyPath]?.codexCostNanos = nil
        mixed.files[legacyPath]?.codexStandardCostNanos = nil
        mixed.files[legacyPath]?.codexPriorityCostNanos = nil
        mixed.files[rowlessPath]?.codexRows = nil

        let mixedBackfilled = CostUsageScanner.buildCodexReportFromCache(cache: mixed, range: range)
        #expect(abs((mixedBackfilled.summary?.totalCostUSD ?? 0) - (scanned.summary?.totalCostUSD ?? 0)) < 0.000000001)

        let aggregateCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 400_000,
            cachedInputTokens: 0,
            outputTokens: 20)
        #expect(abs((backfilled.summary?.totalCostUSD ?? 0) - (aggregateCost ?? 0)) > 0.1)
    }

    @Test
    func `project rollups resolve the pricing catalog once per build`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        var catalogLoadCount = 0
        let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return ModelsDevCatalog(providers: [:])
            })

        #expect(!projects.isEmpty)
        #expect(catalogLoadCount == 1)
    }

    private static func writeSyntheticCodexCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        files: Int,
        turnsPerFile: Int,
        model: String = "openai/gpt-5.2-codex",
        inputTokensPerTurn: Int = 100) throws -> [URL]
    {
        let baseISO = env.isoString(for: day)
        var fileURLs: [URL] = []
        for fileIndex in 0..<files {
            var lines: [String] = []
            lines.reserveCapacity(turnsPerFile + 2)
            lines.append(
                #"{"type":"session_meta","timestamp":"\#(baseISO)","payload":{"session_id":"perf-\#(fileIndex)"}}"#)
            lines.append(
                #"{"type":"turn_context","timestamp":"\#(baseISO)","payload":{"model":"\#(model)"}}"#)
            for turn in 1...turnsPerFile {
                let inputTokens = turn * inputTokensPerTurn
                lines.append(
                    #"{"type":"event_msg","timestamp":"\#(baseISO)","payload":{"type":"token_count","info":"#
                        + #"{"total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(turn * 20),"#
                        + #""output_tokens":\#(turn * 10)},"model":"\#(model)"}}}"#)
            }
            let fileURL = try env.writeCodexSessionFile(
                day: day,
                filename: "session-\(fileIndex).jsonl",
                contents: lines.joined(separator: "\n") + "\n")
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private static func replaceTraceBody(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif

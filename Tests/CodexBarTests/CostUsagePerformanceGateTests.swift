import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

// This suite intentionally keeps the scanner's related performance regression gates together.
// swiftlint:disable file_length

/// Regression gates for the two cost-usage scan-storm classes that have shipped before:
/// re-parsing unchanged session files on every refresh (#1387, #1392) and re-running the
/// full trace-database scan on every refresh (#1392, the pre-memo priority-turns path).
@Suite(.serialized)
struct CostUsagePerformanceGateTests {
    @Test
    func `warm cache reuses unchanged files and rejects a same-metadata rewrite`() throws {
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

        let unchangedWarm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(cold.data.count == 1)
        #expect(unchangedWarm.data == cold.data)
        #expect(unchangedWarm.summary == cold.summary)

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

        let rewrittenWarm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)

        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("rewrite-control-cache")
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: controlOptions)

        #expect(rewrittenWarm.data == control.data)
        #expect(rewrittenWarm.summary == control.summary)
        #expect(rewrittenWarm.data != cold.data)
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
        let cachedUsage = try #require(cache.files.values.first {
            ($0.codexUsageRowSidecarState?.rowCount ?? 0) > 0 || !($0.codexRows?.isEmpty ?? true)
        })
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
            var usage = try #require(legacy.files[path])
            usage.codexRows = try CodexPublishedUsageRowsTestSupport.load(
                path: path,
                usage: usage,
                cacheRoot: env.cacheRoot)
            usage.codexUsageRowSidecarState = nil
            usage.codexCostCacheComplete = nil
            usage.codexCostNanos = nil
            usage.codexStandardCostNanos = nil
            usage.codexPriorityCostNanos = nil
            legacy.files[path] = usage
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
        var legacyUsage = try #require(mixed.files[legacyPath])
        legacyUsage.codexRows = try CodexPublishedUsageRowsTestSupport.load(
            path: legacyPath,
            usage: legacyUsage,
            cacheRoot: env.cacheRoot)
        legacyUsage.codexUsageRowSidecarState = nil
        legacyUsage.codexCostCacheComplete = nil
        legacyUsage.codexCostNanos = nil
        legacyUsage.codexStandardCostNanos = nil
        legacyUsage.codexPriorityCostNanos = nil
        mixed.files[legacyPath] = legacyUsage
        mixed.files[rowlessPath]?.codexRows = nil
        mixed.files[rowlessPath]?.codexUsageRowSidecarState = nil
        mixed.files[rowlessPath]?.codexTurnIDs = nil

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

    @Test
    func `oversized codex session is fully accounted across bounded refreshes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let oversizedURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: oversizedURL)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: max(1, metadata.size / 4),
            maxCodexScanBytesPerRefresh: max(1, metadata.size / 4))
        options.refreshMinIntervalSeconds = 0

        var offsets: [Int64] = []
        var report: CostUsageDailyReport?
        for _ in 0..<12 {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
            let cached = try #require(CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: env.cacheRoot).files.values.first)
            offsets.append(cached.parsedBytes ?? 0)
            if cached.codexScanComplete == true {
                break
            }
        }

        #expect(offsets.count > 1)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(offsets.last == metadata.size)
        #expect(report?.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(report?.data.map(\.totalTokens) == baseline.data.map(\.totalTokens))
    }

    @Test
    func `oversized codex progress survives cache round trip`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, metadata.size / 4)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh += Self.codexLookbackDiscoveryWork(options: options)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cacheData = try Data(contentsOf: CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot))
        let roundTripped = try JSONDecoder().decode(CostUsageCache.self, from: cacheData)
        let first = try #require(roundTripped.files.values.first)
        let firstOffset = try #require(first.parsedBytes)
        #expect(first.codexScanFileId == metadata.fileId)
        #expect(first.codexScanTargetSize == metadata.size)
        #expect(first.codexScanComplete == false)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let second = try #require(CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot).files.values.first)
        #expect((second.parsedBytes ?? 0) > firstOffset)
        #expect(second.codexScanFileId == metadata.fileId)
        #expect(second.codexScanTargetSize == metadata.size)
    }

    @Test
    func `oversized codex progress survives an append while catch-up is in progress`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, originalMetadata.size / 4)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh += Self.codexLookbackDiscoveryWork(options: options)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let first = try #require(CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot).files.values.first)
        #expect(first.parsedBytes == slice)
        #expect(first.codexScanComplete == false)

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        try (original + String(repeating: " ", count: 512)).write(to: fileURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: fileURL.path)
        let changedMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(changedMetadata.size != originalMetadata.size)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let resumed = try #require(CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot).files.values.first)
        #expect((resumed.parsedBytes ?? 0) > (first.parsedBytes ?? 0))
        #expect(resumed.parsedBytes == min(changedMetadata.size, (first.parsedBytes ?? 0) + slice))
        #expect(resumed.codexScanTargetSize == changedMetadata.size)
        #expect(resumed.codexScanFileId == changedMetadata.fileId)
        #expect(resumed.codexScanComplete == false)
    }

    @Test
    func `catch-up API continuously advances bounded slices to the exact full result`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, metadata.size / 4)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let fetcher = CostUsageFetcher(scannerOptions: options)
        var status = await fetcher.codexScanCatchUpStatus()
        #expect(status.pending)
        var progressKeys = [status.progressKey]
        for _ in 0..<12 where status.pending {
            status = try await fetcher.advanceCodexScanCatchUp(now: day, historyDays: 1)
            progressKeys.append(status.progressKey)
        }

        let completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let completedUsage = try #require(completedCache.files.values.first)
        let completedReport = CostUsageScanner.buildCodexReportFromCache(
            cache: completedCache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        #expect(!status.pending)
        #expect(completedUsage.codexScanComplete == true)
        #expect(completedUsage.parsedBytes == metadata.size)
        #expect(zip(progressKeys, progressKeys.dropFirst()).allSatisfy(!=))
        #expect(completedReport.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(completedReport.data.map(\.totalTokens) == baseline.data.map(\.totalTokens))
    }

    @Test
    func `incompatible populated cache stays visible until bounded fork rebuild converges`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.2-codex"

        let parentBody = ([
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"upgrade-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"\#(model)"}}}"#,
        ] + Array(repeating: "x", count: 4096)).joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "upgrade-parent.jsonl",
            contents: parentBody)
        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"upgrade-child","#
                + #""forked_from_id":"upgrade-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"\#(model)"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "upgrade-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: childURL.path)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("upgrade-baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 1024,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0
        let range = CostUsageScanner.CostUsageDayRange(
            since: day,
            until: day,
            calendar: options.calendar)
        let priorScanAt = day.addingTimeInterval(-3600)
        var priorCache = CostUsageCache()
        priorCache.lastScanUnixMs = Int64(priorScanAt.timeIntervalSince1970 * 1000)
        priorCache.scanSinceKey = range.scanSinceKey
        priorCache.scanUntilKey = range.scanUntilKey
        priorCache.timeZoneIdentifier = options.calendar.timeZone.identifier
        priorCache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        priorCache.days = [
            range.sinceKey: [CostUsagePricing.normalizeCodexModel(model): [777, 0, 0]],
        ]
        CostUsageCacheIO.save(
            provider: .codex,
            cache: priorCache,
            cacheRoot: env.cacheRoot,
            producerKey: "codex:cu:pupgrade-fixture")

        let priorReport = CostUsageScanner.buildCodexReportFromCache(
            cache: priorCache,
            range: range)
        var report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let fetcher = CostUsageFetcher(scannerOptions: options)
        var status = await fetcher.codexScanCatchUpStatus()

        #expect(status.pending)
        #expect(status.staleSnapshotUpdatedAt == priorScanAt)
        #expect(report.data == priorReport.data)
        #expect(report.summary == priorReport.summary)
        #expect(CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot).codexPreviousReport != nil)

        for pass in 1...16 where status.pending {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            status = await fetcher.codexScanCatchUpStatus()
            if status.pending {
                #expect(report.data == priorReport.data)
                #expect(report.summary == priorReport.summary)
                #expect(status.staleSnapshotUpdatedAt == priorScanAt)
            }
        }

        let completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(!status.pending)
        #expect(status.staleSnapshotUpdatedAt == nil)
        #expect(completedCache.codexPreviousReport == nil)
        #expect(report.data == baseline.data)
        #expect(report.summary == baseline.summary)
    }

    @Test
    func `single oversized jsonl record resumes without stalling`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let model = "openai/gpt-5.2-codex"
        let contents = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"long-record"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","padding":""#
                + String(repeating: "x", count: 4096)
                +
                #"","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"#
                + #""output_tokens":25},"model":"\#(model)"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "long-record.jsonl", contents: contents)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 256,
            maxCodexScanBytesPerRefresh: 256)
        options.refreshMinIntervalSeconds = 0

        var offsets: [Int64] = []
        var sawPartialRecord = false
        var report: CostUsageDailyReport?
        for _ in 0..<24 {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
            let cached = try #require(CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: env.cacheRoot).files.values.first)
            offsets.append(cached.parsedBytes ?? 0)
            sawPartialRecord = sawPartialRecord || cached.codexJSONLResumeState != nil
            if cached.codexScanComplete == true {
                break
            }
        }

        #expect(sawPartialRecord)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(report?.summary?.totalTokens == baseline.summary?.totalTokens)
    }

    @Test
    func `codex scan budget never admits more than its remaining allowance`() {
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 100, maxBytesPerRefresh: 150)
        guard case let .allow(first) = budget.admit(workBytes: 1000) else {
            Issue.record("expected first bounded admission")
            return
        }
        #expect(first == 100)
        budget.consume(workBytes: first)

        guard case let .allow(second) = budget.admit(workBytes: 1000) else {
            Issue.record("expected remaining-budget admission")
            return
        }
        #expect(second == 50)
        budget.consume(workBytes: second)
        guard case .deferBudget = budget.admit(workBytes: 1) else {
            Issue.record("expected exhausted budget to defer")
            return
        }
        #expect(budget.bytesConsumed == 150)
    }

    @Test
    func `codex scan budget distinguishes file body work from metadata probes`() {
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 100, maxBytesPerRefresh: 100)
        guard case let .allow(metadataAllowance) = budget.admit(workBytes: 10) else {
            Issue.record("expected metadata admission")
            return
        }
        budget.complete(admittedWorkBytes: metadataAllowance, actualWorkBytes: 1)

        guard case let .allow(bodyAllowance) = budget.admit(workBytes: 50) else {
            Issue.record("expected body admission")
            return
        }
        budget.consumeFileBody(workBytes: bodyAllowance)

        #expect(budget.bytesConsumed == 51)
        #expect(budget.fileBodyBudgetBytesConsumed == 50)
    }

    @Test
    func `codex scan budget yields after its wall clock deadline`() {
        let clock = TestMonotonicClock()
        let budget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 100,
            maxBytesPerRefresh: 150,
            maxDuration: 2,
            now: { clock.now() })
        guard case let .allow(first) = budget.admit(workBytes: 100) else {
            Issue.record("expected work before the deadline to be admitted")
            return
        }
        budget.consume(workBytes: first)

        clock.advance(by: .seconds(3))
        #expect(budget.shouldYield(additionalBytes: 0))
        #expect(budget.deferredByTimeBudgetFileCount == 1)
        #expect(budget.shouldYield(additionalBytes: 0))
        #expect(budget.deferredByTimeBudgetFileCount == 1)
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero

    func now() -> ContinuousClock.Instant {
        self.lock.withLock {
            self.origin.advanced(by: self.offset)
        }
    }

    func advance(by duration: Duration) {
        self.lock.withLock {
            self.offset += duration
        }
    }
}

extension CostUsagePerformanceGateTests {
    @Test
    func `missing parent head discovery resumes inside the scan budget`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let body = #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"known-session","cwd":"#
            + String(repeating: "x", count: 512)
            + #""}}"#
            + "\n"
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "budgeted-head.jsonl", contents: body)

        var discovery: CostUsageCodexSessionDiscovery?
        var offsets: [Int64] = []
        var resolvedMissing = false
        for _ in 0..<32 {
            let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 32, maxBytesPerRefresh: 32)
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [fileURL],
                roots: [env.codexSessionsRoot],
                cachedDiscovery: discovery,
                scanBudget: budget)
            switch try index.lookup(sessionId: "absent-session") {
            case .found:
                Issue.record("unexpected parent resolution")
            case .missing:
                resolvedMissing = true
            case .deferred:
                break
            }
            discovery = index.persistedState
            if let offset = discovery?.headScan?.resumeState?.offset ?? discovery?.headScan?.offset {
                offsets.append(offset)
            }
            if resolvedMissing {
                break
            }
        }

        #expect(offsets.count >= 2)
        #expect(offsets[1] > offsets[0])
        #expect(resolvedMissing)
        #expect(discovery?.missingSessionIds.contains("absent-session") == true)
    }

    @Test
    func `missing fork parent stays idle then publishes buffered usage once when created`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 250,
            turnsPerFile: 0)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"missing-child","#
                + #""forked_from_id":"late-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":150,"cached_input_tokens":15,"output_tokens":8},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "missing-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(600)],
            ofItemAtPath: childURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let coldCounter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            coldCounter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
        }
        let coldCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let coldChild = try #require(coldCache.files.values.first { $0.sessionId == "missing-child" })
        let coldDiscovery = try #require(coldCache.codexSessionDiscovery)
        // The ordinary files were already parsed earlier in this refresh, so their authoritative
        // session IDs and file stamps must satisfy the missing-parent inventory without reopening
        // all 250 heads a second time.
        #expect(coldCounter.value == 0)
        #expect(coldChild.days.isEmpty)
        #expect(coldChild.codexForkTimestamp == forkISO)
        #expect(coldChild.forkBaselineDependencyKey?.contains("missing|late-parent|discovery|") == true)
        #expect(coldChild.parsedBytes == 0)
        #expect(coldChild.codexDeferredForkScan == true)
        #expect(coldChild.codexBufferedUnresolvedForkLines == nil)
        #expect(coldChild.codexTokenSnapshots == nil)
        #expect(coldChild.codexTokenCheckpoints == nil)
        #expect(!coldChild.hasRetryableBufferedCodexFork)
        #expect(coldDiscovery.missingSessionIds.contains("late-parent"))
        #expect(coldCache.codexScanCatchUpPending == false)
        #expect(coldCache.codexScanCompletedFiles == coldCache.codexScanTotalFiles)

        let warmCounter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            warmCounter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
        }
        #expect(warmCounter.value == 0)
        let warmCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot)
        let warmChild = try #require(warmCache.files.values.first { $0.sessionId == "missing-child" })
        #expect(warmCache.codexScanCatchUpPending == false)
        #expect(warmChild.parsedBytes == coldChild.parsedBytes)
        #expect(warmChild.codexTokenIndexAnchor == coldChild.codexTokenIndexAnchor)
        #expect(warmChild.codexDeferredForkScan == true)
        #expect(warmChild.codexBufferedUnresolvedForkLines == nil)

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"late-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "late-parent.jsonl", contents: parentBody)

        let resolved = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let resolvedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let resolvedChild = try #require(resolvedCache.files.values.first { $0.sessionId == "missing-child" })
        #expect(!resolvedChild.days.isEmpty)
        #expect(resolvedChild.forkBaselineDependencyKey?.hasPrefix("file|late-parent|") == true)
        #expect(resolvedChild.codexDeferredForkScan != true)
        #expect(resolvedChild.codexBufferedUnresolvedForkLines == nil)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let stableCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let stableChild = try #require(stableCache.files.values.first { $0.sessionId == "missing-child" })
        #expect(stableChild.days == resolvedChild.days)
        #expect(stable.summary?.totalTokens == resolved.summary?.totalTokens)
    }

    @Test
    func `partition inventory change rotates negative lookup generation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 20, turnsPerFile: 0)
        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"inventory-child","#
                + #""forked_from_id":"inventory-missing"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":10,"cached_input_tokens":1,"output_tokens":1}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "inventory-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(600)],
            ofItemAtPath: childURL.path)

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
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstGeneration = try #require(firstCache.codexSessionDiscovery?.generation)
        #expect(firstCache.codexSessionDiscovery?.missingSessionIds.contains("inventory-missing") == true)

        let newFile = try env.writeCodexSessionFile(
            day: day,
            filename: "inventory-new.jsonl",
            contents: #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"new-session"}}"#
                + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(300)],
            ofItemAtPath: newFile.path)
        let counter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            counter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
        }
        let changedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let changedGeneration = try #require(changedCache.codexSessionDiscovery?.generation)
        #expect(changedGeneration != firstGeneration)
        #expect(changedCache.codexSessionDiscovery?.missingSessionIds.contains("inventory-missing") == true)
        #expect(counter.value <= 1)
    }

    @Test
    func `stable missing parent discovers session metadata appended in place`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let childDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: parentDay)
        let forkISO = env.isoString(for: parentDay.addingTimeInterval(1))
        let childISO = env.isoString(for: childDay)
        let parentURL = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "in-place-parent.jsonl",
            contents: #"{"type":"response_item","payload":{"text":"placeholder"}}"# + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: parentDay],
            ofItemAtPath: parentURL.path)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(childISO)","payload":{"session_id":"in-place-child","#
                + #""forked_from_id":"in-place-parent","timestamp":"\#(forkISO)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":150,"cached_input_tokens":15,"output_tokens":8},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "in-place-child.jsonl",
            contents: childBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)
        let coldCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let coldChild = try #require(coldCache.files.values.first { $0.sessionId == "in-place-child" })
        let coldDiscovery = try #require(coldCache.codexSessionDiscovery)
        let parentPath = parentURL.standardizedFileURL.path
        #expect(coldChild.days.isEmpty)
        #expect(coldChild.forkBaselineDependencyKey?.contains("missing|in-place-parent|discovery|") == true)
        #expect(coldChild.codexDeferredForkScan == true)
        #expect(coldDiscovery.fileStamps[parentPath] != nil)
        #expect(!coldDiscovery.filePathBySessionId.values.contains(parentPath))

        let parentDirectory = parentURL.deletingLastPathComponent()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: parentDirectory.path)
        let directoryModificationDate = try #require(directoryAttributes[.modificationDate] as? Date)
        let directoryMtimeUnixMs = CostUsageScanner.codexFileMetadata(fileURL: parentDirectory).mtimeUnixMs
        let appendedParentBody = [
            #"{"type":"session_meta","timestamp":"\#(parentISO)","payload":{"session_id":"in-place-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        let parentHandle = try FileHandle(forWritingTo: parentURL)
        try parentHandle.seekToEnd()
        try parentHandle.write(contentsOf: Data(appendedParentBody.utf8))
        try parentHandle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: parentDay.addingTimeInterval(60)],
            ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: directoryModificationDate],
            ofItemAtPath: parentDirectory.path)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: parentDirectory).mtimeUnixMs == directoryMtimeUnixMs)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay.addingTimeInterval(1),
            options: options)
        let resolvedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let resolvedChild = try #require(
            resolvedCache.files.values.first { $0.sessionId == "in-place-child" })
        let childModels = try #require(
            resolvedChild.days[CostUsageScanner.CostUsageDayRange.dayKey(from: childDay)])

        #expect(resolvedCache.codexSessionDiscovery?.filePathBySessionId["in-place-parent"] == parentPath)
        #expect(childModels[CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")] == [50, 5, 3])
        #expect(resolvedChild.forkBaselineDependencyKey?.hasPrefix("file|in-place-parent|") == true)
        #expect(resolvedChild.codexDeferredForkScan != true)
        #expect(resolvedCache.codexScanCatchUpPending == false)
    }

    @Test
    func `completed active lookback yields an exact tiny budget to pending session`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 1)
        let fileURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let lookbackWork = Self.codexLookbackDiscoveryWork(options: options)
        #expect(lookbackWork > 0)
        options.maxCodexSessionFileBytes = lookbackWork
        options.maxCodexScanBytesPerRefresh = lookbackWork

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstLookback = try #require(firstCache.codexActiveLookbackState)
        let firstParsedBytes = firstCache.files.values.first?.parsedBytes ?? 0
        #expect(Set(firstLookback.completedRootPaths) == Set(firstLookback.rootPaths))
        #expect(firstParsedBytes == 0)
        #expect(firstCache.codexScanCatchUpPending == true)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        var completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let secondUsage = try #require(completedCache.files.values.first)
        #expect((secondUsage.parsedBytes ?? 0) > firstParsedBytes)

        for pass in 2..<64 where completedCache.codexScanCatchUpPending == true {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        }

        let completedUsage = try #require(completedCache.files.values.first)
        let completedModels = try #require(
            completedUsage.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        #expect(completedUsage.parsedBytes == metadata.size)
        #expect(completedUsage.codexScanComplete == true)
        #expect(completedModels[CostUsagePricing.normalizeCodexModel("openai/gpt-5.2-codex")] == [100, 20, 10])
        #expect(completedCache.codexActiveLookbackState == nil)
        #expect(completedCache.codexScanCatchUpPending == false)
    }

    @Test
    func `sparse token checkpoints preserve the exact accumulator state`() {
        let mebibyte: Int64 = 1024 * 1024
        let events = [
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:00:00Z",
                last: .init(input: 100, cached: 10, output: 5),
                total: .init(input: 100, cached: 10, output: 5),
                endOffset: 1 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:01:00Z",
                last: .init(input: 100, cached: 10, output: 5),
                total: .init(input: 200, cached: 20, output: 10),
                endOffset: 5 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:02:00Z",
                last: .init(input: 10, cached: 1, output: 1),
                total: .init(input: 150, cached: 15, output: 8),
                endOffset: 6 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:03:00Z",
                last: .init(input: 70, cached: 7, output: 2),
                total: .init(input: 220, cached: 22, output: 12),
                endOffset: 10 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:04:00Z",
                last: .init(input: 10, cached: 1, output: 1),
                total: .init(input: 230, cached: 23, output: 13),
                endOffset: 10 * mebibyte + 1),
        ]

        let checkpoints = CostUsageScanner.codexTokenCheckpoints(for: events)
        #expect(checkpoints.map(\.eventIndex) == [1, 3, 4])

        for checkpoint in checkpoints {
            var accumulator = CostUsageScanner.CodexSnapshotAccumulator()
            for event in events[...checkpoint.eventIndex] {
                _ = accumulator.apply(last: event.last, total: event.total)
            }
            #expect(checkpoint.state == accumulator.state)
        }
    }

    @Test
    func `per refresh byte budget defers later dirty files`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let urls = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 3)
        // Make deterministic order by newest-first: touch later files later.
        let older = try #require(urls.first)
        let middle = try #require(urls.dropFirst().first)
        let newer = try #require(urls.last)
        let olderDate = day.addingTimeInterval(-3600)
        let middleDate = day.addingTimeInterval(-1800)
        let newerDate = day
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: middleDate], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.path)

        let newestMeta = CostUsageScanner.codexFileMetadata(fileURL: newer)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 64 * 1024 * 1024,
            // Enough for the newest file only; remaining dirty files defer.
            maxCodexScanBytesPerRefresh: max(1, newestMeta.size),
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let cachedNames = Set(cache.files.keys.map { URL(fileURLWithPath: $0).lastPathComponent })

        #expect(cachedNames.contains(newer.lastPathComponent))
        #expect(!cachedNames.contains(older.lastPathComponent))
    }

    @Test
    func `pending work bytes treat fork files as full rescan work`() {
        let metadata = CostUsageScanner.CodexFileMetadata(
            path: "/tmp/forked.jsonl",
            mtimeUnixMs: 2,
            size: 1000,
            fileId: "1:2")
        let cached = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 400,
            days: [:],
            parsedBytes: 400,
            forkedFromId: "parent-session")
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(metadata: metadata, cached: cached) == 1000)
    }

    @Test
    func `pending work bytes charge full file for forced rescans of unchanged cache entries`() {
        let metadata = CostUsageScanner.CodexFileMetadata(
            path: "/tmp/unchanged.jsonl",
            mtimeUnixMs: 42,
            size: 2_000_000_000,
            fileId: "9:9")
        let cached = CostUsageFileUsage(
            mtimeUnixMs: 42,
            size: 2_000_000_000,
            days: ["2026-05-10": ["gpt-5.2-codex": [100, 20, 10]]],
            parsedBytes: 2_000_000_000,
            sessionId: "session-unchanged")
        // keepCached can still reject this (forceFullScan / priority / fork dependency).
        // Budget must not report zero pending work or multi-GB forced rescans slip through.
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(metadata: metadata, cached: cached) == 2_000_000_000)
    }

    @Test
    func `bounded parent reaches EOF across JSON reloads and matches unbounded child totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let parentTotalISO = env.isoString(for: day.addingTimeInterval(1))
        let forkISO = env.isoString(for: day.addingTimeInterval(2))

        // Parent is intentionally larger than the per-file budget.
        let parentBody = ([
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-giant"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(parentTotalISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":3},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ] + Array(repeating: "x", count: 4096)).joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "parent-giant.jsonl", contents: parentBody)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"child-small","#
                + #""forked_from_id":"parent-giant"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(day: day, filename: "child-small.jsonl", contents: childBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024)
        options.refreshMinIntervalSeconds = 0

        let unboundedCacheRoot = env.root.appendingPathComponent("unbounded-cache", isDirectory: true)
        var unboundedOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: unboundedCacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        unboundedOptions.refreshMinIntervalSeconds = 0
        var unboundedCache = CostUsageCache()
        for pass in 0..<8 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: unboundedOptions)
            unboundedCache = CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: unboundedCacheRoot)
            if unboundedCache.codexScanCatchUpPending != true { break }
        }
        let unboundedParent = try #require(
            unboundedCache.files.values.first { $0.sessionId == "parent-giant" })
        let unboundedChild = try #require(
            unboundedCache.files.values.first { $0.sessionId == "child-small" })
        #expect(unboundedParent.codexScanComplete == true)
        #expect(unboundedChild.days.isEmpty == false)

        let started = Date()
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let elapsed = Date().timeIntervalSince(started)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstParent = try #require(firstCache.files.values.first { $0.sessionId == "parent-giant" })
        let firstChild = try #require(firstCache.files.values.first { $0.sessionId == "child-small" })

        #expect(elapsed < 2.0)
        #expect(firstCache.files.keys.contains {
            URL(fileURLWithPath: $0).lastPathComponent == childURL.lastPathComponent
        })
        #expect(firstChild.days.isEmpty)
        #expect(firstChild.forkBaselineDependencyKey == nil)
        #expect(firstChild.hasRetryableBufferedCodexFork)
        #expect(firstChild.codexDeferredForkScan == true)
        #expect(firstChild.codexBufferedUnresolvedForkLines == nil)
        #expect(firstParent.codexScanComplete == false)
        #expect(firstParent.codexTokenSnapshots == nil)
        #expect(firstParent.codexTokenCheckpoints == nil)
        #expect(firstParent.codexTokenSidecarState?.eventCount == 2)
        #expect(firstParent.codexTokenIndexAnchor != nil)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let secondCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let parent = try #require(secondCache.files.values.first { $0.sessionId == "parent-giant" })
        let child = try #require(secondCache.files.values.first { $0.sessionId == "child-small" })

        #expect(parent.codexScanComplete == false)
        #expect(parent.codexTokenSnapshots == nil)
        #expect(parent.codexTokenCheckpoints == nil)
        #expect(parent.codexTokenSidecarState?.eventCount == 2)
        #expect(child.days.isEmpty)
        #expect(child.forkBaselineDependencyKey == nil)
        #expect(child.codexDeferredForkScan == true)

        var completedCache = secondCache
        for pass in 2..<32 where completedCache.codexScanCatchUpPending == true {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        }
        let completedParent = try #require(
            completedCache.files.values.first { $0.sessionId == "parent-giant" })
        let completedChild = try #require(
            completedCache.files.values.first { $0.sessionId == "child-small" })
        let completedChildDay = try #require(
            completedChild.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        let completedChildTokens = try #require(
            completedChildDay[CostUsagePricing.normalizeCodexModel("openai/gpt-5.2-codex")])

        #expect(completedParent.codexScanComplete == true)
        #expect(completedParent.codexTokenSnapshots == nil)
        #expect(completedParent.codexTokenCheckpoints == nil)
        #expect(completedParent.codexTokenSidecarState?.eventCount == 2)
        #expect(completedChildTokens == [80, 5, 2])
        #expect(completedChild.days == unboundedChild.days)
        #expect(completedChild.forkBaselineDependencyKey != nil)
        #expect(completedChild.codexDeferredForkScan != true)
        #expect(completedCache.codexScanCatchUpPending == false)
    }

    @Test
    func `ready parent lets a bounded ordinary fork resume monotonically across cache reloads`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let childISO = env.isoString(for: day.addingTimeInterval(2))

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(parentISO)","payload":{"session_id":"resume-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "00-resume-parent.jsonl",
            contents: parentBody)

        var boundedOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024,
            preferNewestCodexSessionsFirst: false)
        boundedOptions.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: boundedOptions)
        let parentCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let parent = try #require(parentCache.files.values.first { $0.sessionId == "resume-parent" })
        #expect(parent.codexScanComplete == true)

        let padding = String(repeating: "x", count: 360)
        let childBody = ([
            #"{"type":"session_meta","timestamp":"\#(childISO)","payload":{"session_id":"resume-child","#
                + #""forked_from_id":"resume-parent","timestamp":"\#(forkISO)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ] + (0..<14).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        } + [
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":180,"cached_input_tokens":15,"output_tokens":8},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ]).joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-resume-child.jsonl",
            contents: childBody)
        let childSize = CostUsageScanner.codexFileMetadata(fileURL: childURL).size
        #expect(childSize > 3 * boundedOptions.maxCodexSessionFileBytes)

        var controlOptions = boundedOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("unbounded-cache", isDirectory: true)
        controlOptions.maxCodexSessionFileBytes = 0
        controlOptions.maxCodexScanBytesPerRefresh = 0
        let controlReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: controlOptions)
        let controlCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: controlOptions.cacheRoot)
        let controlChild = try #require(controlCache.files.values.first { $0.sessionId == "resume-child" })
        #expect(controlChild.codexScanComplete == true)

        var offsets: [Int64] = []
        var finalReport: CostUsageDailyReport?
        var completedCache = parentCache
        for pass in 1..<24 {
            finalReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: boundedOptions)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let child = try #require(completedCache.files.values.first { $0.sessionId == "resume-child" })
            let parsedBytes = try #require(child.parsedBytes)
            if let previous = offsets.last {
                #expect(parsedBytes > previous)
            }
            offsets.append(parsedBytes)
            #expect(parsedBytes > 0)
            #expect(child.codexDeferredForkScan != true)
            #expect(child.forkBaselineDependencyKey != nil)
            #expect(child.codexForkAccountingState != nil)
            if child.codexScanComplete == true { break }
        }

        // Reaching this file's EOF can leave unrelated active-lookback bookkeeping to settle on
        // the next warm pass. That pass must not rescan or move the completed child cursor.
        for pass in 24..<28 where completedCache.codexScanCatchUpPending == true {
            finalReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: boundedOptions)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let settledChild = try #require(
                completedCache.files.values.first { $0.sessionId == "resume-child" })
            #expect(settledChild.parsedBytes == childSize)
        }

        let completedChild = try #require(
            completedCache.files.values.first { $0.sessionId == "resume-child" })
        let boundedReport = try #require(finalReport)
        #expect(offsets.count >= 4)
        #expect(completedChild.parsedBytes == childSize)
        #expect(completedChild.codexScanComplete == true)
        #expect(completedChild.days == controlChild.days)
        #expect(boundedReport.data == controlReport.data)
        #expect(boundedReport.summary == controlReport.summary)
        #expect(completedCache.codexScanCatchUpPending == false)
    }

    @Test
    func `transient parent lookup during ordinary fork suffix does not publish its cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let childISO = env.isoString(for: day.addingTimeInterval(2))

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(parentISO)","payload":{"session_id":"race-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "00-race-parent.jsonl",
            contents: parentBody)

        var boundedOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024,
            preferNewestCodexSessionsFirst: false)
        boundedOptions.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: boundedOptions)

        let padding = String(repeating: "x", count: 380)
        let childBody = ([
            #"{"type":"session_meta","timestamp":"\#(childISO)","payload":{"session_id":"race-child","#
                + #""forked_from_id":"race-parent","timestamp":"\#(forkISO)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ] + (0..<12).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        } + [
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":175,"cached_input_tokens":16,"output_tokens":9},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ]).joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-race-child.jsonl",
            contents: childBody)
        let childSize = CostUsageScanner.codexFileMetadata(fileURL: childURL).size
        #expect(childSize > 3 * boundedOptions.maxCodexSessionFileBytes)

        var controlOptions = boundedOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("race-control-cache", isDirectory: true)
        controlOptions.maxCodexSessionFileBytes = 0
        controlOptions.maxCodexScanBytesPerRefresh = 0
        let controlReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: controlOptions)
        let controlCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: controlOptions.cacheRoot)
        let controlChild = try #require(controlCache.files.values.first { $0.sessionId == "race-child" })

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: boundedOptions)
        let beforeCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let before = try #require(beforeCache.files.values.first { $0.sessionId == "race-child" })
        #expect(before.codexScanComplete == false)
        #expect(before.codexForkAccountingState != nil)
        let committedOffset = try #require(before.parsedBytes)

        var injectedLookups = 0
        _ = CostUsageScanner.withCodexInheritedTotalsParseOverrideForTesting { parentSessionId, _ in
            guard parentSessionId == "race-parent" else { return nil }
            injectedLookups += 1
            return .unresolved
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: boundedOptions)
        }
        #expect(injectedLookups == 1)
        let retryCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let retry = try #require(retryCache.files.values.first { $0.sessionId == "race-child" })
        #expect(retry.parsedBytes == committedOffset)
        #expect(retry.codexScanComplete == false)
        #expect(retry.codexForkAccountingState == before.codexForkAccountingState)
        #expect(retry.codexTokenSidecarState == before.codexTokenSidecarState)
        #expect(retry.days == before.days)

        var finalReport: CostUsageDailyReport?
        var completedCache = retryCache
        for pass in 3..<24 {
            finalReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: boundedOptions)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let child = try #require(completedCache.files.values.first { $0.sessionId == "race-child" })
            if child.codexScanComplete == true { break }
        }
        let completed = try #require(
            completedCache.files.values.first { $0.sessionId == "race-child" })
        #expect(completed.parsedBytes == childSize)
        #expect(completed.codexScanComplete == true)
        #expect(completed.days == controlChild.days)
        #expect(try #require(finalReport).data == controlReport.data)
        #expect(try #require(finalReport).summary == controlReport.summary)
    }

    @Test
    func `last only ordinary fork preserves remaining inherited totals across cache reloads`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let childISO = env.isoString(for: day.addingTimeInterval(2))

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(parentISO)","payload":{"session_id":"last-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "00-last-parent.jsonl",
            contents: parentBody)

        var boundedOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024,
            preferNewestCodexSessionsFirst: false)
        boundedOptions.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: boundedOptions)

        let padding = String(repeating: "x", count: 390)
        let childBody = ([
            #"{"type":"session_meta","timestamp":"\#(childISO)","payload":{"session_id":"last-child","#
                + #""forked_from_id":"last-parent","timestamp":"\#(forkISO)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":60,"cached_input_tokens":6,"output_tokens":3},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ] + (0..<6).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        } + [
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":50,"cached_input_tokens":5,"output_tokens":2},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ] + (6..<12).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        } + [
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":30,"cached_input_tokens":3,"output_tokens":2},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ]).joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-last-child.jsonl",
            contents: childBody)
        let childSize = CostUsageScanner.codexFileMetadata(fileURL: childURL).size
        #expect(childSize > 3 * boundedOptions.maxCodexSessionFileBytes)

        var controlOptions = boundedOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("last-control-cache", isDirectory: true)
        controlOptions.maxCodexSessionFileBytes = 0
        controlOptions.maxCodexScanBytesPerRefresh = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: controlOptions)
        let controlCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: controlOptions.cacheRoot)
        let controlChild = try #require(controlCache.files.values.first { $0.sessionId == "last-child" })

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: boundedOptions)
        var completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let first = try #require(completedCache.files.values.first { $0.sessionId == "last-child" })
        let firstRemaining = try #require(first.codexForkAccountingState?.remainingInheritedTotals)
        #expect(firstRemaining == CostUsageCodexTotals(input: 40, cached: 4, output: 2, reasoning: nil))

        for pass in 2..<24 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: boundedOptions)
            completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let child = try #require(completedCache.files.values.first { $0.sessionId == "last-child" })
            if child.codexScanComplete == true { break }
        }
        let completed = try #require(
            completedCache.files.values.first { $0.sessionId == "last-child" })
        let completedDay = try #require(
            completed.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        let completedTokens = try #require(
            completedDay[CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")])
        #expect(completed.parsedBytes == childSize)
        #expect(completed.codexScanComplete == true)
        #expect(completed.codexForkAccountingState?.remainingInheritedTotals == nil)
        #expect(completedTokens == [40, 4, 2])
        #expect(completed.days == controlChild.days)
    }

    @Test
    func `deferred child advances an out-of-window parent but waits for EOF`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let childDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: parentDay)
        let forkISO = env.isoString(for: parentDay.addingTimeInterval(1))
        let childISO = env.isoString(for: childDay)
        let padding = String(repeating: "x", count: 700)
        let parentBody = ([
            #"{"type":"session_meta","timestamp":"\#(parentISO)","payload":{"session_id":"redacted-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentISO)","payload":{"model":"openai/gpt-5.4"}}"#,
        ] + (0..<12).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        } + [
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ] + (12..<18).map { index in
            #"{"type":"response_item","payload":{"index":\#(index),"text":"\#(padding)"}}"#
        }).joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "redacted-parent.jsonl",
            contents: parentBody)
        try FileManager.default.setAttributes(
            [.modificationDate: parentDay],
            ofItemAtPath: parentURL.path)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(childISO)","payload":{"session_id":"redacted-child","#
                + #""forked_from_id":"redacted-parent","timestamp":"\#(forkISO)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childISO)","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(childISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":150,"cached_input_tokens":15,"output_tokens":8},"#
                + #""model":"openai/gpt-5.4"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "redacted-child.jsonl",
            contents: childBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let firstParent = try #require(firstCache.files.values.first { $0.sessionId == "redacted-parent" })
        let firstChild = try #require(firstCache.files.values.first { $0.sessionId == "redacted-child" })
        #expect(firstParent.codexScanComplete == false)
        #expect(firstParent.codexTokenSnapshots == nil)
        #expect(firstParent.codexTokenCheckpoints == nil)
        #expect(firstParent.codexTokenSidecarState?.eventCount == 0)
        #expect(firstChild.days.isEmpty)
        #expect(firstChild.hasRetryableBufferedCodexFork)
        #expect(firstChild.codexForkTimestamp == forkISO)
        #expect(firstChild.parsedBytes == 0)
        #expect(firstChild.codexDeferredForkScan == true)
        #expect(firstChild.codexBufferedUnresolvedForkLines == nil)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay.addingTimeInterval(1),
            options: options)
        let secondCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let secondParent = try #require(secondCache.files.values.first { $0.sessionId == "redacted-parent" })
        let secondChild = try #require(secondCache.files.values.first { $0.sessionId == "redacted-child" })
        #expect((secondParent.parsedBytes ?? 0) > (firstParent.parsedBytes ?? 0))
        #expect(secondChild.parsedBytes == firstChild.parsedBytes)
        #expect(secondChild.days.isEmpty)
        #expect(secondChild.codexDeferredForkScan == true)
        #expect(secondChild.codexBufferedUnresolvedForkLines == nil)

        var cache = secondCache
        var incompleteParentPasses = 0
        for pass in 2..<30 where cache.codexScanCatchUpPending == true {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: childDay,
                until: childDay,
                now: childDay.addingTimeInterval(TimeInterval(pass)),
                options: options)
            cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let parent = try #require(cache.files.values.first { $0.sessionId == "redacted-parent" })
            let child = try #require(cache.files.values.first { $0.sessionId == "redacted-child" })
            if parent.codexScanComplete == false {
                incompleteParentPasses += 1
                #expect(child.days.isEmpty)
                #expect(child.codexDeferredForkScan == true)
            }
            if !child.days.isEmpty {
                #expect(parent.codexScanComplete == true)
            }
        }
        let completedParent = try #require(cache.files.values.first { $0.sessionId == "redacted-parent" })
        let completedChild = try #require(cache.files.values.first { $0.sessionId == "redacted-child" })
        let childModels = try #require(completedChild.days[
            CostUsageScanner.CostUsageDayRange.dayKey(from: childDay),
        ])
        #expect(incompleteParentPasses > 0)
        #expect(completedParent.codexScanComplete == true)
        #expect(completedParent.codexTokenSnapshots == nil)
        #expect(completedParent.codexTokenCheckpoints == nil)
        #expect(completedParent.codexTokenSidecarState?.eventCount == 1)
        #expect(childModels[CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")] == [50, 5, 3])
        #expect(completedChild.forkBaselineDependencyKey?.hasPrefix("file|redacted-parent|") == true)
        #expect(completedChild.codexDeferredForkScan != true)
        #expect(cache.codexScanCatchUpPending == false)
    }

    @Test
    func `growing an out-of-window token index keeps the JSON cache size bounded`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let childDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: parentDay)
        let childISO = env.isoString(for: childDay)
        let forkISO = env.isoString(for: parentDay.addingTimeInterval(5000))
        let initialEventCount = 128
        let finalEventCount = 2048

        func tokenObject(_ index: Int) -> [String: Any] {
            let input = index + 1
            return [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(TimeInterval(index + 1))),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": input,
                            "cached_input_tokens": input / 10,
                            "output_tokens": input / 20,
                        ],
                        "model": "openai/gpt-5.4",
                    ],
                ],
            ]
        }

        var parentObjects: [Any] = [
            [
                "type": "session_meta",
                "timestamp": parentISO,
                "payload": ["session_id": "bounded-cache-parent"],
            ],
            [
                "type": "turn_context",
                "timestamp": parentISO,
                "payload": ["model": "openai/gpt-5.4"],
            ],
        ]
        parentObjects.append(contentsOf: (0..<initialEventCount).map { tokenObject($0) })
        let parentURL = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "bounded-cache-parent.jsonl",
            contents: env.jsonl(parentObjects))

        let childBody = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": childISO,
                "payload": [
                    "session_id": "bounded-cache-child",
                    "forked_from_id": "bounded-cache-parent",
                    "timestamp": forkISO,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": childISO,
                "payload": ["model": "openai/gpt-5.4"],
            ],
            [
                "type": "event_msg",
                "timestamp": childISO,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 3000,
                            "cached_input_tokens": 300,
                            "output_tokens": 150,
                        ],
                        "model": "openai/gpt-5.4",
                    ],
                ],
            ],
        ])
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "bounded-cache-child.jsonl",
            contents: childBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0

        func convergedCache(expectedEventCount: Int, startingPass: Int) -> CostUsageCache {
            var cache = CostUsageCache()
            for pass in startingPass..<(startingPass + 12) {
                _ = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: childDay,
                    until: childDay,
                    now: childDay.addingTimeInterval(TimeInterval(pass)),
                    options: options)
                cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
                let parent = cache.files.values.first { $0.sessionId == "bounded-cache-parent" }
                if parent?.codexScanComplete == true,
                   parent?.codexTokenSidecarState?.eventCount == expectedEventCount,
                   cache.codexScanCatchUpPending != true
                {
                    break
                }
            }
            return cache
        }

        let initialCache = convergedCache(expectedEventCount: initialEventCount, startingPass: 0)
        let initialParent = try #require(
            initialCache.files.values.first { $0.sessionId == "bounded-cache-parent" })
        #expect(initialParent.days.isEmpty)
        #expect(initialParent.codexRows?.isEmpty != false)
        #expect(initialParent.codexTokenSnapshots == nil)
        #expect(initialParent.codexTokenCheckpoints == nil)
        #expect(initialParent.codexTokenTimestampsMonotonic == nil)
        #expect(initialParent.codexTokenSidecarState?.eventCount == initialEventCount)
        #expect(initialParent.codexTokenSidecarState?.accumulatorState.seenRawTotals.count == 64)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        let initialJSONBytes = try Data(contentsOf: cacheURL).count

        let appendedBody = try env.jsonl(
            (initialEventCount..<finalEventCount).map { tokenObject($0) })
        let handle = try FileHandle(forWritingTo: parentURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedBody.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: parentDay.addingTimeInterval(7000)],
            ofItemAtPath: parentURL.path)

        let finalCache = convergedCache(expectedEventCount: finalEventCount, startingPass: 100)
        let finalParent = try #require(
            finalCache.files.values.first { $0.sessionId == "bounded-cache-parent" })
        #expect(finalParent.codexScanComplete == true)
        #expect(finalParent.days.isEmpty)
        #expect(finalParent.codexRows?.isEmpty != false)
        #expect(finalParent.codexTokenSnapshots == nil)
        #expect(finalParent.codexTokenCheckpoints == nil)
        #expect(finalParent.codexTokenTimestampsMonotonic == nil)
        #expect(finalParent.codexTokenSidecarState?.eventCount == finalEventCount)
        #expect(finalParent.codexTokenSidecarState?.accumulatorState.seenRawTotals.count == 64)
        let finalJSONBytes = try Data(contentsOf: cacheURL).count

        #expect(finalJSONBytes <= initialJSONBytes + 4 * 1024)
    }

    @Test
    func `appended parent defers its child until the cached suffix reaches EOF`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let appendedISO = env.isoString(for: day.addingTimeInterval(10))

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-append"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "parent-append.jsonl",
            contents: parentBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let indexedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let indexedParentEntry = try #require(
            indexedCache.files.first { $0.value.sessionId == "parent-append" })
        let indexedParent = indexedParentEntry.value
        let indexedSize = indexedParent.size
        #expect(indexedParent.codexScanComplete == true)
        #expect(indexedParent.codexTokenIndexAnchor?.indexedBytes == indexedSize)
        #expect(indexedParent.codexTokenSnapshots == nil)
        #expect(indexedParent.codexTokenCheckpoints == nil)
        #expect(indexedParent.codexTokenSidecarState?.eventCount == 1)

        let appendedLine = #"{"type":"event_msg","timestamp":"\#(appendedISO)","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":900,"cached_input_tokens":90,"output_tokens":45},"#
            + #""model":"openai/gpt-5.2-codex"}}}"# + "\n"
        let parentHandle = try FileHandle(forWritingTo: parentURL)
        try parentHandle.seekToEnd()
        try parentHandle.write(contentsOf: Data(appendedLine.utf8))
        try parentHandle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: parentURL.path)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"child-append","#
                + #""forked_from_id":"parent-append"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "child-append.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: childURL.path)
        let childSize = CostUsageScanner.codexFileMetadata(fileURL: childURL).size

        options.maxCodexSessionFileBytes = 64 * 1024 * 1024
        options.maxCodexScanBytesPerRefresh = childSize + Self.codexLookbackDiscoveryWork(options: options)
        options.preferNewestCodexSessionsFirst = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: options)

        let refreshedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredParent = try #require(
            refreshedCache.files.values.first { $0.sessionId == "parent-append" })
        let child = try #require(
            refreshedCache.files.values.first { $0.sessionId == "child-append" })

        #expect(child.days.isEmpty)
        #expect(child.forkBaselineDependencyKey == nil)
        #expect(child.parsedBytes == 0)
        #expect(child.codexDeferredForkScan == true)
        #expect(child.codexBufferedUnresolvedForkLines == nil)
        #expect(deferredParent.size == indexedSize)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: parentURL).size > deferredParent.size)
        #expect(refreshedCache.codexScanCatchUpPending == true)
    }

    @Test
    func `rewritten parent prefix rejects its cached token index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let originalBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-rewrite"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25}}}}"#,
        ].joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "parent-rewrite.jsonl",
            contents: originalBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let usage = try #require(cache.files.values.first { $0.sessionId == "parent-rewrite" })
        let anchor = try #require(usage.codexTokenIndexAnchor)

        let rewrittenBody = originalBody.replacingOccurrences(
            of: #""input_tokens":500"#,
            with: #""input_tokens":900"#)
        #expect(rewrittenBody.utf8.count == originalBody.utf8.count)
        try rewrittenBody.write(to: parentURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: parentURL.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: parentURL)
        #expect(!CostUsageScanner.codexTokenIndexAnchorMatches(
            anchor,
            fileURL: parentURL,
            metadata: metadata))

        let fileIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parentURL],
            roots: [env.codexSessionsRoot])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: fileIndex,
            checkCancellation: nil,
            scanBudget: CostUsageScanner.CodexScanBudget(maxFileBytes: 1, maxBytesPerRefresh: 1),
            tokenIndexStore: CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot),
            cachedFiles: cache.files)
        guard case .unresolved = try resolver.inheritedTotals(
            for: "parent-rewrite",
            atOrBefore: forkISO)
        else {
            Issue.record("rewritten prefix must not reuse the cached fork baseline")
            return
        }
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
            if turnsPerFile > 0 {
                for turn in 1...turnsPerFile {
                    let inputTokens = turn * inputTokensPerTurn
                    let cachedTokens = turn * 20
                    let outputTokens = turn * 10
                    lines.append(
                        #"{"type":"event_msg","timestamp":"\#(baseISO)","payload":{"type":"token_count","info":"#
                            + #"{"total_token_usage":{"input_tokens":\#(inputTokens),"#
                            + #""cached_input_tokens":\#(cachedTokens),"output_tokens":\#(outputTokens)},"#
                            + #""model":"\#(model)"}}}"#)
                }
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

    private static func codexLookbackDiscoveryWork(options: CostUsageScanner.Options) -> Int64 {
        let existingRootCount = CostUsageScanner.codexSessionsRoots(options: options).count {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return Int64(CostUsageScanner.codexActiveSessionLookbackDays * existingRootCount)
    }
}

private final class HeadParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
#endif

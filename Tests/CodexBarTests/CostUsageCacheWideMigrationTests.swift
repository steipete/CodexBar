import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
@Suite(.serialized)
struct CostUsageCacheWideMigrationTests {
    @Test
    func `cache wide migration preserves newest first queue ordering`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
        let oldestURL = try #require(fileURLs.first)
        let newestURL = try #require(fileURLs.last)
        for (index, fileURL) in fileURLs.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: day.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path)
        }

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var migrationCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        migrationCache.codexPricingKey = "legacy-pricing-key"
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: migrationCache)

        options.maxCodexScanDurationPerRefresh = 60
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let migratedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(recorder.attemptedCodexFilePaths().contains(newestURL.path))
        #expect(!recorder.attemptedCodexFilePaths().contains(oldestURL.path))
        #expect(migratedCache.codexActiveLookbackState?.pendingFilePaths == [oldestURL.path])
    }

    @Test
    func `cache wide migration reorders a partially drained queue newest first`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 600
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
        let oldestURL = try #require(fileURLs.first)
        let newestURL = try #require(fileURLs.last)
        for (index, fileURL) in fileURLs.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: day.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path)
        }

        var options = Self.boundedOptions(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var migrationCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(migrationCache.codexActiveLookbackState?.pendingFilePaths.isEmpty == true)
        #expect(migrationCache.codexActiveLookbackState?.currentWindowNextDayKeyByRoot?.isEmpty == false)
        migrationCache.codexPricingKey = "legacy-pricing-key"
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: migrationCache)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let migratedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(recorder.attemptedCodexFilePaths().contains(newestURL.path))
        #expect(!recorder.attemptedCodexFilePaths().contains(oldestURL.path))
        #expect(migratedCache.codexActiveLookbackState?.pendingFilePaths.count
            == corpusSize - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(migratedCache.codexActiveLookbackState?.pendingFilePaths.contains(oldestURL.path) == true)
    }

    @Test(arguments: CacheWideMigrationCase.allCases)
    func `cache wide migrations reseed and drain bounded work once`(
        migration: CacheWideMigrationCase) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 600
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
        let targetURL = try #require(fileURLs.last)
        let traceDatabaseURL = env.root.appendingPathComponent("migration-traces.sqlite")
        if migration != .priorityMetadata {
            try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: traceDatabaseURL)
        }

        var options = Self.boundedOptions(env: env)
        options.codexTraceDatabaseURL = traceDatabaseURL
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var migrationCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(migrationCache.codexActiveLookbackState == nil)
        #expect(migrationCache.codexScanCatchUpPending == false)
        #expect(migrationCache.codexScanCompletedFiles == corpusSize)
        let expectedPricingKey = try #require(migrationCache.codexPricingKey)
        let expectedProjectMetadataVersion = try #require(migrationCache.codexProjectMetadataVersion)

        switch migration {
        case .pricingMetadata:
            for path in migrationCache.files.keys {
                migrationCache.files[path]?.codexCostCacheComplete = false
                migrationCache.files[path]?.codexStandardTokens = nil
                migrationCache.files[path]?.codexPriorityTokens = nil
            }
        case .pricingKey:
            migrationCache.codexPricingKey = "legacy-pricing-key"
        case .projectMetadata:
            migrationCache.codexProjectMetadataVersion = nil
        case .turnIDCache:
            for path in migrationCache.files.keys {
                migrationCache.files[path]?.codexTurnIDs = nil
            }
        case .priorityMetadata:
            try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: traceDatabaseURL)
        case .priorityTurns:
            try CostUsageScannerCodexPriorityTests.insertTestLog(
                dbURL: traceDatabaseURL,
                timestamp: env.isoString(for: day),
                body: "thread_id=migration-thread turn.id=migration-turn websocket request: "
                    + #"{"type":"response.create","model":"gpt-5.4","service_tier":"priority"}"#)
        }
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: migrationCache)

        options.maxCodexScanDurationPerRefresh = 60
        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let firstMetrics = firstRecorder.snapshot()
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(firstMetrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexProgressAccountingVisits == 0)
        #expect(!firstRecorder.attemptedCodexFilePaths().contains(targetURL.path))
        #expect(firstCache.codexActiveLookbackState?.pendingFilePaths.count
            == corpusSize - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstCache.codexScanCompletedFiles == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstCache.codexScanTotalFiles == corpusSize)
        #expect(firstCache.codexScanCatchUpPending == true)
        Self.expectAuthoritativeMigrationMetadata(
            migration,
            cache: firstCache,
            expectedPricingKey: expectedPricingKey,
            expectedProjectMetadataVersion: expectedProjectMetadataVersion)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(secondMetrics.codexCandidateSelectionVisits
            == corpusSize - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(secondMetrics.codexFileScanAttempts
            == corpusSize - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(secondMetrics.codexProgressAccountingVisits == 0)
        #expect(secondRecorder.attemptedCodexFilePaths().contains(targetURL.path))
        #expect(secondCache.codexActiveLookbackState?.pendingFilePaths.isEmpty == true)
        #expect(secondCache.codexScanCompletedFiles == corpusSize - 1)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanCatchUpPending == true)

        let exactRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = exactRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let exactCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(exactRecorder.snapshot().codexCandidateSelectionVisits == 0)
        #expect(exactRecorder.snapshot().codexFileScanAttempts == 0)
        #expect(exactRecorder.snapshot().codexProgressAccountingVisits == corpusSize)
        #expect(exactCache.codexActiveLookbackState == nil)
        #expect(exactCache.codexScanCompletedFiles == corpusSize)
        #expect(exactCache.codexScanTotalFiles == corpusSize)
        #expect(exactCache.codexScanCatchUpPending == false)
        Self.expectAuthoritativeMigrationMetadata(
            migration,
            cache: exactCache,
            expectedPricingKey: expectedPricingKey,
            expectedProjectMetadataVersion: expectedProjectMetadataVersion)

        options.refreshMinIntervalSeconds = 60
        let warmRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = warmRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        let warmMetrics = warmRecorder.snapshot()
        let warmCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(warmMetrics.codexCandidateSelectionVisits == 0)
        #expect(warmMetrics.codexFileScanAttempts == 0)
        #expect(warmMetrics.codexProgressAccountingVisits == 0)
        #expect(warmCache.codexActiveLookbackState == nil)
        #expect(warmCache.codexScanCatchUpPending == false)
    }

    private static func expectAuthoritativeMigrationMetadata(
        _ migration: CacheWideMigrationCase,
        cache: CostUsageCache,
        expectedPricingKey: String,
        expectedProjectMetadataVersion: Int)
    {
        switch migration {
        case .pricingMetadata, .pricingKey:
            #expect(cache.codexPricingKey == expectedPricingKey)
        case .projectMetadata:
            #expect(cache.codexProjectMetadataVersion == expectedProjectMetadataVersion)
        case .turnIDCache:
            #expect(cache.files.values.contains { $0.codexTurnIDs == nil } == cache.codexScanCatchUpPending)
        case .priorityMetadata:
            #expect(cache.codexPriorityMetadataKey?.hasPrefix("sqlite:") == true)
        case .priorityTurns:
            #expect(cache.codexPriorityTurnKeys?.isEmpty == false)
        }
    }

    private static func boundedOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func writeSyntheticCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        fileCount: Int) throws -> [URL]
    {
        let iso = env.isoString(for: day)
        return try (0..<fileCount).map { index in
            let lines = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"migration-\#(index)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ]
            return try env.writeCodexSessionFile(
                day: day,
                filename: String(format: "migration-%04d.jsonl", index),
                contents: lines.joined(separator: "\n") + "\n")
        }
    }
}

enum CacheWideMigrationCase: CaseIterable {
    case pricingMetadata
    case pricingKey
    case projectMetadata
    case turnIDCache
    case priorityMetadata
    case priorityTurns
}
#endif

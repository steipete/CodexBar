import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeLocalHistoryPublicationTests {
    @Test
    func `ambient OpenCode history stays cached and out of Spend Dashboard`() async throws {
        // This integration check requires the repository runner's contained home.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
        try #require(home.contains("codexbar-"))
        let scratch = URL(fileURLWithPath: home)
        let root = scratch.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let options = CostUsageScanner.Options(
            includeOpenCodeLocalHistory: true,
            cacheRoot: root.appendingPathComponent("cache"),
            codexTraceDatabaseURL: root.appendingPathComponent("missing-trace.sqlite"),
            calendar: calendar)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        try #require(roots.allSatisfy { $0.path.hasPrefix(home + "/") })
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        try #require(roots.allSatisfy {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedHome + "/")
        })

        let url = root.appendingPathComponent("source.db")
        let timestamp: Int64 = 1_772_798_400_000
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = """
        CREATE TABLE session_message(id TEXT PRIMARY KEY, type TEXT, data TEXT,
          time_created INTEGER, time_updated INTEGER);
        INSERT INTO session_message VALUES ('scope-fixture', 'assistant',
            '{"model":{"providerID":"openai","id":"fixture-opencode-dashboard-only"},"cost":3}',
            \(timestamp), \(timestamp));
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try #require(result == SQLITE_OK)
        func load(_ context: CostUsageReportContext) async throws -> CostUsageTokenResult {
            try await CostUsageFetcher.loadTokenResult(
                provider: .codex,
                environment: ["OPENCODE_DB": url.path],
                now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                forceRefresh: true,
                historyDays: 1,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false,
                scannerOptions: options,
                retryUnknownPricing: false,
                reportContext: context)
        }
        let regular = try await load(.regular)
        try #require(regular.snapshot.daily.flatMap { $0.modelsUsed ?? [] }.contains("fixture-opencode-dashboard-only"))
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
            historyDays: 1,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            scannerOptions: options,
            environment: ["OPENCODE_DB": url.path])
        #expect(cached?.snapshot.daily.flatMap { $0.modelsUsed ?? [] }
            .contains("fixture-opencode-dashboard-only") == true)
        #expect(cached?.snapshot.daily.first?.totalTokens == nil)
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let appendSQL = """
        INSERT INTO session_message SELECT 'catch-up-fixture', type,
            '{"model":{"providerID":"openai","id":"fixture-opencode-dashboard-only"},"cost":2}',
            time_created, time_updated FROM session_message LIMIT 1
        """
        let appendResult = sqlite3_exec(database, appendSQL, nil, nil, nil)
        sqlite3_close(database)
        try #require(appendResult == SQLITE_OK)
        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: url,
            store: CostUsageStore(cacheRoot: options.cacheRoot),
            rowBudget: 1,
            calendar: calendar)
        let fetcher = CostUsageFetcher(scannerOptions: options)
        let pending = await fetcher.codexScanCatchUpStatus(
            calendar: calendar,
            historyDays: 1,
            now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
            includeOpenCodeLocalHistory: true,
            environment: ["OPENCODE_DB": url.path])
        #expect(pending.pending)
        var advanced = try await fetcher.advanceCodexScanCatchUp(
            now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
            historyDays: 1,
            calendar: calendar,
            includeOpenCodeLocalHistory: true,
            environment: ["OPENCODE_DB": url.path])
        // Native directory discovery can finish after the source checkpoint does.
        for _ in 0..<4 where advanced.value.pending {
            advanced = try await fetcher.advanceCodexScanCatchUp(
                now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                historyDays: 1,
                calendar: calendar,
                includeOpenCodeLocalHistory: true,
                environment: ["OPENCODE_DB": url.path])
        }
        #expect(!advanced.value.pending)
        #expect(advanced.value.completionIsConfirmed)
        let afterCatchUp = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
            historyDays: 1,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            scannerOptions: options,
            environment: ["OPENCODE_DB": url.path])
        #expect(afterCatchUp?.snapshot.daily.first?.costUSD == 5)
        let report = try await load(.spendDashboard)
        #expect(report.snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.allSatisfy { $0.sourceRecorded != true })
        #expect(!report.snapshot.daily.flatMap { $0.modelsUsed ?? [] }.contains("fixture-opencode-dashboard-only"))
        let explicitHome = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: Date(timeIntervalSince1970: Double(timestamp) / 1000),
            historyDays: 1,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            scannerOptions: options,
            environment: ["OPENCODE_DB": url.path, "CODEX_HOME": root.appendingPathComponent("scoped").path])
        #expect(explicitHome?.snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }
            .contains { $0.sourceRecorded == true } != true)
    }
}

struct OpenCodeLocalHistoryCursorTests {
    @Test
    func `a rejected eligible row cannot hide an older valid message`() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo
            .environment["CFFIXED_USER_HOME"] ?? NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.db")
        let timestamp: Int64 = 1_772_798_400_000
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = """
        CREATE TABLE message(id TEXT PRIMARY KEY, data TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER);
        INSERT INTO message VALUES
          ('old', '{"providerID":"openai","role":"assistant","modelID":"fixture-model","cost":1}',
            \(timestamp), \(timestamp)),
          ('bad', '{"providerID":"openai","role":"assistant","modelID":"fixture-model","cost":"bad"}',
            \(timestamp), \(timestamp)),
          ('new', '{"providerID":"openai","role":"assistant","modelID":"fixture-model","cost":2}',
            \(timestamp), \(timestamp));
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try #require(result == SQLITE_OK)
        let store = CostUsageStore(cacheRoot: root.appendingPathComponent("cache"))
        for _ in 0..<16 {
            _ = try await OpenCodeLocalHistoryAdapter.runPass(
                databaseURL: url,
                store: store,
                rowBudget: 1)
        }
        let day = OpenCodeLocalHistoryAdapter.dayKey(fromUnixMs: timestamp)
        let aggregates = await OpenCodeLocalHistoryAdapter.windowedAggregates(
            store: store,
            path: url.path,
            sinceDay: day,
            untilDay: day)
        #expect(aggregates.reduce(0) { $0 + $1.aggregate.authoritativeCostNanos } == 3_000_000_000)
        #expect(aggregates.reduce(0) { $0 + $1.aggregate.requestCount } == 2)
    }
}

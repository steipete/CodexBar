import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CostUsageSessionDetailsTests {
    @Test
    func `catch up progress cannot load newer requests under an older session summary`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.source.sessionSource.fileURL.path
        var partial = fixture.cache
        var usage = try #require(partial.files[path])
        let row = try #require(usage.codexRows?.first)
        usage.codexRows = [row]
        usage.days = [row.day: [row.model: [row.input, row.cached, row.output]]]
        usage.parsedBytes = 0
        usage.codexScanComplete = false
        partial.files[path] = usage
        partial.days = usage.days
        _ = CostUsageStoreAccess.replace(cacheRoot: fixture.root, cache: partial, calendar: fixture.calendar)
        let summary = try #require(CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: partial,
            range: fixture.dayRange,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            modelsDevCacheRoot: fixture.root).sessions.first)
        #expect(summary.totalTokens == 110)
        _ = CostUsageStoreAccess.replace(cacheRoot: fixture.root, cache: fixture.cache, calendar: fixture.calendar)
        #expect(try fixture.read().compactMap(\.totalTokens).reduce(0, +) == 220)
        #expect(throws: CostUsageSessionDetailError.sourceChanged) {
            try CostUsageSessionDetailLoader.read(
                source: #require(summary.requestDetailSource),
                lastActivity: summary.lastActivity,
                range: fixture.range,
                timeZone: fixture.calendar.timeZone,
                catalog: ModelsDevCatalog(providers: [:]))
        }
    }

    @Test
    func `selected requests retain resolved priority pricing over older standard row metadata`() throws {
        let fixture = try Fixture(priority: true)
        defer { fixture.remove() }
        let summary = try #require(CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: fixture.cache,
            range: fixture.dayRange,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            modelsDevCacheRoot: fixture.root).sessions.first)
        let details = try fixture.read()
        let costs = details.compactMap(\.costUSD)
        #expect(costs.count == 2)
        #expect(abs(costs.reduce(0, +) - (summary.costUSD ?? -1)) < 1e-12)
        #expect((costs.first ?? 0) > (costs.last ?? 0))
    }

    @Test
    func `ordinary refresh retains summaries and only selected details are decoded`() throws {
        let fixture = try Fixture(fileCount: 3)
        defer { fixture.remove() }
        let summaries = CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: fixture.cache,
            range: fixture.dayRange,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            modelsDevCacheRoot: fixture.root).sessions
        #expect(summaries.count == 3)
        #expect(summaries.flatMap(\.turns).isEmpty)
        let selected = try #require(summaries.first { $0.sessionID == fixture.source.sessionSource.sessionID })
        #expect(selected.requestDetailSource == fixture.source)
        // A different session's malformed payload must never be decoded by this inspector.
        try fixture.execute("""
        UPDATE usage_rows SET payload = x'00'
        WHERE file_id IN (SELECT id FROM files WHERE session_id != 'session-0')
        """)
        let details = try fixture.read()
        #expect(details.map(\.turnID) == ["turn-0", "turn-1"])
        #expect(details.compactMap(\.totalTokens).reduce(0, +) == selected.totalTokens)
        #expect(abs(details.compactMap(\.costUSD).reduce(0, +) - (selected.costUSD ?? -1)) < 1e-12)
        #expect(details.flatMap(\.requests).count == 2)
        #expect(selected.turns.isEmpty, "Opening details must not mutate the retained history summaries")
    }

    @Test
    func `request count and payload budgets fail without presenting a truncated total`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var limits = CostUsageSessionDetailLoader.Limits()
        limits.requests = 1
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read(limits: limits) }
        limits.requests = 2
        #expect(try fixture.read(limits: limits).count == 2)
        limits.payloadBytes = 1
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read(limits: limits) }
    }

    @Test
    func `file metadata and aggregate budgets are enforced before decoding`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var limits = CostUsageSessionDetailLoader.Limits()
        limits.metadataBytes = 1
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read(limits: limits) }
        limits = .init()
        limits.aggregates = 0
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read(limits: limits) }
    }

    @Test
    func `persisted priority metadata is byte bounded before copying or decoding`() throws {
        let fixture = try Fixture(priority: true)
        defer { fixture.remove() }
        var limits = CostUsageSessionDetailLoader.Limits()
        limits.pricingMetadataBytes = 1
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read(limits: limits) }
        try fixture.execute("UPDATE scan_metadata SET payload = zeroblob(1048577) WHERE id = 1")
        #expect(throws: CostUsageSessionDetailError.limitExceeded) { try fixture.read() }
    }

    @Test
    func `changed session identity timestamp or schema cannot reuse a stale summary`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrongSession = CostUsageSessionDetailSource(
            databaseURL: fixture.source.databaseURL,
            sessionSource: .init(fileURL: fixture.source.sessionSource.fileURL, sessionID: "another-account"),
            parsedBytes: fixture.source.parsedBytes)
        #expect(throws: CostUsageSessionDetailError.unavailable) {
            try CostUsageSessionDetailLoader.read(
                source: wrongSession,
                lastActivity: fixture.now,
                range: fixture.range,
                timeZone: fixture.calendar.timeZone)
        }
        #expect(throws: CostUsageSessionDetailError.sourceChanged) {
            try CostUsageSessionDetailLoader.read(
                source: fixture.source,
                lastActivity: fixture.now.addingTimeInterval(1),
                range: fixture.range,
                timeZone: fixture.calendar.timeZone)
        }
        try fixture.execute("PRAGMA user_version = 1")
        #expect(throws: CostUsageSessionDetailError.sourceChanged) { try fixture.read() }
    }

    @Test(arguments: ["455876ace937d42a", "4feea9e203d85529"])
    func `upgrading current main or the prior inspector preserves stored requests`(parserHash: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let version = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: parserHash)
        try fixture.execute("PRAGMA user_version = \(version)")
        try fixture.execute("UPDATE meta SET value = '\(parserHash)' WHERE key = 'parser_hash'")
        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        #expect(await store.rebuildCount == 0)
        #expect(try fixture.read().flatMap(\.requests).count == 2)
    }

    @Test
    func `reporting window and cancellation apply to selected reads`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nextDay = fixture.range.upperBound..<fixture.range.upperBound.addingTimeInterval(86400)
        let details = try CostUsageSessionDetailLoader.read(
            source: fixture.source,
            lastActivity: fixture.now,
            range: nextDay,
            timeZone: fixture.calendar.timeZone,
            catalog: ModelsDevCatalog(providers: [:]))
        #expect(details.isEmpty)
        var cancellationChecks = 0
        #expect(throws: CancellationError.self) {
            try CostUsageSessionDetailLoader.read(
                source: fixture.source,
                lastActivity: fixture.now,
                range: fixture.range,
                timeZone: fixture.calendar.timeZone,
                checkCancellation: {
                    cancellationChecks += 1
                    if cancellationChecks >= 4 { throw CancellationError() }
                })
        }
        // A previous window or failure must not be cached for the next selection.
        #expect(try fixture.read().count == 2)
    }

    @Test
    func `cancelled async selection never publishes a detail result`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CostUsageSessionDetailLoader.load(
                source: fixture.source,
                lastActivity: fixture.now,
                range: fixture.range,
                timeZone: fixture.calendar.timeZone)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func `missing database is never created by detail inspection`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("missing.sqlite")
        let source = CostUsageSessionDetailSource(
            databaseURL: database,
            sessionSource: .init(
                fileURL: root.appendingPathComponent("session.jsonl"),
                sessionID: "missing"),
            parsedBytes: nil)
        let now = Date(timeIntervalSince1970: 1_792_562_400)
        #expect(throws: CostUsageSessionDetailError.unavailable) {
            try CostUsageSessionDetailLoader.read(
                source: source,
                lastActivity: now,
                range: now..<now.addingTimeInterval(1),
                timeZone: #require(TimeZone(identifier: "Asia/Shanghai")))
        }
        #expect(!FileManager.default.fileExists(atPath: database.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func `non native inspection metadata removes captured request source`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try #require(CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: fixture.cache,
            range: fixture.dayRange,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            modelsDevCacheRoot: fixture.root).sessions.first)
        #expect(session.withInspectionMetadata(toolActivitySource: nil, turnPerformanceSamples: [])
            .requestDetailSource == nil)
        #expect(session.withInspectionMetadata(
            toolActivitySource: session.toolActivitySource,
            turnPerformanceSamples: []).requestDetailSource != nil)
    }

    private struct Fixture {
        let root: URL
        let now: Date
        let calendar: Calendar
        let range: Range<Date>
        let dayRange: CostUsageScanner.CostUsageDayRange
        let cache: CostUsageCache
        let source: CostUsageSessionDetailSource

        init(fileCount: Int = 1, priority: Bool = false) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent("session-details-\(UUID())")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
            self.calendar = calendar
            self.now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15)))
            let timestamp = Int64(self.now.timeIntervalSince1970 * 1000)
            let start = calendar.startOfDay(for: self.now)
            self.range = start..<start.addingTimeInterval(86400)
            self.dayRange = .init(since: self.now, until: self.now, calendar: calendar)
            let day = self.dayRange.sinceKey
            let model = priority ? "gpt-5.4" : "fictional-selected-model"
            var cache = CostUsageCache()
            cache.timeZoneIdentifier = calendar.timeZone.identifier
            if priority {
                cache.codexResolvedPriorityTurns = [
                    "turn-0": .init(
                        threadID: "session-0",
                        turnID: "turn-0",
                        model: model,
                        timestamp: "2026-10-21T15:00:00+08:00"),
                ]
            }
            for index in 0..<fileCount {
                let rows = (0..<2).map { event in
                    CostUsageScanner.CodexUsageRow(
                        day: day,
                        model: model,
                        turnID: "turn-\(event)",
                        eventIndex: event,
                        timestampUnixMs: timestamp + Int64(event * 1000),
                        input: 100,
                        cached: 80,
                        output: 10,
                        reasoning: 4,
                        knownCostNanos: priority ? nil : 100_000_000,
                        pricingModel: model,
                        pricingMode: "standard")
                }
                let usage = CostUsageScanner.makeFileUsage(
                    mtimeUnixMs: Int64(self.now.timeIntervalSince1970 * 1000),
                    size: 1,
                    days: [day: [model: [200, 160, 20]]],
                    parsedBytes: 1,
                    sessionId: "session-\(index)",
                    codexRows: rows,
                    codexScanComplete: true)
                cache.files[self.root.appendingPathComponent("session-\(index).jsonl").path] = usage
                CostUsageScanner.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
            }
            self.cache = cache
            self.source = .init(
                databaseURL: CostUsageStore.databaseURL(cacheRoot: self.root),
                sessionSource: .init(
                    fileURL: self.root.appendingPathComponent("session-0.jsonl"),
                    sessionID: "session-0"),
                parsedBytes: 1)
            _ = CostUsageStoreAccess.replace(cacheRoot: self.root, cache: cache, calendar: calendar)
        }

        func read(limits: CostUsageSessionDetailLoader.Limits = .init()) throws -> [CostUsageSessionTurn] {
            try CostUsageSessionDetailLoader.read(
                source: self.source,
                lastActivity: self.now,
                range: self.range,
                timeZone: self.calendar.timeZone,
                limits: limits,
                catalog: ModelsDevCatalog(providers: [:]))
        }

        func execute(_ sql: String) throws {
            var database: OpaquePointer?
            let opened = sqlite3_open_v2(self.source.databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
            let pointer = try #require(database)
            defer { sqlite3_close_v2(pointer) }
            #expect(opened == SQLITE_OK)
            sqlite3_busy_timeout(pointer, 5000)
            let result = sqlite3_exec(pointer, sql, nil, nil, nil)
            #expect(result == SQLITE_OK, "SQLite result: \(result)")
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }
}

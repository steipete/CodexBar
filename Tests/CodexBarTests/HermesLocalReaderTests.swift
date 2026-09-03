import XCTest
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

final class HermesLocalReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesLocalReaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = self.tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    #if canImport(SQLite3) || canImport(CSQLite3)
    private func createDatabase(at url: URL) -> OpaquePointer? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            return nil
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL DEFAULT 'cli',
            model TEXT,
            billing_provider TEXT,
            started_at REAL NOT NULL,
            last_activity_at REAL,
            message_count INTEGER DEFAULT 0,
            api_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL,
            actual_cost_usd REAL,
            cost_status TEXT,
            cost_source TEXT
        );

        CREATE TABLE IF NOT EXISTS session_model_usage (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '',
            billing_base_url TEXT NOT NULL DEFAULT '',
            billing_mode TEXT NOT NULL DEFAULT '',
            task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0,
            actual_cost_usd REAL NOT NULL DEFAULT 0,
            cost_status TEXT,
            cost_source TEXT,
            first_seen REAL,
            last_seen REAL,
            PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        return db
    }
    #endif

    // MARK: - Unit Tests

    func testMissingDatabaseReturnsUnavailable() throws {
        let missingContext = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: missingContext)
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.report.data.isEmpty)
    }

    func testMissingDatabaseSnapshotIsConfirmedEmpty() async throws {
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: ["HERMES_HOME": self.tempDirectory.path],
            now: Date(),
            historyDays: 30)
        XCTAssertTrue(snapshot.historyCoverageIsEstablished)
        XCTAssertEqual(snapshot.sessionRequests, 0)
        XCTAssertEqual(snapshot.last30DaysRequests, 0)
        XCTAssertTrue(snapshot.daily.isEmpty)
    }

    func testLightweightAvailabilityDoesNotRequireOpeningOrParsingDatabase() throws {
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        XCTAssertFalse(HermesLocalReader.hasLocalStore(context: context))
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .absent)

        let databaseURL = self.tempDirectory.appendingPathComponent("state.db")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        XCTAssertTrue(HermesLocalReader.hasLocalStore(context: context))
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .present)
    }

    func testProfileDiscoveryFailureIsUnavailable() throws {
        let profilesURL = self.tempDirectory.appendingPathComponent("profiles")
        try Data("not a directory".utf8).write(to: profilesURL)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .unavailable)
    }

    func testEmptyDatabaseReturnsCompleteWithNoEntries() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        sqlite3_close(db)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertTrue(result.report.data.isEmpty)
        #endif
    }

    func testCanonicalTokenSumExcludesReasoningDoubleCount() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, started_at) VALUES ('sess_1', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
            estimated_cost_usd, actual_cost_usd, first_seen, last_seen
        ) VALUES (
            'sess_1', 'nous-hermes-3', 'anthropic', 1,
            100, 50, 20, 10, 15,
            0.05, 0.0, \(now), \(now)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(result.report.data.count, 1)

        let entry = try XCTUnwrap(result.report.data.first)
        // Canonical total in producer semantics: input (100) + output (50) + cacheRead (20) + cacheWrite (10) = 180
        // Reasoning (15) is a subset of output, NOT added twice!
        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 50)
        XCTAssertEqual(entry.cacheReadTokens, 20)
        XCTAssertEqual(entry.cacheCreationTokens, 10)
        XCTAssertEqual(entry.reasoningTokens, 15)
        XCTAssertEqual(entry.totalTokens, 180)
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(entry.costUSD, 0.05)

        let breakdown = try XCTUnwrap(entry.modelBreakdowns?.first)
        XCTAssertEqual(breakdown.modelName, "nous-hermes-3")
        XCTAssertEqual(breakdown.totalTokens, 180)
        XCTAssertEqual(breakdown.reasoningTokens, 15)
        #endif
    }

    func testCostStatePreservesKnownZeroAndCoverageCategories() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_actual_zero', 'actual-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_estimated_zero', 'estimated-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_included_zero', 'included-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_unknown', 'unknown-cost', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, estimated_cost_usd, actual_cost_usd,
            cost_status, cost_source, first_seen, last_seen
        ) VALUES
            ('sess_actual_zero', 'actual-zero', 'provider', 1, 10, 1, 0, 0,
             'actual', 'provider_cost_api', \(now), \(now)),
            ('sess_estimated_zero', 'estimated-zero', 'provider', 1, 20, 2, 0, 0,
             'estimated', 'official_docs_snapshot', \(now), \(now)),
            ('sess_included_zero', 'included-zero', 'provider', 1, 30, 3, 0, 0,
             'included', 'none', \(now), \(now)),
            ('sess_unknown', 'unknown-cost', 'provider', 1, 40, 4, 0, 0,
             'unknown', 'none', \(now), \(now));
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 110)
        XCTAssertEqual(entry.costUSD, 0)
        XCTAssertEqual(entry.requestCount, 4)
        XCTAssertEqual(
            entry.coverageCounts,
            CostUsageCoverageCounts(priced: 1, unpriced: 1, unmetered: 1, estimated: 1))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: ["HERMES_HOME": self.tempDirectory.path],
            now: Date(timeIntervalSince1970: now),
            historyDays: 1)
        XCTAssertEqual(snapshot.last30DaysTokens, 110)
        XCTAssertEqual(snapshot.last30DaysCostUSD, 0)
        XCTAssertEqual(snapshot.costProvenance, .mixed)
        #endif
    }

    func testResidualSessionReconciliation() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        // Main session row has 1000 input, 200 output, and five API calls
        // SMU has only an auxiliary row with 20 input, 10 output, api_call_count 1
        let sql = """
        INSERT INTO sessions (
            id, model, billing_provider, started_at, message_count, api_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
        ) VALUES (
            'sess_main', 'hermes-main-model', 'nous', \(now), 5, 5,
            1000, 200, 0, 0
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, task, api_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            first_seen, last_seen
        ) VALUES (
            'sess_main', 'aux-title-model', 'nous', 'title', 1,
            20, 10, 0, 0,
            \(now), \(now)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)

        let entry = try XCTUnwrap(result.report.data.first)
        // Total should be exactly 1000 + 200 = 1200 (residual 1170 + aux 30 = 1200)
        XCTAssertEqual(entry.totalTokens, 1200)
        XCTAssertEqual(entry.inputTokens, 1000)
        XCTAssertEqual(entry.outputTokens, 200)
        XCTAssertEqual(entry.requestCount, 5)

        let breakdowns = try XCTUnwrap(entry.modelBreakdowns)
        XCTAssertEqual(breakdowns.count, 2)

        let aux = breakdowns.first(where: { $0.modelName == "aux-title-model" })
        XCTAssertNotNil(aux)
        XCTAssertEqual(aux?.totalTokens, 30)
        XCTAssertEqual(aux?.requestCount, 1)

        let main = breakdowns.first(where: { $0.modelName == "hermes-main-model" })
        XCTAssertNotNil(main)
        XCTAssertEqual(main?.totalTokens, 1170)
        XCTAssertEqual(main?.requestCount, 4) // 5 API calls - 1 auxiliary call = 4
        #endif
    }

    func testResumedSessionAttributionToActiveDate() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = calendar.startOfDay(for: Date())
        let tenDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: today))

        let todayEpoch = today.timeIntervalSince1970 + 3600
        let tenDaysAgoEpoch = tenDaysAgo.timeIntervalSince1970 + 3600

        // Session started 10 days ago, but SMU last_seen is today
        let sql = """
        INSERT INTO sessions (id, started_at) VALUES ('sess_resumed', \(tenDaysAgoEpoch));
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_resumed', 'model-v1', 500, 100, \(tenDaysAgoEpoch), \(todayEpoch)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context, calendar: calendar)
        XCTAssertEqual(result.coverage, .complete)

        let todayKey = CostUsageLocalDay.key(from: today, calendar: calendar)
        let entry = try XCTUnwrap(result.report.data.first(where: { $0.date == todayKey }))
        XCTAssertEqual(entry.totalTokens, 600)
        #endif
    }

    func testUndatedModelRowsUseSessionActivityTimestamp() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = calendar.startOfDay(for: Date())
        let startedAt = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: today))
        let activityAt = today.addingTimeInterval(3600)
        let startedEpoch = startedAt.timeIntervalSince1970
        let activityEpoch = activityAt.timeIntervalSince1970

        let sql = """
        INSERT INTO sessions (id, model, started_at, last_activity_at)
        VALUES (
            'sess_legacy', 'legacy-session-model', \(startedEpoch), \(activityEpoch)
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_legacy', 'legacy-row-model', 'nous', 1, 500, 100
        );
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context, calendar: calendar)
        XCTAssertEqual(result.coverage, .complete)

        let todayKey = CostUsageLocalDay.key(from: today, calendar: calendar)
        let entry = try XCTUnwrap(result.report.data.first(where: { $0.date == todayKey }))
        XCTAssertEqual(entry.totalTokens, 600)
        XCTAssertEqual(entry.modelBreakdowns?.first?.modelName, "legacy-row-model")
        XCTAssertEqual(entry.modelBreakdowns?.first?.totalTokens, 600)
        #endif
    }

    func testArithmeticOverflowProtection() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, started_at) VALUES ('sess_overflow', \(now));
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_overflow', 'model-overflow', 9223372036854775807, 100, \(now), \(now)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        // Should not crash due to integer overflow
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertNotNil(result)
        #endif
    }

    func testCorruptDatabaseReturnsPartialCoverage() throws {
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        try Data("not a sqlite database".utf8).write(to: dbURL)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.report.data.isEmpty)
    }

    func testActiveWALRowsAreReadWithinSnapshot() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil),
            SQLITE_OK)
        let now = Date().timeIntervalSince1970
        let sql = """
        BEGIN;
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_wal', 'wal-model', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('sess_wal', 'wal-model', 'provider', 1, 7, 3, \(now), \(now));
        COMMIT;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(result.report.data.first?.totalTokens, 10)
        #endif
    }

    func testMultiProfileDeduplication() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let defaultDB = self.tempDirectory.appendingPathComponent("state.db")
        let profileDir = self.tempDirectory.appendingPathComponent("profiles/dev", isDirectory: true)
        let profileDB = profileDir.appendingPathComponent("state.db")

        guard let db1 = self.createDatabase(at: defaultDB),
              let db2 = self.createDatabase(at: profileDB)
        else {
            XCTFail("Failed to create test databases")
            return
        }
        defer {
            sqlite3_close(db1)
            sqlite3_close(db2)
        }

        let now = Date().timeIntervalSince1970
        let stale = now - 60
        let defaultSQL = """
        INSERT INTO sessions (
            id, model, billing_provider, started_at, last_activity_at, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_shared', 'old-model', 'old-provider', \(stale), \(stale), 1, 300, 100
        );
        """
        let profileSQL = """
        INSERT INTO sessions (
            id, model, billing_provider, started_at, last_activity_at, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_shared', 'new-model', 'other-provider', \(stale), \(now), 2, 450, 150
        );
        """
        XCTAssertEqual(sqlite3_exec(db1, defaultSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db2, profileSQL, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)

        let entry = try XCTUnwrap(result.report.data.first)
        // Counted once using the newer profile observation, not the stale default copy.
        XCTAssertEqual(entry.totalTokens, 600)
        XCTAssertEqual(entry.modelBreakdowns?.first?.modelName, "new-model")
        #endif
    }

    func testNewerProfileModelRowsSuppressOlderSessionResidual() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let defaultDB = self.tempDirectory.appendingPathComponent("state.db")
        let profileDB = self.tempDirectory.appendingPathComponent("profiles/dev/state.db")
        guard let db1 = self.createDatabase(at: defaultDB),
              let db2 = self.createDatabase(at: profileDB)
        else {
            XCTFail("Failed to create test databases")
            return
        }
        defer {
            sqlite3_close(db1)
            sqlite3_close(db2)
        }

        let now = Date().timeIntervalSince1970
        let stale = now - 60
        let defaultSQL = """
        INSERT INTO sessions (
            id, model, started_at, last_activity_at, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_residual_merge', 'old-session-model', \(stale), \(stale), 1, 100, 0
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_residual_merge', 'new-model', 'provider', 1,
            60, 0, \(stale), \(stale)
        );
        """
        let profileSQL = """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_residual_merge', 'new-model', 'provider', 1,
            60, 0, \(now), \(now)
        );
        """
        XCTAssertEqual(sqlite3_exec(db1, defaultSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db2, profileSQL, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(entry.modelBreakdowns?.count, 2)
        XCTAssertEqual(entry.modelBreakdowns?.first?.modelName, "new-model")
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "new-model" })?.totalTokens),
            60)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "old-session-model" })?.totalTokens),
            40)
        #endif
    }

    func testProfileScopedHomeDoesNotReadSiblingProfiles() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let root = self.tempDirectory.appendingPathComponent("hermes-root", isDirectory: true)
        let selectedDir = root.appendingPathComponent("profiles/selected", isDirectory: true)
        let siblingDir = root.appendingPathComponent("profiles/sibling", isDirectory: true)
        let selectedDB = selectedDir.appendingPathComponent("state.db")
        let siblingDB = siblingDir.appendingPathComponent("state.db")
        guard let selected = self.createDatabase(at: selectedDB),
              let sibling = self.createDatabase(at: siblingDB)
        else {
            XCTFail("Failed to create profile databases")
            return
        }
        defer {
            sqlite3_close(selected)
            sqlite3_close(sibling)
        }

        let now = Date().timeIntervalSince1970
        let selectedSQL = """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('selected', 'selected-model', 'provider', 1, 8, 2, \(now), \(now));
        """
        let siblingSQL = """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('sibling', 'sibling-model', 'provider', 1, 80, 20, \(now), \(now));
        """
        XCTAssertEqual(sqlite3_exec(selected, selectedSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(sibling, siblingSQL, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: selectedDir)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(result.report.data.first?.totalTokens, 10)
        #endif
    }

    func testCancellationPromptlyAborts() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        sqlite3_close(db)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(
            context: context,
            checkCancellation: { throw CancellationError() })
        XCTAssertEqual(result.coverage, .partial)
        #endif
    }

    func testEndToEndCostUsageFetcherSnapshot() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, started_at) VALUES ('sess_e2e', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, first_seen, last_seen
        ) VALUES (
            'sess_e2e', 'hermes-e2e-model', 'nous', 1, 1000, 500,
            0.12, \(now), \(now)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        let env = ["HERMES_HOME": self.tempDirectory.path]
        let fetcher = CostUsageFetcher()
        let snapshot = try await fetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: env,
            now: Date(),
            historyDays: 30)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot.sessionTokens, 1500)
        XCTAssertEqual(snapshot.last30DaysTokens, 1500)
        XCTAssertEqual(snapshot.sessionCostUSD, 0.12)
        XCTAssertEqual(snapshot.last30DaysCostUSD, 0.12)
        XCTAssertEqual(snapshot.sessionRequests, 1)
        XCTAssertEqual(snapshot.last30DaysRequests, 1)
        XCTAssertEqual(snapshot.costProvenance, .listPriceEstimate)
        #endif
    }

    func testVendorMeteredCostProvenanceIsPreserved() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, started_at) VALUES ('sess_metered', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES (
            'sess_metered', 'hermes-metered-model', 'nous', 1, 100, 50,
            0.12, 'actual', 'provider_cost_api', \(now), \(now)
        );
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        XCTAssertEqual(result.report.data.first?.costUSD, 0.12)
        #endif
    }

    func testAuthoritativeSessionCostWinsWhenModelProvenanceDiffers() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (
            id, model, started_at, api_call_count, input_tokens, output_tokens,
            actual_cost_usd, cost_status, cost_source
        ) VALUES (
            'sess_authoritative', 'hermes-authoritative-model', \(now), 1, 100, 50,
            0.12, 'actual', 'provider_cost_api'
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES (
            'sess_authoritative', 'hermes-authoritative-model', 'nous', 1, 100, 50,
            0.05, 0.0, 'estimated', 'official_docs_snapshot', \(now), \(now)
        );
        """
        XCTAssertEqual(
            sqlite3_exec(db, sql, nil, nil, nil),
            SQLITE_OK,
            String(cString: sqlite3_errmsg(db)))

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 150)
        XCTAssertEqual(entry.costUSD, 0.12)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        XCTAssertEqual(entry.modelBreakdowns?.first?.costUSD, 0.12)
        #endif
    }

    func testKnownEstimatedSessionCostSurvivesUnknownModelCost() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (
            id, model, started_at, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, cost_status, cost_source
        ) VALUES (
            'sess_estimated_authoritative', 'hermes-estimated-model', \(now), 1, 100, 0,
            0.20, 'estimated', 'official_docs_snapshot'
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES (
            'sess_estimated_authoritative', 'hermes-estimated-model', 'nous', 1, 100, 0,
            0.0, 0.0, 'unknown', 'none', \(now), \(now)
        );
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.20, accuracy: 0.0001)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .listPriceEstimate)
        #endif
    }

    func testSameProvenanceModelCostsAreCappedAtSessionTotal() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (
            id, model, started_at, api_call_count, input_tokens, output_tokens,
            actual_cost_usd, cost_status, cost_source
        ) VALUES (
            'sess_cost_cap', 'session-model', \(now), 2, 200, 100,
            0.10, 'actual', 'provider_cost_api'
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES
            ('sess_cost_cap', 'model-a', 'nous', 1, 100, 50,
             0.08, 'actual', 'provider_cost_api', \(now), \(now)),
            ('sess_cost_cap', 'model-b', 'nous', 1, 100, 50,
             0.08, 'actual', 'provider_cost_api', \(now), \(now));
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.10, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns).compactMap(\.costUSD).reduce(0, +),
            0.10,
            accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(entry.modelBreakdowns).compactMap { breakdown in
                breakdown.modelName == "model-a" ? breakdown.costUSD : nil
            }.first),
            0.05,
            accuracy: 0.0001)
        #endif
    }

    func testCostProvenanceDoesNotRequirePositiveAPICallCount() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: dbURL) else {
            XCTFail("Failed to create test database")
            return
        }
        defer { sqlite3_close(db) }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO sessions (id, model, started_at) VALUES
            ('sess_actual_zero_calls', 'actual-zero-calls', \(now)),
            ('sess_estimated_zero_calls', 'estimated-zero-calls', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES
            ('sess_actual_zero_calls', 'actual-zero-calls', 'provider', 0, 10, 1,
             0.05, 0.05, 'actual', 'provider_cost_api', \(now), \(now)),
            ('sess_estimated_zero_calls', 'estimated-zero-calls', 'provider', 0, 20, 2,
             0.07, 0.07, 'estimated', 'official_docs_snapshot', \(now), \(now));
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertNil(entry.requestCount)
        XCTAssertEqual(entry.coverageCounts, CostUsageCoverageCounts())
        XCTAssertEqual(entry.pricedRequestCount, 0)
        XCTAssertEqual(entry.estimatedRequestCount, 0)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .mixed)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: ["HERMES_HOME": self.tempDirectory.path],
            now: Date(timeIntervalSince1970: now),
            historyDays: 1)
        XCTAssertEqual(snapshot.costProvenance, .mixed)
        #endif
    }
}

extension HermesLocalReaderTests {
    func testNewerProfileModelRowsPreserveUnmatchedSessionCalls() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let defaultDB = self.tempDirectory.appendingPathComponent("state.db")
        let profileDB = self.tempDirectory.appendingPathComponent("profiles/dev/state.db")
        guard let db1 = self.createDatabase(at: defaultDB),
              let db2 = self.createDatabase(at: profileDB)
        else {
            XCTFail("Failed to create test databases")
            return
        }
        defer {
            sqlite3_close(db1)
            sqlite3_close(db2)
        }

        let now = Date().timeIntervalSince1970
        let stale = now - 60
        let defaultSQL = """
        INSERT INTO sessions (
            id, model, started_at, last_activity_at, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_request_residual_merge', 'old-session-model', \(stale), \(stale), 10, 100, 0
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_request_residual_merge', 'new-model', 'provider', 5,
            60, 0, \(stale), \(stale)
        );
        """
        let profileSQL = """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_request_residual_merge', 'new-model', 'provider', 5,
            100, 0, \(now), \(now)
        );
        """
        XCTAssertEqual(sqlite3_exec(db1, defaultSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db2, profileSQL, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(entry.requestCount, 10)
        XCTAssertEqual(entry.modelBreakdowns?.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "new-model" })?.requestCount),
            5)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "old-session-model" })?.requestCount),
            5)
        #endif
    }

    func testNewerProfileModelCostsAreSubtractedFromOlderSessionResidual() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let defaultDB = self.tempDirectory.appendingPathComponent("state.db")
        let profileDB = self.tempDirectory.appendingPathComponent("profiles/dev/state.db")
        guard let db1 = self.createDatabase(at: defaultDB),
              let db2 = self.createDatabase(at: profileDB)
        else {
            XCTFail("Failed to create test databases")
            return
        }
        defer {
            sqlite3_close(db1)
            sqlite3_close(db2)
        }

        let now = Date().timeIntervalSince1970
        let defaultSQL = """
        INSERT INTO sessions (
            id, model, billing_provider, started_at, last_activity_at, api_call_count, input_tokens, output_tokens,
            actual_cost_usd, cost_status, cost_source
        ) VALUES (
            'sess_residual_cost_merge', 'old-session-model', 'provider', \(now - 60), \(now - 60), 1, 100, 0,
            1.00, 'actual', 'provider_cost_api'
        );
        """
        let profileSQL = """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        ) VALUES (
            'sess_residual_cost_merge', 'new-model', 'provider', 1,
            100, 0, 0.40, 'actual', 'provider_cost_api', \(now), \(now)
        );
        """
        XCTAssertEqual(sqlite3_exec(db1, defaultSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db2, profileSQL, nil, nil, nil), SQLITE_OK)

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 1.00, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns).compactMap(\.costUSD).reduce(0, +),
            1.00,
            accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(entry.modelBreakdowns).first(where: { $0.modelName == "new-model" })?.costUSD),
            0.40,
            accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(entry.modelBreakdowns).first(where: { $0.modelName == "old-session-model" })?
                .costUSD),
            0.60,
            accuracy: 0.0001)
        #endif
    }
}

import CodexBarCore
import Foundation
import SQLite3
import Testing

@testable import CodexBarCore

/// Gating tests for the opt-in machine-local OpenCode history source (#3273 contract):
/// it may only join the ambient Codex ledger, never scoped homes, other providers, or a
/// default-off configuration.
@Suite(.serialized)
struct OpenCodeLocalHistoryMergeTests {
    @Test
    func `ambient codex scan merges opt-in opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let merged = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect(merged.snapshot.last30DaysTokens == 35)
        // Recorded $0 cost (subscription usage) is preserved as-is, never reinterpreted.
        #expect(merged.snapshot.last30DaysCostUSD == 0)
        // Rows keep a visible source label instead of silently merging into native totals.
        let model = try #require(merged.snapshot.daily.first?.modelsUsed?.first)
        #expect(model.hasSuffix("(OpenCode local)"))
        // Grouped accounting carries the rows: the unattributed bucket holds the OpenCode
        // daily data, and session breakdowns stay native (empty here, no native sessions).
        let unattributed = try #require(
            merged.snapshot.projects.first { $0.name == CostUsageProjectBreakdown.unknownProjectName })
        #expect(unattributed.daily.first?.totalTokens == 35)
        #expect(merged.snapshot.sessions.isEmpty)
        // Only recorded rows are present, so the snapshot must not claim list-price estimation.
        #expect(merged.snapshot.costProvenance == .sourceRecorded)
    }

    @Test
    func `mixed history separates recorded costs from the list-price claim`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        try Self.writeNativeCodexSession(env: env, day: day, filename: "mixed-native.jsonl", tokens: 100)

        var scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        scannerOptions.refreshMinIntervalSeconds = 0
        let merged = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: [
                "OPENCODE_DB": databaseURL.path,
                "HOME": env.root.path,
            ],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        // Native (estimated) and OpenCode (recorded) rows both contribute.
        #expect(merged.snapshot.last30DaysTokens == 135)
        // Grouped totals keep both: the native project and the unattributed bucket.
        let nativeProject = try #require(merged.snapshot.projects.first {
            $0.name != CostUsageProjectBreakdown.unknownProjectName
        })
        #expect(nativeProject.totalTokens == 100)
        let unattributed = try #require(
            merged.snapshot.projects.first { $0.name == CostUsageProjectBreakdown.unknownProjectName })
        #expect(unattributed.totalTokens == 35)
        // Session breakdowns cannot attribute OpenCode rows and stay native.
        #expect(merged.snapshot.sessions.isEmpty)
        // The window mixes estimated and recorded costs; a pure list-price claim would be false.
        #expect(merged.snapshot.costProvenance == .mixed)
        let window = merged.snapshot.summary(forLastDays: 1, calendar: scannerOptions.calendar)
        #expect(window.provenance == .mixed)
        // Per-day entries keep the recorded marker so cached windows stay truthful too.
        #expect(merged.snapshot.daily.contains { $0.costIsSourceRecorded })
    }

    @Test
    func `narrow window of a mixed snapshot stays source recorded`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let olderDay = try env.makeLocalNoon(year: 2026, month: 4, day: 5)
        // OpenCode recorded cost lands on the recent day; the priced native session is
        // two days older, so the snapshot is mixed but today's window is recorded-only.
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        try Self.writeNativeCodexSession(
            env: env,
            day: olderDay,
            filename: "older-priced-native.jsonl",
            tokens: 100)

        var scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        scannerOptions.refreshMinIntervalSeconds = 0
        let merged = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: [
                "OPENCODE_DB": databaseURL.path,
                "HOME": env.root.path,
            ],
            now: day,
            historyDays: 7,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        // The full snapshot is mixed: list-priced native rows and recorded OpenCode rows.
        #expect(merged.snapshot.costProvenance == .mixed)
        // A window covering both days is mixed too.
        #expect(merged.snapshot.summary(forLastDays: 7, calendar: scannerOptions.calendar).provenance == .mixed)
        // But the one-day window holds only the recorded row: no list-price amount exists
        // in it, so claiming a mixed estimate would be false.
        let today = merged.snapshot.summary(forLastDays: 1, calendar: scannerOptions.calendar)
        #expect(today.provenance == .sourceRecorded)
        #expect(today.totalCostUSD != nil)
    }

    @Test
    func `unpriced native history keeps provenance source recorded`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        // A native model with no list price contributes tokens only; its rows carry no cost,
        // so a mixed provenance would claim an estimate that is not actually included.
        try Self.writeNativeCodexSession(
            env: env,
            day: day,
            filename: "unpriced-native.jsonl",
            tokens: 100,
            model: "unknown-unpriced-model")

        var scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        scannerOptions.refreshMinIntervalSeconds = 0
        let merged = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: [
                "OPENCODE_DB": databaseURL.path,
                "HOME": env.root.path,
            ],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        // Tokens still merge from both sources.
        #expect(merged.snapshot.last30DaysTokens == 135)
        // But the cost claim stays recorded-only: no native list-price amount exists.
        #expect(merged.snapshot.costProvenance == .sourceRecorded)
        let window = merged.snapshot.summary(forLastDays: 1, calendar: scannerOptions.calendar)
        #expect(window.provenance == .sourceRecorded)
    }

    @Test
    func `ambient codex scan stays native when the source is off`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let native = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: false,
            scannerOptions: scannerOptions)

        #expect((native.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `scoped codex home never merges opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let scopedHome = env.root.appendingPathComponent("scoped-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedHome, withIntermediateDirectories: true)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: scopedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let scoped = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            codexHomePath: scopedHome.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect((scoped.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `environment selected codex home never merges opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let selectedHome = env.root.appendingPathComponent("selected-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedHome, withIntermediateDirectories: true)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: selectedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let scoped = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: [
                "OPENCODE_DB": databaseURL.path,
                "CODEX_HOME": selectedHome.path,
            ],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect((scoped.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `claude scans never merge opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let claude = try await CostUsageFetcher.loadTokenResult(
            provider: .claude,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect((claude.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `cached codex publication merges opt-in opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let scanTime = day.addingTimeInterval(-60)
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(scanTime.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-04-07"
        cache.scanUntilKey = "2026-04-09"
        cache.timeZoneIdentifier = options.calendar.timeZone.identifier
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)

        // The cached publication reads only the OpenCode store's durable cache, so a scan
        // populates it first — exactly how production reaches the cached path after the
        // foreground scan has already persisted entries.
        _ = try OpenCodeLocalHistoryStore(
            cacheRoot: env.cacheRoot,
            environment: ["OPENCODE_DB": databaseURL.path])
            .loadDailyReport(since: day.addingTimeInterval(-86400), until: day, calendar: options.calendar)

        let merged = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            historyDays: 1,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect(merged?.snapshot.last30DaysTokens == 35)
        // Catch-up publication converges on the same grouped accounting and provenance.
        #expect(merged?.snapshot.costProvenance == .sourceRecorded)
        #expect(merged?.snapshot.projects.contains {
            $0.name == CostUsageProjectBreakdown.unknownProjectName
        } == true)
        #expect(merged?.snapshot.sessions.isEmpty == true)

        let native = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            historyDays: 1,
            includePiSessions: false,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect(native?.snapshot.last30DaysTokens == 0)
        #expect(native?.snapshot.costProvenance == .listPriceEstimate)
    }

    @Test
    func `cached scoped codex publication stays native`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let scopedHome = env.root.appendingPathComponent("scoped-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedHome, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: scopedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-04-07"
        cache.scanUntilKey = "2026-04-09"
        cache.timeZoneIdentifier = options.calendar.timeZone.identifier
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)

        let scoped = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            codexHomePath: scopedHome.path,
            historyDays: 1,
            allowScopedCodexHome: true,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect((scoped?.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `cached publication honors environment selected codex homes`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let selectedHome = env.root.appendingPathComponent("selected-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedHome, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: selectedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-04-07"
        cache.scanUntilKey = "2026-04-09"
        cache.timeZoneIdentifier = options.calendar.timeZone.identifier
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)

        let scoped = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            historyDays: 1,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: options,
            environment: [
                "OPENCODE_DB": databaseURL.path,
                "CODEX_HOME": selectedHome.path,
            ])
        #expect((scoped?.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `entries persisted before this feature decode without the recorded marker`() throws {
        // A pre-feature cache entry carries every field this feature reads, plus none of the
        // new ones. Upgrading must keep that stored data loading instead of discarding it.
        let legacyJSON = """
        {
          "date": "2026-04-08",
          "inputTokens": 30,
          "outputTokens": 5,
          "totalTokens": 35,
          "requestCount": 1,
          "costUSD": 0.5,
          "modelsUsed": ["gpt-5.1-codex"],
          "modelBreakdowns": [
            {"modelName": "gpt-5.1-codex", "costUSD": 0.5, "totalTokens": 35, "requestCount": 1}
          ]
        }
        """
        let entry = try JSONDecoder().decode(
            CostUsageDailyReport.Entry.self, from: Data(legacyJSON.utf8))
        #expect(entry.totalTokens == 35)
        #expect(entry.costUSD == 0.5)
        #expect(entry.costIsSourceRecorded == false)
        // Re-encoding round-trips the new field so refreshed caches stay self-describing.
        let reencoded = try JSONDecoder().decode(
            CostUsageDailyReport.Entry.self, from: JSONEncoder().encode(entry))
        #expect(reencoded == entry)
        // A recorded entry must survive its own encode/decode round trip.
        let recorded = CostUsageDailyReport.Entry(
            date: "2026-04-08",
            inputTokens: 30,
            outputTokens: 5,
            totalTokens: 35,
            requestCount: 1,
            costUSD: 0,
            modelsUsed: ["gpt-5.1-codex (OpenCode local)"],
            modelBreakdowns: [
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "gpt-5.1-codex (OpenCode local)",
                    costUSD: 0,
                    totalTokens: 35,
                    requestCount: 1),
            ],
            costIsSourceRecorded: true)
        let recordedData = try JSONEncoder().encode(recorded)
        let recordedJSON = try #require(String(data: recordedData, encoding: .utf8))
        #expect(recordedJSON.contains("\"costIsSourceRecorded\":true"))
        let decodedRecorded = try JSONDecoder().decode(CostUsageDailyReport.Entry.self, from: recordedData)
        #expect(decodedRecorded.costIsSourceRecorded == true)
        #expect(decodedRecorded == recorded)
    }

    /// Writes one native Codex JSONL session with the given token count, so mixed-history
    /// tests can assert how estimated and recorded rows combine.
    private static func writeNativeCodexSession(
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        tokens: Int,
        model: String = "gpt-5.4") throws
    {
        var partition = Calendar(identifier: .gregorian)
        partition.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = partition.dateComponents([.year, .month, .day], from: day)
        let directory = env.codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", components.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day.addingTimeInterval(-2)),
                "payload": [
                    "id": "opencode-merge-\(filename)",
                    "cwd": env.root.appendingPathComponent("merge-project", isDirectory: true).path,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day.addingTimeInterval(-1)),
                "payload": ["model": model, "turn_id": "opencode-merge-turn"],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": model,
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                    ],
                ],
            ],
        ]).write(
            to: directory.appendingPathComponent(filename, isDirectory: false),
            atomically: true,
            encoding: .utf8)
    }

    /// Builds an OpenCode SQLite database with one `openai` assistant record (35 tokens,
    /// recorded $0 cost) plus one `nchc` record that must never be selected.
    private static func makeOpenCodeDatabase(root: URL, day: Date) throws -> URL {
        let databaseURL = root.appendingPathComponent("opencode-local.db", isDirectory: false)
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
            """)
        let createdMs = Int64(day.timeIntervalSince1970 * 1000)
        try Self.insertRow(
            db: db,
            json: Self.json([
                "providerID": "openai",
                "role": "assistant",
                "modelID": "gpt-5.1-codex",
                "cost": 0,
                "time": ["created": createdMs],
                "tokens": ["input": 30, "output": 5, "total": 35]]),
            createdMs: createdMs)
        try Self.insertRow(
            db: db,
            json: Self.json([
                "providerID": "nchc",
                "role": "assistant",
                "modelID": "glm-5.3-max",
                "cost": 9,
                "time": ["created": createdMs],
                "tokens": ["input": 900, "output": 90, "total": 990]]),
            createdMs: createdMs)
        return databaseURL
    }

    private static func insertRow(db: OpaquePointer?, json: String, createdMs: Int64) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func json(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case exec
    }
}

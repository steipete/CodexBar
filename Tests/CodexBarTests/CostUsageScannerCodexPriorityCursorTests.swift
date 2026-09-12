import CryptoKit
import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerCodexPriorityCursorTests {
    @Test
    func `relaunch reuses persisted priority cursor and scans only appended rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = (0..<50).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.databasePath == dbURL.path)
        #expect(persisted.lastRowID == 51)
        let firstMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(firstMemo.lastRowID == 51)
        #expect(firstMemo.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.fileIdentity == firstMemo.fileIdentity)
        #expect(persisted.fileIdentity != nil)
        #expect(firstMemo.anchorRowID == firstMemo.lastRowID)
        #expect(!firstMemo.anchorDigest.isEmpty)
        #expect(persisted.anchorRowID == firstMemo.anchorRowID)
        #expect(persisted.anchorDigest == firstMemo.anchorDigest)
        #expect(persisted.anchors?.count == 4)
        #expect(persisted.anchors?.last?.rowID == persisted.anchorRowID)
        #expect(persisted.anchors?.last?.digest == persisted.anchorDigest)
        let downgrade = try JSONDecoder().decode(
            LegacyCursorProjection.self,
            from: JSONEncoder().encode(persisted))
        #expect(downgrade.anchorRowID == persisted.anchorRowID)
        #expect(downgrade.anchorDigest == persisted.anchorDigest)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "mutated", turnID: "mutated-old"))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))])

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))

        let relaunched = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(relaunched.turns.keys.sorted() == ["turn-a", "turn-b"])
        #expect(relaunched.lastRowID == firstMemo.lastRowID + 1)
        #expect(relaunched.anchorRowID == relaunched.lastRowID)
        #expect(relaunched.anchorDigest != firstMemo.anchorDigest)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.lastRowID == firstMemo.lastRowID + 1)
        #expect(reloaded.databasePath == dbURL.path)
        #expect(reloaded.anchorRowID == relaunched.anchorRowID)
        #expect(reloaded.anchorDigest == relaunched.anchorDigest)
    }

    @Test
    func `persisted cursor still full scans after the database inode changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.fileIdentity != nil)
        #expect(persisted.turns.keys.sorted() == ["turn-a", "turn-b"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try FileManager.default.removeItem(at: dbURL)
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-c", turnID: "turn-c"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-d", turnID: "turn-d"))

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))
        let replaced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(replaced.turns.keys.sorted() == ["turn-c", "turn-d"])
        #expect(replaced.lastRowID == 2)
        #expect(replaced.fileIdentity != persisted.fileIdentity)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.turns.keys.sorted() == ["turn-c", "turn-d"])
        #expect(reloaded.fileIdentity == replaced.fileIdentity)
    }

    @Test
    func `replaced database with a reused inode still full scans when the content anchor mismatches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        let originalRowCount = 20
        var originalRows: [(epochSeconds: Int64, body: String)] = (0..<(originalRowCount - 1)).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        originalRows.append((
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: originalRows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.lastRowID == Int64(originalRowCount))
        #expect(persisted.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.anchorRowID == persisted.lastRowID)
        #expect(!persisted.anchorDigest.isEmpty)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try FileManager.default.removeItem(at: dbURL)
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        var replacementRows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x")),
        ]
        replacementRows.append(contentsOf: (1..<originalRowCount).map { index in
            (epochSeconds: epoch, body: "thread_id=r-\(index) turn.id=v-\(index) replacement filler")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: replacementRows)

        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let freshMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(freshTurns.keys.sorted() == ["turn-x"])
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)

        let replacementIdentity = try #require(
            CostUsageScanner._test_codexPriorityDatabaseFileIdentity(at: dbURL))
        var stale = persisted
        stale.fileIdentity = replacementIdentity
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: dbURL)

        let resumedTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let resumedMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(resumedTurns == freshTurns)
        #expect(resumedTurns.keys.sorted() == ["turn-x"])
        #expect(!resumedTurns.keys.contains("turn-a"))
        #expect(resumedMemo.lastRowID == freshMemo.lastRowID)
        #expect(resumedMemo.lastRowID == Int64(originalRowCount))

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(
            Self.persistedCursor(from: freshMemo, databasePath: dbURL.path),
            databaseURL: dbURL)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-y", turnID: "turn-y"))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-z", turnID: "turn-z"))])
        let incremental = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let incrementalMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(incremental.keys.sorted() == ["turn-y", "turn-z"])
        #expect(!incremental.keys.contains("turn-x"))
        #expect(incrementalMemo.lastRowID == freshMemo.lastRowID + 1)
        #expect(incrementalMemo.anchorRowID == incrementalMemo.lastRowID)
    }

    @Test
    func `deleted terminal anchor with surviving quorum resumes incrementally`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (1..<8).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.lastRowID == 8)
        #expect(persisted.turns.keys.sorted() == ["turn-a"])
        #expect(persisted.anchorRowID == persisted.lastRowID)
        #expect(persisted.anchors?.map(\.rowID) == [2, 4, 6, 8])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 3,
            body: Self.priorityRequestBody(threadID: "sentinel", turnID: "sentinel-old-row"))
        try Self.deleteTestLog(dbURL: dbURL, rowID: persisted.lastRowID)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(turns.keys.sorted() == ["turn-a", "turn-new"])
        #expect(!turns.keys.contains("sentinel-old-row"))
        #expect(memo.lastRowID == persisted.lastRowID + 1)
        #expect(memo.anchors?.count == 4)
        #expect(!((memo.anchors ?? []).contains { $0.rowID == persisted.anchorRowID }))
    }

    @Test
    func `pruned tracked request and completion preserve cold scan parity`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        let rows: [(epochSeconds: Int64, body: String)] = [
            (epoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
            (epoch, Self.completedBody(turnID: "turn-a", model: "model-a")),
            (epoch, Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b")),
            (epoch, Self.completedBody(turnID: "turn-b", model: "model-b")),
            (epoch, "routine trace row 5"),
            (epoch, "routine trace row 6"),
            (epoch, "routine trace row 7"),
            (epoch, "routine trace row 8"),
        ]
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.anchors?.map(\.rowID) == [2, 4, 6, 8])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.deleteTestLogs(dbURL: dbURL, rowIDs: [2, 3, 8])
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

        let resumedTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let resumed = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(resumedTurns == freshTurns)
        #expect(resumedTurns.keys.sorted() == ["turn-a", "turn-new"])
        #expect(resumedTurns["turn-a"]?.model == "gpt-5.5")
        #expect(resumedTurns["turn-a"]?.model != "model-a")
        #expect(resumed.anchors?.count == 4)
        #expect(!((resumed.anchors ?? []).contains { [2, 8].contains($0.rowID) }))
    }

    @Test
    func `changed retained priority source forces cold scan parity after terminal pruning`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (1..<8).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        try Self.deleteTestLog(dbURL: dbURL, rowID: persisted.lastRowID)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

        let resumedTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let resumedMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(resumedTurns == freshTurns)
        #expect(resumedTurns.keys.sorted() == ["turn-new", "turn-x"])
        #expect(!resumedTurns.keys.contains("turn-a"))
        #expect(resumedMemo.requestSourcesByTurnID["turn-x"]?.keys.contains(1) == true)
    }

    @Test
    func `failed fallback cold scan leaves refresh uncommitted until retry succeeds`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer {
            CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL, nil)
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (1..<8).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)
        try Self.writeCodexSession(env: env, now: now)

        let initialReport = Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let initialCursor = try #require(initialCache.codexPriorityTurnsCursor)
        let initialLastScanUnixMs = initialCache.lastScanUnixMs
        #expect(initialCursor.turns.keys.sorted() == ["turn-a"])
        #expect((initialReport.data.first?.modelBreakdowns?.first?.priorityCostUSD ?? 0) > 0)
        #expect(initialCursor.anchors?.map(\.rowID) == [2, 4, 6, 8])
        #expect(initialCache.codexScanCatchUpPending != true)
        #expect(initialCache.lastScanUnixMs > 0)

        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        var faultHookCalls = 0
        CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL) { db in
            faultHookCalls += 1
            sqlite3_progress_handler(db, 1, { _ in 1 }, nil)
        }

        let failedReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))
        #expect(faultHookCalls > 0)
        #expect(failedReport.data == initialReport.data)
        #expect(failedReport.summary == initialReport.summary)
        let failedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(failedCache.codexScanCatchUpPending != true)
        #expect(failedCache.lastScanUnixMs == initialLastScanUnixMs)
        #expect(failedCache.codexPriorityTurnsCursor == initialCursor)
        let retainedMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(retainedMemo.turns == initialCursor.turns)

        CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL, nil)
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now.addingTimeInterval(2))
        let retriedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let retriedCursor = try #require(retriedCache.codexPriorityTurnsCursor)
        #expect(retriedCache.codexScanCatchUpPending != true)
        #expect(retriedCache.lastScanUnixMs > initialLastScanUnixMs)
        #expect(retriedCursor.turns.keys.sorted() == ["turn-x"])
        #expect(!retriedCursor.turns.keys.contains("turn-a"))
    }

    @Test
    func `trace open failure retains persisted priority pricing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let backupURL = env.root.appendingPathComponent("logs_2.backup.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ])
        try Self.writeCodexSession(env: env, now: now)

        let initialReport = Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let initialCursor = try #require(initialCache.codexPriorityTurnsCursor)
        let initialLastScanUnixMs = initialCache.lastScanUnixMs
        #expect((initialReport.data.first?.modelBreakdowns?.first?.priorityCostUSD ?? 0) > 0)
        let preparedCache = Self.cacheRequiringPricingMetadataMigration(initialCache)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: preparedCache)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        for (path, usage) in preparedCache.files {
            let rows = try (usage.codexRows ?? []).enumerated().map { index, row in
                try CostUsageStoreUsageRow(
                    path: path,
                    rowIndex: index,
                    payload: JSONEncoder().encode(row))
            }
            #expect(await store.replaceUsageRows(path: path, rows: rows))
        }
        let migrationCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let migrationRows = migrationCache.files.values.flatMap { $0.codexRows ?? [] }
        #expect(!migrationRows.isEmpty)
        #expect(migrationRows.allSatisfy { $0.pricingMode == nil })
        #expect(migrationCache.files.values.allSatisfy { $0.codexPriorityTokens == nil })

        try FileManager.default.moveItem(at: dbURL, to: backupURL)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: false)
        let pendingReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1))

        #expect(pendingReport.data == initialReport.data)
        #expect(pendingReport.summary == initialReport.summary)
        let pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(pendingCache.lastScanUnixMs == initialLastScanUnixMs)
        #expect(pendingCache.codexPriorityTurnsCursor == initialCursor)

        try FileManager.default.removeItem(at: dbURL)
        try FileManager.default.moveItem(at: backupURL, to: dbURL)
        let retriedReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(2))
        #expect(retriedReport.data == initialReport.data)
        #expect(retriedReport.summary == initialReport.summary)
    }

    @Test
    func `historical trace read failure retains persisted priority pricing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let backupURL = env.root.appendingPathComponent("logs_2.backup.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let historicalDay = try #require(Calendar.current.date(byAdding: .day, value: -10, to: now))
        let epoch = Int64(historicalDay.timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
            (epochSeconds: epoch, body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ])
        try Self.writeCodexSession(env: env, now: historicalDay)

        _ = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: now,
            now: now)
        let expectedReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(1))
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let initialCursor = try #require(initialCache.codexPriorityTurnsCursor)
        let initialLastScanUnixMs = initialCache.lastScanUnixMs
        #expect((expectedReport.data.first?.modelBreakdowns?.first?.priorityCostUSD ?? 0) > 0)

        let preparedCache = Self.cacheRequiringPricingMetadataMigration(initialCache)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: preparedCache)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        for (path, usage) in preparedCache.files {
            let rows = try (usage.codexRows ?? []).enumerated().map { index, row in
                try CostUsageStoreUsageRow(
                    path: path,
                    rowIndex: index,
                    payload: JSONEncoder().encode(row))
            }
            #expect(await store.replaceUsageRows(path: path, rows: rows))
        }

        try FileManager.default.moveItem(at: dbURL, to: backupURL)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: false)
        let pendingReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(2))

        #expect(pendingReport.data == expectedReport.data)
        #expect(pendingReport.summary == expectedReport.summary)
        let pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(pendingCache.lastScanUnixMs == initialLastScanUnixMs)
        #expect(pendingCache.codexPriorityTurnsCursor == initialCursor)
    }

    @Test(arguments: [
        (false, false, false, false), (false, true, false, false), (true, false, false, false),
        (false, false, true, false), (false, true, true, false), (true, false, true, false),
        (true, false, false, true), (true, false, true, true),
    ])
    func `historical correction survives trace failure and relaunch`(
        replacementPriority: Bool,
        legacyCache: Bool,
        missingTraceFile: Bool,
        forceRescan: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let backupURL = env.root.appendingPathComponent("logs_2.backup.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let historicalDay = try #require(Calendar.current.date(byAdding: .day, value: -10, to: now))
        let historicalEpoch = Int64(historicalDay.timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
            (historicalEpoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
            (Int64(now.timeIntervalSince1970), Self.priorityRequestBody(threadID: "outside", turnID: "outside")),
        ])
        try Self.writeCodexSession(env: env, now: historicalDay)
        try Self.writeCodexSession(env: env, now: now, turnID: "outside")
        let initialReport = Self.loadCodexDailyReport(
            env: env, databaseURL: dbURL, since: historicalDay, until: now, now: now)
        let initialHistoricalCost = try #require(initialReport.data.first?.costUSD)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let initialCursor = try #require(initialCache.codexPriorityTurnsCursor)
        #expect(initialCursor.turns.keys.sorted() == ["outside", "turn-a"])
        let outsideKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        let initialOutside = initialCache.files.filter { $0.value.days[outsideKey] != nil }
        #expect(!initialOutside.isEmpty)

        try Self.deleteTestLog(dbURL: dbURL, rowID: 1)
        if replacementPriority {
            try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
                (historicalEpoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a", model: "gpt-5.4")),
            ])
        }
        var correctedReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(1))
        for _ in 0..<5 where CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == true {
            correctedReport = Self.loadCodexDailyReport(
                env: env,
                databaseURL: dbURL,
                since: historicalDay,
                until: historicalDay,
                now: now.addingTimeInterval(1))
        }
        correctedReport = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(1))
        var correctedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(correctedCache.codexScanCatchUpPending != true)
        #expect(correctedReport.summary?.totalTokens == 110)
        let breakdown = try #require(correctedReport.data.first?.modelBreakdowns?.first)
        // Pruning does not erase priority evidence already recorded on usage rows.
        #expect(breakdown.priorityTokens == 110)
        if replacementPriority {
            #expect(try #require(breakdown.costUSD) < initialHistoricalCost)
        }
        #expect(correctedCache.codexPriorityTurnsCursor == initialCursor)
        #expect(correctedCache.codexResolvedPriorityTurns?.keys.sorted()
            == (replacementPriority ? ["outside", "turn-a"] : ["outside"]))
        #expect(correctedCache.files.filter { $0.value.days[outsideKey] != nil } == initialOutside)
        let historicalRange = CostUsageScanner.CostUsageDayRange(since: historicalDay, until: historicalDay)
        let view = CostUsageStoreAccess.readView(cacheRoot: env.cacheRoot, calendar: .current, purpose: .report)
        #expect(view.dailyReport(range: historicalRange, cacheRoot: env.cacheRoot).summary == correctedReport.summary)
        #expect(view.projects(range: historicalRange, cacheRoot: env.cacheRoot).first?.totalCostUSD
            == correctedReport.summary?.totalCostUSD)
        #expect(view.sessions(range: historicalRange, cacheRoot: env.cacheRoot, roots: [env.codexSessionsRoot])
            .first?.costUSD == correctedReport.summary?.totalCostUSD)
        #expect(CostUsageScanner.buildCodexReportFromCache(cache: correctedCache, range: historicalRange).summary
            == correctedReport.summary)
        #expect(CostUsageScanner.buildCodexProjectBreakdownsFromCache(cache: correctedCache, range: historicalRange)
            .first?.totalCostUSD == correctedReport.summary?.totalCostUSD)
        #expect(CostUsageScanner.buildCodexSessionBreakdownsFromCache(cache: correctedCache, range: historicalRange)
            .first?.costUSD == correctedReport.summary?.totalCostUSD)
        let debounced = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(1.5),
            refreshMinIntervalSeconds: 60)
        #expect(debounced.data == correctedReport.data)
        #expect(debounced.summary == correctedReport.summary)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot) == correctedCache)
        if legacyCache {
            correctedCache.codexResolvedPriorityTurns = nil
            #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: correctedCache).catchUpRequired)
            correctedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        }

        try FileManager.default.moveItem(at: dbURL, to: backupURL)
        if !missingTraceFile {
            try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: false)
        }
        for relaunched in [false, true] {
            if relaunched { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
            let pending = Self.loadCodexDailyReport(
                env: env,
                databaseURL: dbURL,
                since: historicalDay,
                until: historicalDay,
                now: now.addingTimeInterval(2),
                forceRescan: forceRescan)
            #expect(pending.data == correctedReport.data)
            #expect(pending.summary == correctedReport.summary)
            #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot) == correctedCache)
            let outsideReport = Self.loadCodexDailyReport(
                env: env, databaseURL: dbURL, now: now.addingTimeInterval(2))
            #expect(outsideReport.data.first?.modelBreakdowns?.first?.priorityTokens == 110)
            #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot) == correctedCache)
        }
        if !missingTraceFile { try FileManager.default.removeItem(at: dbURL) }
        try FileManager.default.moveItem(at: backupURL, to: dbURL)
        let retried = Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: historicalDay,
            until: historicalDay,
            now: now.addingTimeInterval(3))
        #expect(retried.data == correctedReport.data)
        #expect(retried.summary == correctedReport.summary)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).lastScanUnixMs > correctedCache.lastScanUnixMs)
    }

    @Test
    func `fallback fault hook is scoped to its database path`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let faultedDB = env.root.appendingPathComponent("faulted.sqlite")
        let unaffectedDB = env.root.appendingPathComponent("unaffected.sqlite")
        for dbURL in [faultedDB, unaffectedDB] {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
            try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
            let epoch = Int64(Date().timeIntervalSince1970)
            var rows: [(epochSeconds: Int64, body: String)] = [
                (epoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
            ]
            rows.append(contentsOf: (1..<8).map { index in
                (epoch, "routine trace row \(index)")
            })
            try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)
            _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
            try Self.updateTestLog(
                dbURL: dbURL,
                rowID: 1,
                body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        }
        defer {
            CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: faultedDB, nil)
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: faultedDB.path)
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: unaffectedDB.path)
        }

        CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: faultedDB) { db in
            sqlite3_progress_handler(db, 1, { _ in 1 }, nil)
        }

        let unaffected = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: unaffectedDB)
        let faulted = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: faultedDB)
        #expect(unaffected.validationPending == false)
        #expect(unaffected.turns.keys.sorted() == ["turn-x"])
        #expect(faulted.validationPending == true)
        #expect(faulted.turns.keys.sorted() == ["turn-a"])
    }

    @Test(arguments: [false, true], [false, true])
    func `trace failure never borrows a different report scope`(
        changedTimeZone: Bool,
        missingTraceFile: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let other = try CostUsageTestEnvironment()
        defer { other.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let backupURL = env.root.appendingPathComponent("logs_2.backup.sqlite")
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
            (Int64(now.timeIntervalSince1970), Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ])
        try Self.writeCodexSession(env: env, now: now)
        let initial = Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        #expect(initial.summary?.totalTokens == 110)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try FileManager.default.moveItem(at: dbURL, to: backupURL)
        if !missingTraceFile {
            try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: false)
        }
        var calendar = Calendar.current
        if changedTimeZone {
            calendar.timeZone = try #require(TimeZone(identifier:
                calendar.timeZone.identifier == "Pacific/Honolulu" ? "Asia/Tokyo" : "Pacific/Honolulu"))
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: changedTimeZone ? env.codexSessionsRoot : other.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL,
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        let pending = CostUsageScanner.loadDailyReport(
            provider: .codex, since: now, until: now, now: now.addingTimeInterval(1), options: options)
        if changedTimeZone, missingTraceFile {
            // A new day partition rejects the old cache and can freshly scan native usage without traces.
            #expect(pending.summary?.totalTokens == 110)
            #expect(pending.summary != initial.summary)
            #expect(pending.data.first?.modelBreakdowns?.first?.priorityTokens == nil)
            let updated = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
            #expect(updated.timeZoneIdentifier == calendar.timeZone.identifier)
            #expect(updated.codexResolvedPriorityTurns == [:])
            #expect(updated.codexPriorityTurnsCursor == nil)
        } else {
            #expect(pending.data.isEmpty)
            #expect(pending.summary == nil)
            #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot) == initialCache)
        }
    }

    @Test
    func `never observed trace paths do not block repeated usage scans`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let missingURL = env.root.appendingPathComponent("never-created.sqlite")
        let now = Date()
        try Self.writeCodexSession(env: env, now: now)
        let first = Self.loadCodexDailyReport(env: env, databaseURL: missingURL, now: now)
        #expect(first.summary?.totalTokens == 110)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(initialCache.codexResolvedPriorityTurns == [:])
        #expect(initialCache.codexPriorityMetadataKey == "missing:\(missingURL.path)")

        try Self.writeCodexSession(env: env, now: now, turnID: "turn-b")
        let second = Self.loadCodexDailyReport(
            env: env, databaseURL: missingURL, now: now.addingTimeInterval(1), forceRescan: true)
        #expect(second.summary?.totalTokens == 220)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).lastScanUnixMs > initialCache.lastScanUnixMs)
    }

    @Test
    func `new missing trace path does not inherit the old path requirement`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let missingURL = env.root.appendingPathComponent("new-missing.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try Self.writeCodexSession(env: env, now: now)
        _ = Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let initialCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(initialCache.codexPriorityMetadataKey == "sqlite:\(dbURL.path)")

        try Self.writeCodexSession(env: env, now: now, turnID: "turn-b")
        let report = Self.loadCodexDailyReport(
            env: env, databaseURL: missingURL, now: now.addingTimeInterval(1))
        #expect(report.summary?.totalTokens == 220)
        let updated = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(updated.codexPriorityMetadataKey == "missing:\(missingURL.path)")
        #expect(updated.lastScanUnixMs > initialCache.lastScanUnixMs)
    }

    @Test
    func `validated empty pricing evidence persists independently of the resume cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var cache = CostUsageCache()
        cache.codexResolvedPriorityTurns = ["turn-a": .init(
            threadID: "thread-a", turnID: "turn-a", model: "gpt-5.5", timestamp: "1788192000")]
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache).catchUpRequired)
        let loaded = CostUsageStoreAccess.load(cacheRoot: env.cacheRoot, calendar: .current)
        defer { loaded.release() }
        cache = loaded.cache
        cache.codexResolvedPriorityTurns = [:]
        let result = CostUsageStoreAccess.save(
            store: loaded.store,
            cache: cache,
            calendar: .current,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-31"),
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        #expect(!result.catchUpRequired)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexResolvedPriorityTurns == [:])
    }
}

extension CostUsageScannerCodexPriorityCursorTests {
    @Test
    func `changed surviving anchor forces a full rescan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows = (1...8).map { index in
            (epochSeconds: epoch, body: "routine trace row \(index)")
        }
        rows[3].body = Self.priorityRequestBody(threadID: "thread-stale", turnID: "turn-stale")
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.anchors?.map(\.rowID) == [2, 4, 6, 8])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(dbURL: dbURL, rowID: 4, body: "changed surviving anchor")
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(turns.keys.sorted() == ["turn-new"])
        #expect(!turns.keys.contains("turn-stale"))
    }

    @Test
    func `losing distributed anchor quorum forces a full rescan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (
                epochSeconds: epoch,
                body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (2...8).map { (epochSeconds: epoch, body: "routine trace row \($0)") })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(persisted.anchors?.map(\.rowID) == [2, 4, 6, 8])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        try Self.deleteTestLogs(dbURL: dbURL, rowIDs: [2, 4, 6])
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(turns.keys.sorted() == ["turn-new", "turn-x"])
        #expect(!turns.keys.contains("turn-a"))
    }

    @Test
    func `matched legacy anchor upgrades to distributed anchors`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: (1...8).map {
            (epochSeconds: epoch, body: "routine trace row \($0)")
        })
        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        var legacy = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        legacy.anchors = nil
        let legacyPayload = try JSONEncoder().encode(legacy)
        let legacyJSON = try #require(String(data: legacyPayload, encoding: .utf8))
        #expect(!legacyJSON.contains("\"anchors\""))
        legacy = try JSONDecoder().decode(
            CostUsageScanner.CodexPriorityTurnsPersistedCursor.self,
            from: legacyPayload)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(legacy, databaseURL: dbURL)
        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        let upgraded = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(upgraded.anchors?.map(\.rowID) == [2, 4, 6, 8])
        #expect(upgraded.anchorRowID == legacy.anchorRowID)
        #expect(upgraded.anchorDigest == legacy.anchorDigest)
    }

    @Test
    func `missing legacy anchor remains conservative`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows: [(epochSeconds: Int64, body: String)] = [
            (
                epochSeconds: epoch,
                body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
        ]
        rows.append(contentsOf: (2...8).map { (epochSeconds: epoch, body: "routine trace row \($0)") })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)
        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        var legacy = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        legacy.anchors = nil

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-x", turnID: "turn-x"))
        try Self.deleteTestLog(dbURL: dbURL, rowID: legacy.anchorRowID)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))])
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(legacy, databaseURL: dbURL)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(turns.keys.sorted() == ["turn-new", "turn-x"])
        #expect(!turns.keys.contains("turn-a"))
    }

    @Test
    func `small databases require every available anchor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let epoch = Int64(Date().timeIntervalSince1970)

        for rowCount in 1...3 {
            let dbURL = env.root.appendingPathComponent("small-\(rowCount).sqlite")
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
            defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
            try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
            try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: (1...rowCount).map {
                (epochSeconds: epoch, body: "routine trace row \($0)")
            })
            _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
            var persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
            let anchors = try #require(persisted.anchors)
            #expect(anchors.count == rowCount)
            persisted.turns["stale"] = CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: "stale",
                turnID: "stale",
                model: nil,
                timestamp: nil)

            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
            try Self.deleteTestLog(dbURL: dbURL, rowID: anchors[0].rowID)
            if rowCount == 1 {
                try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
                    epochSeconds: epoch,
                    body: "replacement row")])
            }
            CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)

            let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
            #expect(!turns.keys.contains("stale"))
        }
    }

    @Test
    func `missing anchor refreshes metadata without an appended tail`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: (1...8).map {
            (epochSeconds: epoch, body: "routine trace row \($0)")
        })
        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let persisted = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        let deletedRowID = try #require(persisted.anchors?.first?.rowID)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.deleteTestLog(dbURL: dbURL, rowID: deletedRowID)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(persisted, databaseURL: dbURL)
        _ = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        let refreshed = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL))
        #expect(refreshed.lastRowID == persisted.lastRowID)
        #expect(refreshed.anchors?.count == 4)
        #expect(!((refreshed.anchors ?? []).contains { $0.rowID == deletedRowID }))
    }

    @Test
    func `persisted cursor still full scans when the requested window expands earlier`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let today = Date()
        let thirtyDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -30, to: today))
        let fortyFiveDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -45, to: today))
        let sixtyDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -60, to: today))
        let formatter = ISO8601DateFormatter()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: fortyFiveDaysAgo),
            body: Self.priorityRequestBody(threadID: "thread-old", turnID: "turn-old"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: today),
            body: Self.priorityRequestBody(threadID: "thread-new", turnID: "turn-new"))

        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: thirtyDaysAgo,
            until: today,
            now: today)
        let narrowMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(narrowMemo.turns.keys.sorted() == ["turn-new"])
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.coverageSinceEpoch == narrowMemo.coverageSinceEpoch)
        #expect(persisted.turns.keys.sorted() == ["turn-new"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            since: sixtyDaysAgo,
            until: today,
            now: today.addingTimeInterval(1))
        let expanded = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(expanded.turns.keys.sorted() == ["turn-new", "turn-old"])
        #expect(expanded.coverageSinceEpoch < persisted.coverageSinceEpoch)
    }

    @Test
    func `old priority state payload without a cursor still cold scans`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: Self.priorityRequestBody(threadID: "thread-cold", turnID: "turn-cold"))

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data(
            #"{"turnKeys":{"turn-a":"priority"},"turnIDsByDay":{"2026-05-10":["turn-a"]}}"#.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["turn-a": "priority"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(memo.turns.keys.sorted() == ["turn-cold"])
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let expectedKeys = try #require(Self.expectedPriorityTurnKeys(memo.turns))
        #expect(cache.codexPriorityTurnsCursor != nil)
        #expect(cache.codexPriorityTurnsCursor?.turns.keys.sorted() == ["turn-cold"])
        #expect(cache.codexPriorityTurnKeys == expectedKeys)
        let dayKey = try #require(expectedKeys.keys.first)
        #expect(cache.codexPriorityTurnKeys?[dayKey] != nil)
        #expect(cache.codexPriorityTurnIDsByDay?[dayKey] == ["turn-cold"])
    }

    @Test
    func `live priority memo wins over a stale persisted cursor seed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path) }

        var live = Self.emptyMemoState(observationID: 7)
        live.lastRowID = 99
        live.fileIdentity = 42
        live.turns = [
            "live": CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: "thread-live",
                turnID: "live",
                model: "gpt-5.5",
                timestamp: nil),
        ]
        CostUsageScanner.storeCodexPriorityTurnsMemoIfNewer(live, forPath: databaseURL.path)

        var stale = Self.emptyPersistedCursor(databasePath: databaseURL.path)
        stale.lastRowID = 1
        stale.fileIdentity = 1
        stale.turns = [
            "stale": CostUsageScanner.CodexPriorityTurnMetadata(
                threadID: "thread-stale",
                turnID: "stale",
                model: "gpt-5.5",
                timestamp: nil),
        ]
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: databaseURL)

        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: databaseURL.path))
        #expect(memo.observationID == 7)
        #expect(memo.lastRowID == 99)
        #expect(memo.fileIdentity == 42)
        #expect(memo.turns.keys.sorted() == ["live"])
    }

    @Test
    func `stale seeded cursor reaccumulation is idempotent`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        let matchingRows: [(epochSeconds: Int64, body: String)] = [
            (epoch, Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a")),
            (epoch, Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b")),
            (epoch, Self.priorityRequestBody(threadID: "thread-c", turnID: "turn-c")),
            (epoch, Self.priorityRequestBody(threadID: "thread-d", turnID: "turn-d")),
            (epoch, Self.completedBody(turnID: "turn-a", model: "completed-a")),
            (epoch, Self.completedBody(turnID: "orphan-1", model: "pending-1")),
            (epoch, Self.completedBody(turnID: "orphan-2", model: "pending-2")),
        ]
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: matchingRows)

        let freshTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let freshMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(freshMemo.lastRowID == Int64(matchingRows.count))

        var stale = Self.persistedCursor(from: freshMemo, databasePath: dbURL.path)
        stale.lastRowID = 2
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(stale, databaseURL: dbURL)

        let overlappingTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let overlappingMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let againTurns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let againMemo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        #expect(overlappingTurns == freshTurns)
        #expect(overlappingTurns == againTurns)
        #expect(overlappingMemo.turns == againMemo.turns)
        #expect(overlappingMemo.requestSourcesByTurnID == againMemo.requestSourcesByTurnID)
        #expect(overlappingMemo.priorityCompletedModelsByTurnID == againMemo.priorityCompletedModelsByTurnID)
        #expect(overlappingMemo.completedModelsByTurnID == againMemo.completedModelsByTurnID)
        #expect(overlappingMemo.completedTurnIDInsertionOrder == againMemo.completedTurnIDInsertionOrder)
        #expect(overlappingMemo.completedTurnIDInsertionOrderStartIndex
            == againMemo.completedTurnIDInsertionOrderStartIndex)
        let retained = Array(
            overlappingMemo.completedTurnIDInsertionOrder
                .dropFirst(overlappingMemo.completedTurnIDInsertionOrderStartIndex))
        #expect(Set(retained).count == retained.count)
        #expect(overlappingMemo.lastRowID == freshMemo.lastRowID)
    }

    @Test
    func `identical content skip still persists an advanced priority cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))])
        try Self.writeCodexSession(env: env, now: now)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now.addingTimeInterval(1))
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending != true)
        let firstCursor = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(firstCursor.lastRowID == 1)

        var persistedFileCount = 0
        CostUsageStore.saveCycleCheckpointForTesting = { _ in persistedFileCount += 1 }
        defer { CostUsageStore.saveCycleCheckpointForTesting = nil }

        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: (0..<3).map { index in
            (epochSeconds: epoch, body: "routine trace row \(index)")
        })
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now.addingTimeInterval(2))

        #expect(persistedFileCount == 0)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.lastRowID == firstCursor.lastRowID + 3)
        #expect(reloaded.turns.keys.sorted() == ["turn-a"])
    }

    @Test(arguments: [false, true])
    func `malformed resolved pricing preserves valid priority state`(supersededCursor: Bool) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try Self.writeCodexSession(env: env, now: now)
        let expectedReport = Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let original = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var expectedCursor = try #require(original.codexPriorityTurnsCursor)
        #expect(original.codexPriorityTurnKeys?.isEmpty == false)
        #expect(original.codexResolvedPriorityTurns?.isEmpty == false)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = await store.fetchMetadata()
        let encoded = try #require(metadata.priorityTurnStatePayload)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        if supersededCursor {
            expectedCursor.turns["turn-a"]?.model = "gpt-5.4"
            expectedCursor.requestSourcesByTurnID["turn-a"]?[1]?.model = "gpt-5.4"
            payload["turnsCursor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expectedCursor))
        }
        payload["resolvedTurns"] = ["turn-a": ["turnID": 123]]
        metadata.priorityTurnStatePayload = try JSONSerialization.data(withJSONObject: payload)
        #expect(await store.setMetadata(metadata))

        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == original.codexPriorityTurnKeys)
        #expect(loaded.codexPriorityTurnIDsByDay == original.codexPriorityTurnIDsByDay)
        #expect(loaded.codexPriorityTurnsCursor == expectedCursor)
        #expect(loaded.codexResolvedPriorityTurns == nil)
        #expect(loaded.files == original.files)
        #expect(loaded.days == original.days)

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        let backupURL = env.root.appendingPathComponent("logs_2.backup.sqlite")
        try FileManager.default.moveItem(at: dbURL, to: backupURL)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: false)
        let pending = Self.loadCodexDailyReport(
            env: env, databaseURL: dbURL, now: now.addingTimeInterval(2))
        #expect(pending.data == expectedReport.data)
        #expect(pending.summary == expectedReport.summary)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot) == loaded)
    }

    @Test
    func `malformed priority turns cursor still loads turn keys`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data("""
        {
          "turnKeys": {"2026-05-10": "marker"},
          "turnIDsByDay": {"2026-05-10": ["turn-a"]},
          "turnsCursor": {"databasePath": 123}
        }
        """.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["2026-05-10": "marker"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)
    }

    @Test
    func `persisted payload without content anchor fields still cold scans`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: ISO8601DateFormatter().string(from: now),
            body: Self.priorityRequestBody(threadID: "thread-cold", turnID: "turn-cold"))

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = CostUsageStoreMetadata.empty
        metadata.priorityTurnStatePayload = Data("""
        {
          "turnKeys": {"2026-05-10": "marker"},
          "turnIDsByDay": {"2026-05-10": ["turn-a"]},
          "turnsCursor": {
            "databasePath": "/tmp/logs_2.sqlite",
            "coverageSinceEpoch": 0,
            "lastRowID": 51,
            "fileIdentity": 1,
            "turns": {"turn-a": {"threadID": "thread-a", "turnID": "turn-a"}},
            "requestSourcesByTurnID": {},
            "priorityCompletedModelsByTurnID": {},
            "completedModelsByTurnID": {},
            "completedTurnIDInsertionOrder": [],
            "completedTurnIDInsertionOrderStartIndex": 0
          }
        }
        """.utf8)
        #expect(await store.setMetadata(metadata))
        let loaded = store.syncLoadCodexCache(calendar: .current)
        #expect(loaded.codexPriorityTurnKeys == ["2026-05-10": "marker"])
        #expect(loaded.codexPriorityTurnIDsByDay == ["2026-05-10": ["turn-a"]])
        #expect(loaded.codexPriorityTurnsCursor == nil)

        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(memo.turns.keys.sorted() == ["turn-cold"])
        #expect(memo.anchorRowID == memo.lastRowID)
        #expect(!memo.anchorDigest.isEmpty)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let expectedKeys = try #require(Self.expectedPriorityTurnKeys(memo.turns))
        let persisted = try #require(cache.codexPriorityTurnsCursor)
        #expect(persisted.turns.keys.sorted() == ["turn-cold"])
        #expect(persisted.anchorRowID == memo.anchorRowID)
        #expect(persisted.anchorDigest == memo.anchorDigest)
        #expect(cache.codexPriorityTurnKeys == expectedKeys)
        let dayKey = try #require(expectedKeys.keys.first)
        #expect(cache.codexPriorityTurnIDsByDay?[dayKey] == ["turn-cold"])
    }

    @Test
    func `force rescan drops a persisted priority cursor and cold scans`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }

        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-a", turnID: "turn-a"))
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: timestamp,
            body: Self.priorityRequestBody(threadID: "thread-b", turnID: "turn-b"))
        Self.loadCodexDailyReport(env: env, databaseURL: dbURL, now: now)
        let persisted = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(persisted.lastRowID == 2)
        #expect(persisted.turns.keys.sorted() == ["turn-a", "turn-b"])

        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
        try Self.updateTestLog(
            dbURL: dbURL,
            rowID: 1,
            body: Self.priorityRequestBody(threadID: "thread-mutated", turnID: "turn-mutated"))
        Self.loadCodexDailyReport(
            env: env,
            databaseURL: dbURL,
            now: now.addingTimeInterval(1),
            forceRescan: true)

        let rebuilt = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(rebuilt.turns.keys.sorted() == ["turn-b", "turn-mutated"])
        #expect(rebuilt.lastRowID == 2)
        let reloaded = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexPriorityTurnsCursor)
        #expect(reloaded.turns.keys.sorted() == ["turn-b", "turn-mutated"])
        #expect(reloaded.lastRowID == 2)
    }

    @discardableResult
    private static func loadCodexDailyReport(
        env: CostUsageTestEnvironment,
        databaseURL: URL,
        since: Date? = nil,
        until: Date? = nil,
        now: Date,
        forceRescan: Bool = false,
        refreshMinIntervalSeconds: TimeInterval = 0) -> CostUsageDailyReport
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: databaseURL)
        options.refreshMinIntervalSeconds = refreshMinIntervalSeconds
        options.forceRescan = forceRescan
        return CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since ?? now,
            until: until ?? now,
            now: now,
            options: options)
    }

    private static func priorityRequestBody(
        threadID: String,
        turnID: String,
        model: String = "gpt-5.5") -> String
    {
        "thread_id=\(threadID) turn.id=\(turnID) websocket request: "
            + #"{"type":"response.create","model":"\#(model)","service_tier":"priority"}"#
    }

    private static func completedBody(turnID: String, model: String) -> String {
        "thread_id=thread turn.id=\(turnID) websocket event: "
            + #"{"type":"response.completed","response":{"model":"\#(model)"}}"#
    }

    private static func writeCodexSession(
        env: CostUsageTestEnvironment,
        now: Date,
        turnID: String = "turn-a") throws
    {
        let iso = env.isoString(for: now)
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"cursor-skip-\#(turnID)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.5"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"task_started","turn_id":"\#(turnID)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                + #""model":"gpt-5.5"}}}"#,
        ]
        _ = try env.writeCodexSessionFile(
            day: now,
            filename: "cursor-skip-\(turnID).jsonl",
            contents: lines.joined(separator: "\n") + "\n")
    }

    private static func cacheRequiringPricingMetadataMigration(_ cache: CostUsageCache) -> CostUsageCache {
        var migrationCache = cache
        migrationCache.codexResolvedPriorityTurns = nil
        for path in migrationCache.files.keys {
            guard var usage = migrationCache.files[path] else { continue }
            usage.codexCostCacheComplete = false
            usage.codexStandardTokens = nil
            usage.codexPriorityTokens = nil
            usage.codexRows = usage.codexRows?.map { row in
                CostUsageScanner.CodexUsageRow(
                    day: row.day,
                    model: row.model,
                    rawModel: row.rawModel,
                    turnID: row.turnID,
                    eventIndex: row.eventIndex,
                    timestampUnixMs: row.timestampUnixMs,
                    input: row.input,
                    cached: row.cached,
                    output: row.output,
                    reasoning: row.reasoning,
                    knownCostNanos: row.knownCostNanos,
                    unpricedTokens: row.unpricedTokens,
                    pricingModel: row.pricingModel,
                    pricingMode: nil)
            }
            migrationCache.files[path] = usage.refreshingCodexWorkspaceUsageFingerprint()
        }
        return migrationCache
    }

    private static func expectedPriorityTurnKeys(
        _ turns: [String: CostUsageScanner.CodexPriorityTurnMetadata],
        calendar: Calendar = .current) -> [String: String]?
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in turns {
            guard let timestamp = turn.timestamp, let seconds = Int64(timestamp) else { continue }
            let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(seconds)),
                calendar: calendar)
            partsByDay[dayKey, default: []].append(
                [turnID, turn.model ?? "", turn.timestamp ?? "", turn.threadID ?? ""]
                    .joined(separator: "|"))
        }
        guard !partsByDay.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            let digest = SHA256.hash(data: Data(parts.sorted().joined(separator: "\n").utf8))
            out[dayKey] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private static func persistedCursor(
        from memo: CostUsageScanner.CodexPriorityTurnsMemoState,
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: memo.coverageSinceEpoch,
            lastRowID: memo.lastRowID,
            fileIdentity: memo.fileIdentity,
            anchorRowID: memo.anchorRowID,
            anchorDigest: memo.anchorDigest,
            anchors: memo.anchors,
            turns: memo.turns,
            requestSourcesByTurnID: memo.requestSourcesByTurnID,
            priorityCompletedModelsByTurnID: memo.priorityCompletedModelsByTurnID,
            completedModelsByTurnID: memo.completedModelsByTurnID,
            completedTurnIDInsertionOrder: memo.completedTurnIDInsertionOrder,
            completedTurnIDInsertionOrderStartIndex: memo.completedTurnIDInsertionOrderStartIndex)
    }

    private static func emptyMemoState(observationID: UInt64) -> CostUsageScanner.CodexPriorityTurnsMemoState {
        CostUsageScanner.CodexPriorityTurnsMemoState(
            observationID: observationID,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    private static func emptyPersistedCursor(
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    private static func updateTestLog(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func deleteTestLog(dbURL: URL, rowID: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from logs where id = ?", -1, &statement, nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func deleteTestLogs(dbURL: URL, rowIDs: [Int64]) throws {
        for rowID in rowIDs {
            try self.deleteTestLog(dbURL: dbURL, rowID: rowID)
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
    }

    private struct LegacyCursorProjection: Decodable {
        var anchorRowID: Int64
        var anchorDigest: String
    }
}
#endif

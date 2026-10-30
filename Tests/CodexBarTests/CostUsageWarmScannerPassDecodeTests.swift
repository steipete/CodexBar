import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@Suite(.serialized)
struct CostUsageWarmScannerPassDecodeTests {
    enum MetadataChange: CaseIterable, Sendable {
        case unchanged, freshness, cursor, both
    }

    /// Real scanner passes over an unchanged corpus. After the first pass builds the cache, later passes have
    /// nothing to parse, so they should reuse the retained decoded baseline instead of decoding every row.
    @Test(arguments: [0, 300])
    func `warm scanner passes over an unchanged corpus reuse the decoded baseline`(
        refreshMinIntervalSeconds: Int) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let iso = env.isoString(for: day)
        for index in 0..<16 {
            var lines = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"id":"warm-\#(index)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.4"}}"#,
            ]
            for turn in 1...8 {
                lines.append(#"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","#
                    + #""info":{"total_token_usage":{"input_tokens":\#(turn * 10),"cached_input_tokens":\#(turn),"#
                    + #""output_tokens":\#(turn * 3)}}}}"#)
            }
            _ = try env.writeCodexSessionFile(
                day: day, filename: "warm-\(index).jsonl", contents: lines.joined(separator: "\n") + "\n")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = TimeInterval(refreshMinIntervalSeconds)
        let store = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let databaseURL = store.databaseURL
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)

        var warmDecodes: [Int] = []
        for pass in 1...3 {
            let recorder = CostUsageStoreReadWorkRecorder(databaseURL: databaseURL)
            var hooks = CostUsageStoreTestHooks.current
            hooks.readWorkRecorder = recorder
            hooks.scanStoreOverride = store
            // Space passes like background refreshes so interval-gated work is due each time.
            let now = day.addingTimeInterval(Double(pass * max(refreshMinIntervalSeconds, 1) + pass))
            CostUsageStoreTestHooks.$current.withValue(hooks) {
                env.evictSharedScanStores(except: store, calendar: options.calendar)
                _ = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: day,
                    until: day,
                    now: now,
                    options: options)
            }
            warmDecodes.append(recorder.snapshot().usageRowDecodeAttempts)
        }
        print("[warm-scanner-pass] refreshMin=\(refreshMinIntervalSeconds)s warm_pass_decodes=\(warmDecodes)")
        #expect(warmDecodes.dropFirst().allSatisfy { $0 == 0 })
    }
}

extension CostUsageWarmScannerPassDecodeTests {
    @Test(arguments: MetadataChange.allCases, ["none", "rows", "metadata"])
    func `metadata saves retain only a baseline certified before commit`(
        change: MetadataChange, externalWrite: String) throws
    {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let incoming = Self.incoming(loaded.cache, change: change, fixture: fixture)
        var hooks = CostUsageStoreTestHooks.current
        hooks.identicalContentPostCommitCheckpoint = (fixture.store.databaseURL, {
            do {
                if externalWrite == "rows" {
                    try writer.execute("DELETE FROM usage_rows WHERE rowid = (SELECT MIN(rowid) FROM usage_rows)")
                } else if externalWrite == "metadata" {
                    try writer.execute("""
                    UPDATE scan_metadata SET payload = json_set(CAST(payload AS TEXT), '$.lastScanUnixMs', 12345)
                    """)
                }
            } catch { Issue.record(error) }
        })
        #expect(!CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.save(incoming, load: loaded)
        }.catchUpRequired)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var reads = CostUsageStoreTestHooks.current
        reads.readWorkRecorder = recorder
        let fresh = CostUsageStoreTestHooks.$current.withValue(reads) {
            fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        }
        defer { fresh.release() }
        let work = recorder.snapshot()
        #expect(work
            .usageRowDecodeAttempts ==
            (externalWrite == "none" ? 0 : fixture.rowCount - (externalWrite == "rows" ? 1 : 0)))
        #expect(fresh.cache.lastScanUnixMs == (externalWrite == "metadata" ? 12345 : incoming.lastScanUnixMs))
        #expect(fresh.cache.codexPriorityTurnsCursor == incoming.codexPriorityTurnsCursor)
        #expect(fresh.cache.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) }
            == fixture.rowCount - (externalWrite == "rows" ? 1 : 0))
    }
}

extension CostUsageWarmScannerPassDecodeTests {
    @Test
    func `freshness and cursor changes share one metadata row write`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let incoming = Self.incoming(loaded.cache, change: .both, fixture: fixture)
        let before = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(!fixture.save(incoming, load: loaded).catchUpRequired)
        let after = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(after.rows - before.rows == 1)
    }

    @Test(arguments: [-1000, 0, 1000])
    func `retained freshness never moves backwards`(delta: Int64) throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var incoming = loaded.cache
        incoming.lastScanUnixMs += delta
        #expect(!fixture.save(incoming, load: loaded).catchUpRequired)
        let fresh = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { fresh.release() }
        #expect(fresh.cache.lastScanUnixMs == max(loaded.cache.lastScanUnixMs, incoming.lastScanUnixMs))
    }

    @Test(arguments: ["write", "commit", "content"])
    func `failed or unexpected metadata writes cannot retain provisional content`(failure: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        if failure == "write" {
            try writer.execute("""
            CREATE TRIGGER reject_metadata BEFORE UPDATE ON scan_metadata
            BEGIN SELECT RAISE(ABORT, 'synthetic metadata failure'); END
            """)
        } else if failure == "content" {
            try writer.execute("""
            CREATE TRIGGER change_content AFTER UPDATE ON scan_metadata
            BEGIN DELETE FROM usage_rows WHERE rowid = (SELECT MIN(rowid) FROM usage_rows); END
            """)
        }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        if failure == "commit" {
            #expect(await fixture.store.rejectSaveCommitForTesting())
        }
        let incoming = Self.incoming(loaded.cache, change: .freshness, fixture: fixture)
        #expect(fixture.save(incoming, load: loaded).catchUpRequired)
        if failure == "commit" {
            #expect(await fixture.store.rejectSaveCommitForTesting(false))
        }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var hooks = CostUsageStoreTestHooks.current
        hooks.readWorkRecorder = recorder
        let fresh = CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        }
        defer { fresh.release() }
        #expect(recorder.snapshot().usageRowDecodeAttempts == fixture.rowCount)
        #expect(fresh.cache.lastScanUnixMs == loaded.cache.lastScanUnixMs)
        #expect(await fixture.store.readSnapshot().usageRows.count == fixture.rowCount)
        #expect(await fixture.store.rebuildCount == 0)
    }

    @Test
    func `replacement after metadata commit reopens the replacement database`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let replacement = CostUsageStore(
            cacheRoot: fixture.env.root.appendingPathComponent("replacement"),
            home: fixture.store.home)
        var replacementCache = fixture.canonical
        replacementCache.codexProjectMetadataVersion = 777
        #expect(!replacement.syncSaveCodexCache(
            replacementCache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day)).catchUpRequired)
        #expect(await replacement.truncateWALForTesting())
        await replacement.closeConnectionForTesting()
        #expect(await fixture.store.truncateWALForTesting())
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let incoming = Self.incoming(loaded.cache, change: .both, fixture: fixture)
        let originalDirectory = fixture.store.databaseURL.deletingLastPathComponent()
        let replacementDirectory = replacement.databaseURL.deletingLastPathComponent()
        let retired = fixture.env.root.appendingPathComponent("retired-after-commit")
        var hooks = CostUsageStoreTestHooks.current
        hooks.identicalContentPostCommitCheckpoint = (fixture.store.databaseURL, {
            do {
                try FileManager.default.moveItem(at: originalDirectory, to: retired)
                try FileManager.default.moveItem(at: replacementDirectory, to: originalDirectory)
            } catch { Issue.record(error) }
        })
        #expect(!CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.save(incoming, load: loaded)
        }.catchUpRequired)
        let fresh = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { fresh.release() }
        #expect(fresh.cache.codexProjectMetadataVersion == 777)
        #expect(fresh.cache.lastScanUnixMs == replacementCache.lastScanUnixMs)
        #expect(await fixture.store.rebuildCount == 0)
    }

    @Test(arguments: [false, true])
    func `pending scans retain cursor changes without advancing freshness`(advanceCursor: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.codexScanCatchUpPending == true)
        let incoming = Self.incoming(loaded.cache, change: advanceCursor ? .both : .freshness, fixture: fixture)
        #expect(!fixture.save(incoming, load: loaded).catchUpRequired)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var hooks = CostUsageStoreTestHooks.current
        hooks.readWorkRecorder = recorder
        let fresh = CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        }
        defer { fresh.release() }
        #expect(recorder.snapshot().usageRowDecodeAttempts == 0)
        #expect(fresh.cache.lastScanUnixMs == loaded.cache.lastScanUnixMs)
        #expect(fresh.cache.codexPriorityTurnsCursor == incoming.codexPriorityTurnsCursor)
        #expect(await fixture.store.fetchMetadata().catchUpPending)
    }

    @Test
    func `held writer lock rejects freshness without rebuilding and permits a retry`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let store = CostUsageStore(
            cacheRoot: fixture.env.cacheRoot,
            home: fixture.env.codexStoreHome,
            busyTimeoutMilliseconds: 25)
        func save(_ loaded: CostUsageStoreLoad) -> CostUsageStoreBudgetResult {
            let incoming = Self.incoming(loaded.cache, change: .freshness, fixture: fixture)
            return store.syncSaveCodexCache(
                incoming,
                calendar: fixture.calendar,
                requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
                unloadedTokenSnapshotPaths: loaded.unloadedTokenSnapshotPaths,
                skipIdenticalContent: true,
                receipt: loaded.receipt)
        }
        let loaded = store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let holder = try BaselineSQLiteConnection(url: store.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        #expect(save(loaded).catchUpRequired)
        try holder.execute("COMMIT")
        #expect(store.syncLoadCodexCache(calendar: fixture.calendar) == fixture.canonical)
        #expect(await store.rebuildCount == 0)
        let retry = store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { retry.release() }
        #expect(!save(retry).catchUpRequired)
        #expect(await store.fetchMetadata().lastScanUnixMs == retry.cache.lastScanUnixMs + 1000)
        #expect(await store.rebuildCount == 0)
    }

    private static func incoming(
        _ cache: CostUsageCache,
        change: MetadataChange,
        fixture: ReadWorkFixture) -> CostUsageCache
    {
        var incoming = cache
        if change == .freshness || change == .both {
            incoming.lastScanUnixMs += 1000
        }
        if change == .cursor || change == .both {
            incoming.codexPriorityTurnsCursor = .init(
                databasePath: fixture.env.root.appendingPathComponent("synthetic-trace.sqlite").path,
                coverageSinceEpoch: 0,
                lastRowID: 7,
                fileIdentity: 1,
                anchorRowID: 7,
                anchorDigest: "synthetic",
                turns: [:],
                requestSourcesByTurnID: [:],
                priorityCompletedModelsByTurnID: [:],
                completedModelsByTurnID: [:],
                completedTurnIDInsertionOrder: [],
                completedTurnIDInsertionOrderStartIndex: 0)
        }
        return incoming
    }
}

extension CostUsageStore {
    fileprivate func rejectSaveCommitForTesting(_ reject: Bool = true) -> Bool {
        self.withDatabase(default: false) { database in
            guard reject else { return sqlite3_set_authorizer(database, nil, nil) == SQLITE_OK }
            return sqlite3_set_authorizer(
                database,
                { _, action, operation, _, _, _ in
                    if action == SQLITE_TRANSACTION, let operation, String(cString: operation) == "COMMIT" {
                        return SQLITE_DENY
                    }
                    return SQLITE_OK
                },
                nil) == SQLITE_OK
        }
    }
}

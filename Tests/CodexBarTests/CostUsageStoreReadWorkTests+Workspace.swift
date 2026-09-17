import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [false, true])
    func `workspace cache read failure preserves saved history`(forceRefresh: Bool) throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let options = CodexLocalProjectUsageIndexer.Options(scannerOptions: fixture.options)
        let baseline = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.now,
            historyDays: 1,
            forceRefresh: true,
            options: options)
        #expect(baseline.total.totalTokens == fixture.rowCount * 13)
        let rawCache = CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        let sources = try sidecar.usageCache(roots: baseline.rootsFingerprint)

        CostUsageStore.codexCacheReadCheckpointForTesting = (fixture.store.databaseURL, {
            CostUsageStore.codexCacheReadCheckpointForTesting = nil
            throw CostUsageStore.StoreError.sqlite(SQLITE_BUSY)
        })
        defer { CostUsageStore.codexCacheReadCheckpointForTesting = nil }

        #expect(throws: CodexLocalProjectUsageIndexer.IndexError.cacheScopeMismatch) {
            try CodexLocalProjectUsageIndexer.loadSnapshot(
                now: fixture.now,
                historyDays: 1,
                forceRefresh: forceRefresh,
                options: options)
        }

        #expect(CostUsageStore.codexCacheReadCheckpointForTesting == nil)
        #expect(CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar) == rawCache)
        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(
            now: fixture.now,
            historyDays: 1,
            options: options) == baseline)
        #expect(try sidecar.usageCache(roots: baseline.rootsFingerprint) == sources)
    }

    #if canImport(SQLite3)
    @Test(arguments: [false, true])
    func `workspace refresh rejects a retained cache from another source`(forceRefresh: Bool) throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let options = CodexLocalProjectUsageIndexer.Options(scannerOptions: fixture.options)
        let baseline = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.now,
            historyDays: 1,
            forceRefresh: true,
            options: options)
        let rawCache = CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        let sources = try sidecar.usageCache(roots: baseline.rootsFingerprint)
        var otherOptions = fixture.options
        let otherSessionsRoot = fixture.env.root
            .appendingPathComponent("other-codex-home/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSessionsRoot, withIntermediateDirectories: true)
        otherOptions.codexSessionsRoot = otherSessionsRoot
        let unavailableTrace = fixture.env.root.appendingPathComponent("unavailable-trace.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: unavailableTrace, withIntermediateDirectories: true)
        otherOptions.codexTraceDatabaseURL = unavailableTrace
        let otherScope = CodexLocalProjectUsageIndexer.Options(scannerOptions: otherOptions)
        #expect(rawCache.roots != CostUsageScanner.codexRootsFingerprint(options: otherOptions))

        #expect(throws: CodexLocalProjectUsageIndexer.IndexError.cacheScopeMismatch) {
            try CodexLocalProjectUsageIndexer.loadSnapshot(
                now: fixture.now,
                historyDays: 1,
                forceRefresh: forceRefresh,
                options: otherScope)
        }

        #expect(CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar) == rawCache)
        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(
            now: fixture.now,
            historyDays: 1,
            options: otherScope) == nil)
        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(
            now: fixture.now,
            historyDays: 1,
            options: options) == baseline)
        #expect(try sidecar.usageCache(roots: baseline.rootsFingerprint) == sources)
    }
    #endif

    @Test(arguments: [false, true])
    func `workspace refresh accepts an empty scan from the selected source`(forceRefresh: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        let options = CodexLocalProjectUsageIndexer.Options(scannerOptions: scannerOptions)
        let snapshot = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: now,
            historyDays: 1,
            forceRefresh: forceRefresh,
            options: options)

        #expect(snapshot.total == .empty)
        #expect(snapshot.indexedFileCount == 0)
        #expect(snapshot.projects.isEmpty)
        #expect(snapshot.sessions.isEmpty)
        #expect(CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: env.cacheRoot,
            calendar: scannerOptions.calendar).roots == CostUsageScanner.codexRootsFingerprint(options: scannerOptions))
        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(
            now: now,
            historyDays: 1,
            options: options) == snapshot)
    }

    @Test
    func `lean cache concurrent commit preserves refreshed workspace totals`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let options = CodexLocalProjectUsageIndexer.Options(scannerOptions: fixture.options)
        let baseline = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.now,
            historyDays: 1,
            forceRefresh: true,
            options: options)
        #expect(baseline.total.totalTokens == fixture.rowCount * 13)
        #expect(baseline.indexedFileCount == fixture.fileCount)

        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        CostUsageStore.codexCacheReadCheckpointForTesting = (fixture.store.databaseURL, {
            CostUsageStore.codexCacheReadCheckpointForTesting = nil
            try writer.execute("UPDATE files SET updated_at_ms = updated_at_ms + 1")
        })
        defer {
            CostUsageStore.readWorkRecorderForTesting = nil
            CostUsageStore.codexCacheReadCheckpointForTesting = nil
        }

        let refreshed = try CodexLocalProjectUsageIndexer.loadSnapshot(
            now: fixture.now,
            historyDays: 1,
            forceRefresh: true,
            options: options)
        #expect(CostUsageStore.codexCacheReadCheckpointForTesting == nil)
        #expect(refreshed.total == baseline.total)
        #expect(refreshed.projects == baseline.projects)
        #expect(refreshed.sessions == baseline.sessions)
        #expect(refreshed.indexedFileCount == baseline.indexedFileCount)
        #expect(recorder.snapshot().tokenSnapshotRows == 0)

        let cached = try #require(CodexLocalProjectUsageIndexer.cachedSnapshot(
            now: fixture.now,
            historyDays: 1,
            options: options))
        #expect(cached.total == baseline.total)
        #expect(cached.projects == baseline.projects)
        #expect(cached.sessions == baseline.sessions)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        let sidecarCache = try sidecar.usageCache(roots: [:])
        #expect(sidecarCache.files.count == baseline.indexedFileCount)
    }
}

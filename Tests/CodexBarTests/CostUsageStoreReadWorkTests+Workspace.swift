import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
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

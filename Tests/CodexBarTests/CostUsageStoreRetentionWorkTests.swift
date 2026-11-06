import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageStoreRetentionWorkTests {
    @Test
    func `explicit retention bounds skip the fallback metadata query`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let since = fixture.range.scanSinceKey
        let until = fixture.range.scanUntilKey
        let (explicit, explicitWork) = try await fixture.store.measureSQLWork {
            $0.enforceBudgets(
                maxRows: .max,
                maxFileBytes: .max,
                requestedSinceDay: since,
                requestedUntilDay: until)
        }
        let (fallback, fallbackWork) = try await fixture.store.measureSQLWork {
            $0.enforceBudgets(maxRows: .max, maxFileBytes: .max)
        }
        #expect(explicit == fallback)
        #expect(explicitWork.statements < fallbackWork.statements)
    }

    @Test
    func `budget archive checks do not materialize full file records`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let since = fixture.range.scanSinceKey
        let until = fixture.range.scanUntilKey
        let (result, work) = try await fixture.store.measureSQLWork {
            $0.enforceBudgets(
                maxRows: 1,
                maxFileBytes: .max,
                requestedSinceDay: since,
                requestedUntilDay: until)
        }
        #expect(result.deletedRows == 0)
        #expect(result.rowCount == 2)
        // The widest retention projection is the five-column eviction candidate, not file payloads.
        #expect(work.maximumResultColumns <= 5)
    }

    @Test
    func `protected retention preserves an unchanged scanner baseline`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var hooks = CostUsageStoreTestHooks.current
        hooks.readWorkRecorder = recorder
        await CostUsageStoreTestHooks.$current.withValue(hooks) {
            for _ in 0..<2 {
                let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
                defer { loaded.release() }
                recorder.reset()
                let before = await fixture.store.persistenceWriteMetricsForTesting()
                let saved = fixture.store.syncSaveCodexCache(
                    loaded.cache,
                    calendar: fixture.calendar,
                    requestedScanWindow: (
                        sinceKey: fixture.range.scanSinceKey,
                        untilKey: fixture.range.scanUntilKey),
                    rowBudget: 1,
                    fileBudgetBytes: 1,
                    unloadedTokenSnapshotPaths: loaded.unloadedTokenSnapshotPaths,
                    skipIdenticalContent: true,
                    receipt: loaded.receipt)
                let after = await fixture.store.persistenceWriteMetricsForTesting()
                #expect(!saved.catchUpRequired)
                #expect(saved.deletedRows == 0)
                #expect(saved.rowCount == 2)
                #expect(after.rows == before.rows)
                #expect(after.pages == before.pages)
                #expect(recorder.snapshot().usageRowDecodeAttempts == 0)
                #expect(recorder.snapshot().scannerSnapshotReads == 0)
            }
        }
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == fixture.canonical)
    }
}

import Foundation

#if DEBUG
/// Immutable instrumentation for one test, including work handed to the scan queue.
struct CostUsageStoreTestHooks: Sendable {
    @TaskLocal static var current = CostUsageStoreTestHooks()

    /// Invoked after each persisted file, inside the save transaction, for crash-safety proof.
    var saveCycleCheckpoint: (@Sendable (Int) -> Void)?
    var identicalContentPreLockCheckpoint: (databaseURL: URL, checkpoint: @Sendable () -> Void)?
    var codexCatchUpReconciliationVisit: (@Sendable () -> Void)?
    var readWorkRecorder: CostUsageStoreReadWorkRecorder?
    var codexTokenSnapshotReadFailure: (@Sendable (URL, String) -> Bool)?
    var codexBaselineReadCheckpoint: (databaseURL: URL, checkpoint: @Sendable () throws -> Void)?
    var codexTokenHydrationCheckpoint: (databaseURL: URL, checkpoint: @Sendable () throws -> Void)?
    var codexCacheReadCheckpoint: (databaseURL: URL, checkpoint: @Sendable () throws -> Void)?
}
#endif

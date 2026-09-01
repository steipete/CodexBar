import Foundation

extension CostUsageStore {
    /// Only the actor can resolve this receipt. It carries no decoded state or SQLite handle.
    final class CodexBaselineReceipt: Sendable {
        fileprivate let id = UUID()
        private let store: CostUsageStore

        fileprivate init(store: CostUsageStore) {
            self.store = store
        }

        deinit {
            let store = self.store
            let id = self.id
            Task { await store.releaseCodexBaseline(id: id) }
        }
    }

    struct CodexPersistenceState {
        var metadata: CostUsageStoreMetadata
        var files: [CostUsageStoreFile]
        var snapshotCounts: [String: Int]
        var rowCounts: [String: Int]

        init(snapshot: CostUsageStoreSnapshot) {
            self.metadata = snapshot.metadata
            self.files = snapshot.files.map { file in
                var file = file
                // Resume bodies and details already belong to the typed cache. Comparisons
                // and the row planner only need the file's compact persistence metadata.
                file.scanState.resumePayload = nil
                file.scanState.detailsPayload = nil
                return file
            }
            self.snapshotCounts = snapshot.tokenSnapshots.reduce(into: [:]) { $0[$1.path, default: 0] += 1 }
            self.rowCounts = snapshot.usageRows.reduce(into: [:]) { $0[$1.path, default: 0] += 1 }
        }
    }

    struct CodexDecodedBaseline {
        var decoded: CostUsageCache
        var persistence: CodexPersistenceState
        var stamp: DatabaseStamp
    }

    struct RetainedCodexBaseline {
        var id: UUID
        var baseline: CodexDecodedBaseline
    }

    func loadCodexScan(calendar: Calendar) -> CostUsageStoreLoad {
        self.retainedCodexBaseline = nil
        _ = self.removeLegacyCodexArtifactIfPresent()
        let receipt = CodexBaselineReceipt(store: self)
        guard let baseline = self.readCodexBaseline() else {
            // Keep a receipt even on failure so save cannot fall back to accepting unbased content.
            return CostUsageStoreLoad(store: self, cache: CostUsageCache(), receipt: receipt)
        }
        self.retainedCodexBaseline = RetainedCodexBaseline(id: receipt.id, baseline: baseline)
        let compatible = baseline.decoded.timeZoneIdentifier == nil
            || baseline.decoded.timeZoneIdentifier == calendar.timeZone.identifier
        let cache = compatible ? Self.reconciledCodexCache(
            baseline.decoded, persistence: baseline.persistence) : CostUsageCache()
        return CostUsageStoreLoad(store: self, cache: cache, receipt: receipt)
    }

    func releaseCodexBaseline(_ receipt: CodexBaselineReceipt) {
        self.releaseCodexBaseline(id: receipt.id)
    }

    private func releaseCodexBaseline(id: UUID) {
        if self.retainedCodexBaseline?.id == id {
            self.retainedCodexBaseline = nil
            #if DEBUG
            let observer = self.codexBaselineReleaseObserverForTesting
            self.codexBaselineReleaseObserverForTesting = nil
            observer?()
            #endif
        }
    }

    func takeCodexBaseline(_ receipt: CodexBaselineReceipt?) -> CodexDecodedBaseline? {
        guard let receipt else {
            self.retainedCodexBaseline = nil
            return self.readCodexBaseline()
        }
        guard self.retainedCodexBaseline?.id == receipt.id else { return nil }
        defer { self.retainedCodexBaseline = nil }
        return self.retainedCodexBaseline?.baseline
    }

    func readCodexBaseline() -> CodexDecodedBaseline? {
        let baseline: CodexDecodedBaseline? = self.withDatabase(default: nil) { database in
            guard let before = try? self.databaseStamp(database) else { return nil }
            let snapshot = try? Self.inReadTransaction(database) {
                let snapshot = try Self.readSnapshot(database, recorder: self.scopedReadWorkRecorderForTesting)
                #if DEBUG
                if let checkpoint = Self.codexBaselineReadCheckpointForTesting,
                   checkpoint.databaseURL == self.databaseURL
                {
                    try checkpoint.checkpoint()
                }
                #endif
                return snapshot
            }
            // data_version inside the read transaction can still describe its pinned snapshot.
            // Compare after COMMIT; never attach a newer version to the old decoded rows.
            guard let snapshot, let after = try? self.databaseStamp(database), before == after else { return nil }
            return CodexDecodedBaseline(
                decoded: Self.decodeCodexCache(from: snapshot, recorder: self.scopedReadWorkRecorderForTesting),
                persistence: CodexPersistenceState(snapshot: snapshot),
                stamp: after)
        }
        if baseline == nil {
            // Uncertain reads may be racing schema changes. Preserve the database and drain any
            // failed read transaction; a fresh open still owns normal integrity/recovery checks.
            self.recoverConnectionAfterFailure()
        }
        return baseline
    }

    func codexBaselineIsCurrent(_ baseline: CodexDecodedBaseline) -> Bool {
        self.currentDatabaseStamp() == baseline.stamp
    }

    /// Retention may rewrite identical metadata when a protected window exceeds the budget.
    /// Only those own writes permit a fresh locked semantic comparison; external changes retry.
    func codexBaselineAfterRetention(_ baseline: CodexDecodedBaseline) -> CodexDecodedBaseline? {
        self.withDatabase(default: nil) { database in
            guard let current = self.currentDatabaseStamp() else { return nil }
            if current == baseline.stamp {
                return baseline
            }
            var original = baseline.stamp
            original.totalChanges = current.totalChanges
            guard original == current else { return nil }
            let snapshot = try Self.readSnapshot(database, recorder: self.scopedReadWorkRecorderForTesting)
            return CodexDecodedBaseline(
                decoded: Self.decodeCodexCache(from: snapshot, recorder: self.scopedReadWorkRecorderForTesting),
                persistence: CodexPersistenceState(snapshot: snapshot),
                stamp: current)
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var codexBaselineReadCheckpointForTesting: (
        databaseURL: URL,
        checkpoint: () throws -> Void)?

    var retainedCodexBaselineCountForTesting: Int {
        self.retainedCodexBaseline == nil ? 0 : 1
    }
    #endif
}

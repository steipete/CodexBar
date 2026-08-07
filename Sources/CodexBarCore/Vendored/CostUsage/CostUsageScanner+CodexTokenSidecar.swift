import Foundation

extension CostUsageScanner {
    static let codexPreEOFBaselineProducerKeys: Set<String> = [
        "codex:cu:p1cd29792d9ca2b11",
        "codex:cu:p37aedd661c4272a8",
        "codex:cu:p843ca061c36bbea1",
        "codex:cu:p6c0f1fa950e63467",
        "codex:cu:p89e80f722cad05c8",
        "codex:cu:paa27d287348e79b5",
    ]

    struct CodexTokenIndexPersistence {
        let snapshots: [CostUsageCodexTokenSnapshot]?
        let checkpoints: [CostUsageCodexTokenCheckpoint]?
        let timestampsMonotonic: Bool?
        let anchor: CostUsageCodexTokenIndexAnchor?
        let sidecarState: CostUsageCodexTokenSidecarState?
        /// The completeness actually committed to SQLite (or retained inline). Complete writes
        /// that race with source growth fail instead of publishing an unsafe EOF classification.
        let isComplete: Bool
    }

    enum CodexTokenIndexAppendOutcome {
        case persisted(CodexTokenIndexPersistence)
        /// The published sidecar is still valid; retry the identical suffix later.
        case retryLater
        /// The published sidecar cannot be trusted; schedule one clean byte-zero rebuild.
        case rebuildNextPass
    }

    /// Folds only the supplied suffix and stores the counted cumulative total after each event.
    /// The terminal state is persisted in the JSON cache, so a later append never replays the
    /// already-indexed prefix merely to reconstruct accumulator state.
    static func codexTokenIndexRecords(
        events: [CostUsageCodexTokenSnapshot],
        initialState: CostUsageCodexTokenAccumulatorState? = nil)
        -> (records: [CostUsageCodexTokenIndexRecord], terminalState: CostUsageCodexTokenAccumulatorState)?
    {
        var accumulator = CodexSnapshotAccumulator(state: initialState)
        var records: [CostUsageCodexTokenIndexRecord] = []
        records.reserveCapacity(events.count)
        for event in events {
            guard let endOffset = event.endOffset else { return nil }
            let totals = accumulator.apply(last: event.last, total: event.total)
            let timestampUnixSeconds = Self.dateFromTimestamp(event.timestamp)?.timeIntervalSince1970
            records.append(CostUsageCodexTokenIndexRecord(
                timestamp: event.timestamp,
                timestampUnixSeconds: timestampUnixSeconds,
                totals: totals,
                endOffset: endOffset))
        }
        return (records, accumulator.state)
    }

    static func codexTokenIndexReference(
        fileURL: URL,
        fileId: String?,
        anchor: CostUsageCodexTokenIndexAnchor?,
        state: CostUsageCodexTokenSidecarState?,
        isComplete: Bool) -> CostUsageCodexTokenIndexReference?
    {
        guard let fileId, let anchor, let state, state.eventCount >= 0 else { return nil }
        return CostUsageCodexTokenIndexReference(
            path: CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
            fileId: fileId,
            indexedBytes: anchor.indexedBytes,
            eventCount: state.eventCount,
            anchor: anchor,
            isComplete: isComplete)
    }

    // swiftlint:disable function_parameter_count
    /// Replaces a full token index. SQLite is committed before the returned state is installed in
    /// the JSON cache. If the process exits between those operations, a later replace is idempotent;
    /// if SQLite is unavailable, the existing inline representation remains the safe fallback.
    /// The source identity and publication cursor must be committed together.
    static func replacingCodexTokenIndex(
        events: [CostUsageCodexTokenSnapshot],
        nextUsageRowIndex: Int,
        fileURL: URL,
        fileId: String?,
        indexedBytes: Int64,
        isComplete: Bool,
        store: CostUsageCodexTokenIndexStore) -> CodexTokenIndexPersistence
    {
        let inline = Self.inlineCodexTokenIndex(
            events: events,
            fileURL: fileURL,
            indexedBytes: indexedBytes,
            isComplete: isComplete)
        guard store.isAvailable,
              let fileId,
              let anchor = inline.anchor,
              let folded = Self.codexTokenIndexRecords(events: events)
        else { return inline }

        let state = CostUsageCodexTokenSidecarState(
            eventCount: folded.records.count,
            accumulatorState: folded.terminalState,
            nextUsageRowIndex: nextUsageRowIndex)
        let reference = CostUsageCodexTokenIndexReference(
            path: CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
            fileId: fileId,
            indexedBytes: indexedBytes,
            eventCount: state.eventCount,
            anchor: anchor,
            isComplete: isComplete)
        do {
            let committed = try store.replace(reference: reference, records: folded.records)
            return CodexTokenIndexPersistence(
                snapshots: nil,
                checkpoints: nil,
                timestampsMonotonic: nil,
                anchor: anchor,
                sidecarState: state,
                isComplete: committed.isComplete)
        } catch {
            let firstError = error
            if store.resetDatabaseAfterStructuralFailure(firstError) {
                do {
                    let committed = try store.replace(reference: reference, records: folded.records)
                    Self.log.warning(
                        "Codex token sidecar was structurally invalid and has been rebuilt",
                        metadata: ["path": fileURL.path])
                    return CodexTokenIndexPersistence(
                        snapshots: nil,
                        checkpoints: nil,
                        timestampsMonotonic: nil,
                        anchor: anchor,
                        sidecarState: state,
                        isComplete: committed.isComplete)
                } catch {
                    Self.log.warning(
                        "Codex token sidecar rebuild retry failed; retaining inline index",
                        metadata: ["path": fileURL.path, "error": "\(error)"])
                    return inline
                }
            }
            Self.log.warning(
                "Codex token sidecar replace failed; retaining inline index",
                metadata: ["path": fileURL.path, "error": "\(firstError)"])
            return inline
        }
    }

    // swiftlint:enable function_parameter_count

    // swiftlint:disable function_parameter_count
    /// Extends either a current sidecar or a legacy inline index. A missing/corrupt sidecar returns
    /// Structural failures schedule a later byte-zero rebuild; transient failures preserve the
    /// published cursor. Neither path asks the caller to reread the same large file in this pass.
    /// The expected and updated sidecar generations form one atomic append contract.
    static func appendingCodexTokenIndex(
        cached: CostUsageFileUsage,
        deltaEvents: [CostUsageCodexTokenSnapshot],
        nextUsageRowIndex: Int,
        fileURL: URL,
        fileId: String?,
        indexedBytes: Int64,
        isComplete: Bool,
        store: CostUsageCodexTokenIndexStore) -> CodexTokenIndexAppendOutcome
    {
        guard let newAnchor = codexTokenIndexAnchor(
            fileURL: fileURL,
            indexedBytes: indexedBytes)
        else { return .retryLater }

        if let sidecarState = cached.codexTokenSidecarState {
            guard let expected = Self.codexTokenIndexReference(
                fileURL: fileURL,
                fileId: cached.codexScanFileId,
                anchor: cached.codexTokenIndexAnchor,
                state: sidecarState,
                isComplete: cached.codexScanComplete != false),
                expected.indexedBytes == (cached.parsedBytes ?? cached.size),
                expected.fileId == fileId,
                let folded = Self.codexTokenIndexRecords(
                    events: deltaEvents,
                    initialState: sidecarState.accumulatorState)
            else { return .rebuildNextPass }
            guard sidecarState.eventCount <= Int.max - folded.records.count else {
                return .rebuildNextPass
            }

            let updatedState = CostUsageCodexTokenSidecarState(
                eventCount: sidecarState.eventCount + folded.records.count,
                accumulatorState: folded.terminalState,
                nextUsageRowIndex: nextUsageRowIndex)
            let updated = CostUsageCodexTokenIndexReference(
                path: CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
                fileId: expected.fileId,
                indexedBytes: indexedBytes,
                eventCount: updatedState.eventCount,
                anchor: newAnchor,
                isComplete: isComplete)
            do {
                let committed = try store.append(
                    expected: expected,
                    updated: updated,
                    records: folded.records)
                return .persisted(CodexTokenIndexPersistence(
                    snapshots: nil,
                    checkpoints: nil,
                    timestampsMonotonic: nil,
                    anchor: newAnchor,
                    sidecarState: updatedState,
                    isComplete: committed.isComplete))
            } catch {
                let disposition = CostUsageCodexTokenIndexStore.failureDisposition(for: error)
                Self.log.warning(
                    "Codex token sidecar append failed; deferring cursor publication",
                    metadata: [
                        "path": fileURL.path,
                        "error": "\(error)",
                        "disposition": disposition == .needsRebuild ? "rebuild" : "retry",
                    ])
                return disposition == .needsRebuild ? .rebuildNextPass : .retryLater
            }
        }

        guard let prefixEvents = cached.codexTokenSnapshots else { return .rebuildNextPass }
        let mergedEvents = prefixEvents + deltaEvents
        return .persisted(Self.replacingCodexTokenIndex(
            events: mergedEvents,
            nextUsageRowIndex: nextUsageRowIndex,
            fileURL: fileURL,
            fileId: fileId,
            indexedBytes: indexedBytes,
            isComplete: isComplete,
            store: store))
    }

    // swiftlint:enable function_parameter_count

    static func codexUsageRequiringTokenIndexRebuild(
        _ usage: CostUsageFileUsage) -> CostUsageFileUsage
    {
        var rebuilding = usage
        rebuilding.parsedBytes = 0
        rebuilding.lastModel = nil
        rebuilding.lastTotals = nil
        rebuilding.lastCountedTotals = nil
        rebuilding.lastRawTotalsBaseline = nil
        rebuilding.lastRawTotalsWatermark = nil
        rebuilding.seenRawTotals = nil
        rebuilding.hasDivergentTotals = nil
        rebuilding.hasInterleavedTotals = nil
        rebuilding.lastCodexTurnID = nil
        rebuilding.codexTokenSnapshots = nil
        rebuilding.codexTokenCheckpoints = nil
        rebuilding.codexTokenTimestampsMonotonic = nil
        rebuilding.codexTokenIndexAnchor = nil
        rebuilding.codexTokenSidecarState = nil
        rebuilding.codexForkAccountingState = nil
        rebuilding.codexJSONLResumeState = nil
        rebuilding.codexBufferedSubagentLines = nil
        rebuilding.codexSubagentResumeState = nil
        rebuilding.codexDeferredReplayState = nil
        rebuilding.codexBufferedUnresolvedForkLines = nil
        rebuilding.codexScanComplete = false
        return rebuilding
    }

    static func migratingInlineCodexTokenIndexIfPossible(
        usage: CostUsageFileUsage,
        fileURL: URL,
        metadata: CodexFileMetadata,
        store: CostUsageCodexTokenIndexStore) -> CostUsageFileUsage
    {
        guard usage.codexTokenSidecarState == nil,
              let events = usage.codexTokenSnapshots,
              let anchor = usage.codexTokenIndexAnchor,
              anchor.indexedBytes == (usage.parsedBytes ?? usage.size),
              codexTokenIndexAnchorMatches(anchor, fileURL: fileURL, metadata: metadata)
        else { return usage }

        let persisted = Self.replacingCodexTokenIndex(
            events: events,
            // Token event count is a safe upper bound for legacy usage-row ordinals. Gaps are
            // harmless; reusing an event index after an out-of-window event is not.
            nextUsageRowIndex: max(Self.nextCodexUsageRowIndex(usage.codexRows), events.count),
            fileURL: fileURL,
            fileId: metadata.fileId,
            indexedBytes: anchor.indexedBytes,
            isComplete: usage.codexScanComplete != false && anchor.indexedBytes >= metadata.size,
            store: store)
        guard persisted.sidecarState != nil else { return usage }
        var migrated = usage
        migrated.codexTokenSnapshots = persisted.snapshots
        migrated.codexTokenCheckpoints = persisted.checkpoints
        migrated.codexTokenTimestampsMonotonic = persisted.timestampsMonotonic
        migrated.codexTokenIndexAnchor = persisted.anchor
        migrated.codexTokenSidecarState = persisted.sidecarState
        return migrated
    }

    private static func inlineCodexTokenIndex(
        events: [CostUsageCodexTokenSnapshot],
        fileURL: URL,
        indexedBytes: Int64,
        isComplete: Bool = false) -> CodexTokenIndexPersistence
    {
        CodexTokenIndexPersistence(
            snapshots: events,
            checkpoints: codexTokenCheckpoints(for: events),
            timestampsMonotonic: codexTokenTimestampsAreMonotonic(events),
            anchor: codexTokenIndexAnchor(fileURL: fileURL, indexedBytes: indexedBytes),
            sidecarState: nil,
            isComplete: isComplete)
    }

    /// Pre-sidecar producers could publish a fork child as soon as a partial parent happened to
    /// contain a timestamp at the cutoff. Only children whose cached parent is still incomplete
    /// need revalidation; complete parents and their multi-gigabyte cursors remain reusable.
    @discardableResult
    static func revalidatePreEOFCodexForkBaselines(cache: inout CostUsageCache) -> Bool {
        guard let producerKey = cache.producerKey,
              codexPreEOFBaselineProducerKeys.contains(producerKey)
        else { return false }
        let incompleteParentIDs = Set(cache.files.values.compactMap { usage -> String? in
            usage.codexScanComplete == false ? usage.sessionId : nil
        })
        guard !incompleteParentIDs.isEmpty else { return false }

        var changed = false
        for path in cache.files.keys.sorted() {
            guard var usage = cache.files[path],
                  let parentSessionId = usage.forkedFromId,
                  incompleteParentIDs.contains(parentSessionId),
                  usage.forkBaselineDependencyKey != nil,
                  usage.forkBaselineDependencyKey != Self.codexForkDependencyNotRequiredKey
            else { continue }

            Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: -1)
            usage.days = [:]
            usage.parsedBytes = 0
            usage.lastModel = nil
            usage.lastTotals = nil
            usage.lastCountedTotals = nil
            usage.lastRawTotalsBaseline = nil
            usage.lastRawTotalsWatermark = nil
            usage.seenRawTotals = nil
            usage.hasDivergentTotals = nil
            usage.hasInterleavedTotals = nil
            usage.lastCodexTurnID = nil
            usage.forkBaselineDependencyKey = nil
            usage.codexCostCacheComplete = true
            usage.codexCostNanos = nil
            usage.codexPrioritySurchargeNanos = nil
            usage.codexStandardCostNanos = nil
            usage.codexPriorityCostNanos = nil
            usage.codexStandardTokens = nil
            usage.codexPriorityTokens = nil
            usage.codexTurnIDs = nil
            usage.codexWorkspaceContentFingerprint = nil
            usage.codexRows = nil
            usage.codexTokenSnapshots = nil
            usage.codexTokenCheckpoints = nil
            usage.codexTokenTimestampsMonotonic = nil
            usage.codexTokenIndexAnchor = nil
            usage.codexTokenSidecarState = nil
            usage.codexUsageRowSidecarState = nil
            usage.codexUsageRowProducerKey = nil
            usage.codexForkAccountingState = nil
            usage.codexScanTargetSize = usage.size
            usage.codexScanComplete = false
            usage.codexJSONLResumeState = nil
            usage.codexBufferedSubagentLines = nil
            usage.codexSubagentResumeState = nil
            usage.codexDeferredReplayState = nil
            usage.codexBufferedUnresolvedForkLines = nil
            usage.codexDeferredForkScan = true
            cache.files[path] = usage
            changed = true
        }
        if changed {
            cache.codexScanCatchUpPending = true
            cache.lastScanUnixMs = 0
        }
        return changed
    }
}

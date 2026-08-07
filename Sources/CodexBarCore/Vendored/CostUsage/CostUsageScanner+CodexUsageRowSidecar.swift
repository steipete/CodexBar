import Foundation

extension CostUsageScanner {
    enum CodexUsageRowPersistenceOutcome {
        case persisted(CostUsageCodexUsageRowSidecarState)
        /// SQLite is unavailable for a complete replacement, but the supplied rows are a safe
        /// self-contained fallback. Append callers never receive this outcome for a suffix alone.
        case inline([CodexUsageRow])
        case retryLater
        case rebuildNextPass
    }

    /// Runs while the process owns the Codex refresh lock. Corruption is quarantined before any
    /// new generation is written, then every JSON reference into the old database is invalidated
    /// together. Missing databases are handled the same way; newer schemas remain untouched so an
    /// older binary cannot destroy data it does not understand.
    static func prepareCodexUsageRowStoreForOwnedRefresh(
        cache: inout CostUsageCache,
        store: CostUsageCodexUsageRowStore)
    {
        let hasPublishedReferences = cache.files.values.contains {
            $0.codexUsageRowSidecarState != nil
        }
        do {
            try store.validateDatabaseHealth(requireExistingDatabase: hasPublishedReferences)
            return
        } catch {
            guard CostUsageCodexUsageRowStore.failureDisposition(for: error) == .needsRebuild else {
                Self.log.warning(
                    "Codex usage-row sidecar health check deferred",
                    metadata: ["error": "\(error)"])
                return
            }
            let recovery = try? store.quarantineAndResetDatabaseAfterStructuralFailure(error)
            if case let .quarantined(url) = recovery {
                Self.log.warning(
                    "Quarantined a damaged Codex usage-row sidecar",
                    metadata: ["path": url.path, "error": "\(error)"])
            }
            for path in cache.files.keys {
                guard let usage = cache.files[path], usage.codexUsageRowSidecarState != nil else { continue }
                cache.files[path] = Self.codexUsageRequiringUsageRowIndexRebuild(usage)
            }
            cache.codexScanCatchUpPending = true
            cache.lastScanUnixMs = 0
        }
    }

    static func codexUsageRequiringUsageRowIndexRebuild(
        _ usage: CostUsageFileUsage) -> CostUsageFileUsage
    {
        var rebuilding = Self.codexUsageRequiringTokenIndexRebuild(usage)
        rebuilding.codexUsageRowSidecarState = nil
        rebuilding.codexUsageRowProducerKey = nil
        rebuilding.codexRows = nil
        rebuilding.codexTurnIDs = nil
        rebuilding.codexWorkspaceContentFingerprint = nil
        return rebuilding
    }

    /// Old cache schemas published one producer for the whole JSON artifact. Capture that value
    /// on each immutable row generation before the artifact rotates to the current producer; a
    /// migrated cache may then safely contain old stable generations and new current generations.
    static func captureCodexUsageRowProducerKeys(cache: inout CostUsageCache) {
        guard let publishedProducerKey = cache.producerKey, !publishedProducerKey.isEmpty else { return }
        for path in cache.files.keys {
            guard var usage = cache.files[path] else { continue }
            if usage.codexUsageRowSidecarState != nil {
                guard usage.codexUsageRowProducerKey == nil else { continue }
                usage.codexUsageRowProducerKey = publishedProducerKey
            } else {
                guard usage.codexUsageRowProducerKey != nil else { continue }
                usage.codexUsageRowProducerKey = nil
            }
            cache.files[path] = usage
        }
    }

    static func codexPublishedUsageRowReference(
        usage: CostUsageFileUsage,
        fileURL: URL,
        context: CodexFileScanContext) -> CostUsageCodexUsageRowReference?
    {
        guard let state = usage.codexUsageRowSidecarState,
              state.formatVersion == 1,
              let fileId = usage.codexScanFileId,
              let anchor = usage.codexTokenIndexAnchor
        else { return nil }
        return CostUsageCodexUsageRowReference(
            source: CostUsageCodexUsageRowSource(
                path: CostUsageCodexUsageRowStore.sourcePath(for: fileURL),
                fileId: fileId,
                indexedBytes: usage.parsedBytes ?? usage.size,
                anchor: anchor,
                isComplete: usage.codexScanComplete != false,
                changeUnixNs: usage.codexScanChangeUnixNs,
                sessionId: usage.sessionId,
                forkedFromId: usage.forkedFromId,
                forkDependencyKey: usage.forkBaselineDependencyKey,
                producerKey: usage.codexUsageRowProducerKey
                    ?? context.resources.publishedProducerKey,
                timeZoneIdentifier: context.resources.timeZoneIdentifier),
            state: state)
    }

    static func codexUsageRows(
        usage: CostUsageFileUsage,
        fileURL: URL,
        context: CodexFileScanContext) -> CostUsageCodexUsageRowsLookup<[CodexUsageRow]>
    {
        if let rows = usage.codexRows {
            context.scanBudget?.recordUsageRowWork(read: rows.count)
            return .ready(rows)
        }
        guard let reference = Self.codexPublishedUsageRowReference(
            usage: usage,
            fileURL: fileURL,
            context: context)
        else {
            return usage.days.isEmpty ? .ready([]) : .needsRebuild
        }
        switch context.resources.usageRowStore.load(reference) {
        case let .ready(records):
            context.scanBudget?.recordUsageRowWork(read: records.count)
            return .ready(records.map(\.usageRow))
        case .needsRebuild:
            return .needsRebuild
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        }
    }

    /// Materializes historical row keys only after a second physical source for the same session
    /// is encountered. The common one-source path therefore remains O(delta), while duplicate and
    /// fork reconciliation retains the existing exact row-identity semantics.
    static func prepareCodexSessionRowIdentity(
        sessionId: String?,
        excludingPath: String,
        cache: inout CostUsageCache,
        context: CodexFileScanContext,
        state: inout CodexScanState) -> Bool
    {
        guard let sessionId, !sessionId.isEmpty else { return true }
        let candidates = cache.files
            .filter { path, usage in
                path != excludingPath
                    && usage.sessionId == sessionId
                    && usage.codexScanFileId.map(state.seenFileIds.contains) == true
            }
            .sorted { $0.key < $1.key }
        for (path, usage) in candidates {
            switch Self.codexUsageRows(
                usage: usage,
                fileURL: URL(fileURLWithPath: path),
                context: context)
            {
            case let .ready(rows):
                Self.rememberCodexRows(
                    rows,
                    sessionId: sessionId,
                    fileIdentity: path,
                    state: &state)
            case .needsRebuild:
                cache.files[path] = Self.codexUsageRequiringUsageRowIndexRebuild(usage)
                context.scanBudget?.recordPersistenceDeferral()
                return false
            case .temporarilyUnavailable:
                context.scanBudget?.recordPersistenceDeferral()
                return false
            }
        }
        return true
    }

    static func pricedCodexUsageRows(
        _ rows: [CodexUsageRow],
        context: CodexFileScanContext) -> [CodexUsageRow]
    {
        guard !rows.isEmpty else { return [] }
        context.scanBudget?.recordUsageRowWork(repriced: rows.count)
        return codexRowsWithPricingAudit(
            rows,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
    }

    static func persistingCodexUsageRowProjection(
        _ usage: CostUsageFileUsage,
        rows: [CodexUsageRow],
        fileURL: URL,
        ownershipKey: String?,
        context: CodexFileScanContext) -> CostUsageFileUsage?
    {
        let nextUsageRowIndex = usage.codexTokenSidecarState?.nextUsageRowIndex
            ?? usage.codexUsageRowSidecarState?.nextUsageRowIndex
            ?? Self.nextCodexUsageRowIndex(rows)
        let outcome = Self.replacingCodexUsageRows(
            rows: rows,
            nextUsageRowIndex: nextUsageRowIndex,
            fileURL: fileURL,
            fileId: usage.codexScanFileId,
            indexedBytes: usage.parsedBytes ?? usage.size,
            anchor: usage.codexTokenIndexAnchor,
            isComplete: usage.codexScanComplete != false,
            changeUnixNs: usage.codexScanChangeUnixNs,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            forkDependencyKey: usage.forkBaselineDependencyKey,
            ownershipKey: ownershipKey,
            context: context)
        var updated = usage
        switch outcome {
        case let .persisted(state):
            updated.codexUsageRowSidecarState = state
            updated.codexUsageRowProducerKey = context.resources.currentProducerKey
            updated.codexRows = nil
            updated.codexTurnIDs = nil
        case let .inline(inlineRows):
            updated.codexUsageRowSidecarState = nil
            updated.codexUsageRowProducerKey = nil
            updated.codexRows = inlineRows
            updated.codexTurnIDs = Self.codexTurnIDs(rows: inlineRows)
        case .retryLater, .rebuildNextPass:
            return nil
        }
        return updated.refreshingCodexWorkspaceUsageFingerprint()
    }

    static func codexUsageRowRecords(
        rows: [CodexUsageRow],
        sessionId: String?,
        fileIdentity: String) -> [CostUsageCodexUsageRowRecord]?
    {
        var records: [CostUsageCodexUsageRowRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            let key = Self.codexUsageRowKey(
                sessionId: sessionId,
                fileIdentity: fileIdentity,
                row: row)
            guard let record = CostUsageCodexUsageRowRecord(
                row: row,
                dedupKey: Data(key.utf8))
            else { return nil }
            records.append(record)
        }
        return records.sorted { $0.eventIndex < $1.eventIndex }
    }

    // swiftlint:disable function_parameter_count
    static func replacingCodexUsageRows(
        rows: [CodexUsageRow],
        nextUsageRowIndex: Int,
        fileURL: URL,
        fileId: String?,
        indexedBytes: Int64,
        anchor: CostUsageCodexTokenIndexAnchor?,
        isComplete: Bool,
        changeUnixNs: Int64?,
        sessionId: String?,
        forkedFromId: String?,
        forkDependencyKey: String?,
        ownershipKey: String?,
        context: CodexFileScanContext) -> CodexUsageRowPersistenceOutcome
    {
        guard context.resources.usageRowStore.isAvailable,
              let fileId,
              let anchor,
              let records = codexUsageRowRecords(
                  rows: rows,
                  sessionId: sessionId,
                  fileIdentity: fileURL.path)
        else { return .inline(rows) }
        let source = CostUsageCodexUsageRowSource(
            path: CostUsageCodexUsageRowStore.sourcePath(for: fileURL),
            fileId: fileId,
            indexedBytes: indexedBytes,
            anchor: anchor,
            isComplete: isComplete,
            changeUnixNs: changeUnixNs,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkDependencyKey: forkDependencyKey,
            producerKey: context.resources.currentProducerKey,
            timeZoneIdentifier: context.resources.timeZoneIdentifier)
        do {
            let reference = try context.resources.usageRowStore.createGeneration(
                source: source,
                records: records,
                nextUsageRowIndex: nextUsageRowIndex,
                coverageSinceKey: context.range.scanSinceKey,
                coverageUntilKey: context.range.scanUntilKey,
                ownershipKey: ownershipKey,
                pricingKey: context.resources.pricingKey,
                priorityMetadataKey: context.resources.priorityMetadataKey)
            context.scanBudget?.recordUsageRowWork(
                written: records.count,
                fingerprintHashed: records.count)
            return .persisted(reference.state)
        } catch {
            context.resources.usageRowStore.recordDatabaseFailure(error)
            let disposition = CostUsageCodexUsageRowStore.failureDisposition(for: error)
            Self.log.warning(
                "Codex usage-row sidecar replacement failed; deferring cursor publication",
                metadata: [
                    "path": fileURL.path,
                    "error": "\(error)",
                    "disposition": disposition == .needsRebuild ? "rebuild" : "retry",
                ])
            return disposition == .needsRebuild ? .rebuildNextPass : .retryLater
        }
    }

    static func appendingCodexUsageRows(
        cached: CostUsageFileUsage,
        deltaRows: [CodexUsageRow],
        nextUsageRowIndex: Int,
        fileURL: URL,
        fileId: String?,
        indexedBytes: Int64,
        anchor: CostUsageCodexTokenIndexAnchor?,
        isComplete: Bool,
        changeUnixNs: Int64?,
        sessionId: String?,
        forkedFromId: String?,
        forkDependencyKey: String?,
        context: CodexFileScanContext) -> CodexUsageRowPersistenceOutcome
    {
        guard let expected = codexPublishedUsageRowReference(
            usage: cached,
            fileURL: fileURL,
            context: context),
            expected.state.coverageSinceKey == context.range.scanSinceKey,
            expected.state.coverageUntilKey == context.range.scanUntilKey,
            expected.state.pricingKey == context.resources.pricingKey,
            expected.state.priorityMetadataKey == context.resources.priorityMetadataKey,
            expected.source.producerKey == context.resources.currentProducerKey,
            let fileId,
            let anchor,
            let records = codexUsageRowRecords(
                rows: deltaRows,
                sessionId: sessionId,
                fileIdentity: fileURL.path)
        else { return .rebuildNextPass }
        let updatedSource = CostUsageCodexUsageRowSource(
            path: expected.source.path,
            fileId: fileId,
            indexedBytes: indexedBytes,
            anchor: anchor,
            isComplete: isComplete,
            changeUnixNs: changeUnixNs,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkDependencyKey: forkDependencyKey,
            producerKey: context.resources.currentProducerKey,
            timeZoneIdentifier: context.resources.timeZoneIdentifier)
        do {
            let reference = try context.resources.usageRowStore.append(
                expected: expected,
                updatedSource: updatedSource,
                records: records,
                nextUsageRowIndex: nextUsageRowIndex)
            context.scanBudget?.recordUsageRowWork(
                written: records.count,
                fingerprintHashed: records.count)
            return .persisted(reference.state)
        } catch {
            context.resources.usageRowStore.recordDatabaseFailure(error)
            let disposition = CostUsageCodexUsageRowStore.failureDisposition(for: error)
            Self.log.warning(
                "Codex usage-row sidecar append failed; deferring cursor publication",
                metadata: [
                    "path": fileURL.path,
                    "error": "\(error)",
                    "disposition": disposition == .needsRebuild ? "rebuild" : "retry",
                ])
            return disposition == .needsRebuild ? .rebuildNextPass : .retryLater
        }
    }
    // swiftlint:enable function_parameter_count
}

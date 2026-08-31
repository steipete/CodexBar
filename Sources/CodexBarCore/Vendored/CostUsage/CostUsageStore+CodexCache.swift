import Foundation

enum CostUsagePersistenceAction: Equatable {
    case reuse
    case append(startingAt: Int)
    case replace

    func materialize<Source, Persisted>(
        _ source: [Source],
        transform: (Int, Source) -> Persisted?) -> [Persisted]
    {
        switch self {
        case .reuse:
            []
        case let .append(startingAt):
            source.enumerated().dropFirst(startingAt).compactMap { index, value in
                transform(index, value)
            }
        case .replace:
            source.enumerated().compactMap { index, value in
                transform(index, value)
            }
        }
    }
}

enum CostUsagePersistencePlanner {
    static func action(
        canReuse: Bool,
        stableCursor: Bool,
        appendSafe: Bool,
        persistedCount: Int,
        sourceCount: Int) -> CostUsagePersistenceAction
    {
        if canReuse, stableCursor, persistedCount == sourceCount {
            return .reuse
        }
        if appendSafe, persistedCount <= sourceCount {
            return .append(startingAt: persistedCount)
        }
        return .replace
    }
}

extension CostUsageStore {
    static let defaultRowBudget = 25000
    static let defaultFileBudgetBytes: Int64 = 256 * 1024 * 1024

    func loadCodexCache(calendar: Calendar) -> CostUsageCache {
        self.retainedCodexBaseline = nil
        _ = self.removeLegacyCodexArtifactIfPresent()
        let snapshot = self.readSnapshot()
        guard snapshot.metadata.timeZoneIdentifier == nil
            || snapshot.metadata.timeZoneIdentifier == calendar.timeZone.identifier
        else { return CostUsageCache() }
        return Self.cache(from: snapshot, recorder: self.scopedReadWorkRecorderForTesting)
    }

    func loadCodexReadView(calendar: Calendar, purpose: CostUsageStoreReadPurpose) -> CostUsageStoreReadView {
        self.retainedCodexBaseline = nil
        _ = self.removeLegacyCodexArtifactIfPresent()
        return self.withDatabase(default: CostUsageStoreReadView(cache: CostUsageCache())) { database in
            let recorder = self.scopedReadWorkRecorderForTesting
            let (snapshot, retryPresence) = try Self.inReadTransaction(database) {
                let snapshot = try CostUsageStoreSnapshot(
                    metadata: Self.readSingleton(
                        CostUsageStoreMetadata.self, database: database, table: "scan_metadata") ?? .empty,
                    files: Self.readFiles(database, recorder: recorder),
                    tokenSnapshots: [],
                    usageRows: purpose == .report ? Self.readUsageRows(database, path: nil, recorder: recorder) : [],
                    fileDayAggregates: purpose == .report ? Self.readFileDayAggregates(database, path: nil) : [],
                    dayAggregates: purpose == .report
                        ? Self.readDayAggregates(database, sinceDay: nil, untilDay: nil) : [],
                    forkLineage: Self.readForkLineage(database, path: nil),
                    bufferedLines: [],
                    discoveryState: Self.readSingleton(
                        CostUsageStoreDiscoveryState.self, database: database, table: "discovery_state"),
                    lookbackState: Self.readSingleton(
                        CostUsageStoreLookbackState.self, database: database, table: "lookback_state"),
                    accumulators: [])
                let retryPresence = try Self.readRetryBufferPresence(database, recorder: recorder)
                return (snapshot, retryPresence)
            }
            guard snapshot.metadata.timeZoneIdentifier == nil
                || snapshot.metadata.timeZoneIdentifier == calendar.timeZone.identifier
            else { return CostUsageStoreReadView(cache: CostUsageCache()) }
            // Identity/anchor reconciliation touches the filesystem; do not pin a SQLite reader during it.
            recorder?.recordReadViewConversion(database: database)
            return CostUsageStoreReadView(cache: Self.cache(
                from: snapshot, recorder: recorder, retryPresence: retryPresence))
        }
    }

    @discardableResult
    func saveCodexCache(
        _ cache: CostUsageCache,
        calendar: Calendar,
        requestedScanWindow: (sinceKey: String, untilKey: String),
        reportWindow: (sinceKey: String, untilKey: String)? = nil,
        rowBudget: Int = CostUsageStore.defaultRowBudget,
        fileBudgetBytes: Int64 = CostUsageStore.defaultFileBudgetBytes,
        skipIdenticalContent: Bool = false,
        receipt: CodexBaselineReceipt? = nil) -> CostUsageStoreBudgetResult
    {
        guard let baseline = self.takeCodexBaseline(receipt), self.codexBaselineIsCurrent(baseline) else {
            return Self.rescanRequired()
        }
        var cache = cache
        Self.reconcileCompletedCodexCatchUp(cache: &cache)
        let previous = baseline.persistence
        let budgetProtectionWindow = Self.budgetProtectionWindow(
            cache: cache,
            requestedScanWindow: requestedScanWindow)
        if skipIdenticalContent,
           Self.persistedContentMatches(baseline: baseline, cache: cache, calendar: calendar)
        {
            // Retention owns the safety boundary even when the scanner's content is unchanged.
            let result = self.enforceBudgets(
                maxRows: rowBudget,
                maxFileBytes: fileBudgetBytes,
                requestedSinceDay: budgetProtectionWindow.sinceKey,
                requestedUntilDay: budgetProtectionWindow.untilKey,
                calendar: calendar)
            guard !result.catchUpRequired else { return result }
            self.codexSavePreLockCheckpoint()
            guard self.beginSaveTransaction() else { return Self.rescanRequired(result) }

            // Revalidate after retention and under the writer lock. External changes must never
            // authorize a comparison or rewrite against this scanner's stale decoded baseline.
            guard let locked = self.codexBaselineAfterRetention(baseline),
                  Self.persistedContentMatches(baseline: locked, cache: cache, calendar: calendar),
                  self.codexBaselineIsCurrent(locked)
            else {
                _ = self.rollbackSaveTransaction()
                return Self.rescanRequired(result)
            }
            guard self.persistPriorityTurnsCursorIfChanged(previous: locked, cache: cache) else {
                _ = self.rollbackSaveTransaction()
                return Self.rescanRequired(result)
            }
            guard self.advanceLastScanUnixMsInCurrentTransaction(cache.lastScanUnixMs) else {
                _ = self.rollbackSaveTransaction()
                return Self.rescanRequired(result)
            }
            guard self.endSaveTransaction() else { return Self.rescanRequired(result) }
            return result
        }
        let canReuseStoredRows = previous.metadata.timeZoneIdentifier == calendar.timeZone.identifier
        let previousFilesByPath = Dictionary(uniqueKeysWithValues: previous.files.map { ($0.path, $0) })
        let retry = CostUsageStoreBudgetResult(
            deletedRows: 0, rowCount: previous.files.count, fileBytes: 0, catchUpRequired: true)
        // No transaction spans the JSONL scan. Changed saves must validate their original
        // baseline under the lock too, before deleting files or reusing persisted row prefixes.
        self.codexSavePreLockCheckpoint()
        guard self.beginSaveTransaction() else { return retry }
        guard self.codexBaselineIsCurrent(baseline) else {
            _ = self.rollbackSaveTransaction()
            return retry
        }
        self.deleteRemovedFiles(previous: previous, cache: cache)
        var persistedFiles = 0
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            self.persistFile(
                path: path,
                usage: usage,
                baseline: PersistedFileBaseline(
                    file: previousFilesByPath[path],
                    snapshotCount: previous.snapshotCounts[path] ?? 0,
                    rowCount: previous.rowCounts[path] ?? 0,
                    canReuseRows: canReuseStoredRows),
                calendar: calendar)
            persistedFiles += 1
            Self.saveCycleCheckpointForTesting?(persistedFiles)
        }
        _ = self.replaceDayAggregates(Self.globalAggregates(
            cache: cache, recorder: self.scopedReadWorkRecorderForTesting))
        _ = self.setMetadata(Self.metadata(cache: cache, calendar: calendar))
        _ = self.setDiscoveryState(Self.discoveryState(cache.codexSessionDiscovery))
        _ = self.setLookbackState(Self.lookbackState(cache.codexActiveLookbackState))
        guard self.endSaveTransaction() else { return retry }
        // Checkpointing and vacuuming must remain outside the save transaction.
        let result = self.enforceBudgets(
            maxRows: rowBudget,
            maxFileBytes: fileBudgetBytes,
            requestedSinceDay: budgetProtectionWindow.sinceKey,
            requestedUntilDay: budgetProtectionWindow.untilKey,
            calendar: calendar)
        if result.catchUpRequired, self.fetchMetadata().previousReportPayload == nil,
           let previous = Self.previousReport(cache: cache, calendar: calendar, reportWindow: reportWindow)
        {
            var metadata = self.fetchMetadata()
            metadata.previousReportPayload = try? JSONEncoder().encode(previous)
            _ = self.setMetadata(metadata)
        }
        return result
    }

    private static func rescanRequired(
        _ result: CostUsageStoreBudgetResult = .init(deletedRows: 0, rowCount: 0, fileBytes: 0))
        -> CostUsageStoreBudgetResult
    {
        var result = result
        result.catchUpRequired = true
        return result
    }

    private func codexSavePreLockCheckpoint() {
        if let checkpoint = Self.identicalContentPreLockCheckpointForTesting,
           checkpoint.databaseURL == self.databaseURL
        {
            checkpoint.checkpoint()
        }
    }

    /// True when persisting `cache` would leave every content table semantically unchanged.
    /// This remains O(persisted cache rows), but reuses typed decoding and reruns current
    /// filesystem/anchor reconciliation. The
    /// persisted spellings of a few optional fields differ from their in-memory forms
    /// (`catchUpPending` and `codexScanComplete` store nil as false/true, `timeZoneIdentifier`
    /// is fixed by the caller's calendar, and `lastScanUnixMs` is a wall-clock stamp), so
    /// those are normalized before the comparison. The priority sqlite cursor is also ignored
    /// here: it advances independently of usage content and is written as a metadata-only
    /// update on the skip path.
    private static func persistedContentMatches(
        baseline: CodexDecodedBaseline,
        cache: CostUsageCache,
        calendar: Calendar) -> Bool
    {
        var restored = Self.reconciledCodexCache(baseline.decoded, persistence: baseline.persistence)
        guard restored.timeZoneIdentifier == nil
            || restored.timeZoneIdentifier == calendar.timeZone.identifier
        else { return false }
        guard (cache.codexScanCatchUpPending ?? false) == restored.codexScanCatchUpPending
        else { return false }
        // Freshness and the sqlite cursor are ignored semantic fields. The time zone is a
        // persistence-derived spelling: metadata(cache:calendar:) always writes the caller's
        // calendar identifier.
        restored.lastScanUnixMs = cache.lastScanUnixMs
        restored.timeZoneIdentifier = calendar.timeZone.identifier
        restored.codexScanCatchUpPending = cache.codexScanCatchUpPending
        restored.files = restored.files.mapValues(Self.normalizingScanComplete)
        var incoming = cache
        incoming.timeZoneIdentifier = calendar.timeZone.identifier
        incoming.files = incoming.files.mapValues(Self.normalizingScanComplete)
        restored.codexPriorityTurnsCursor = incoming.codexPriorityTurnsCursor
        return restored == incoming
    }

    /// Writes only `scan_metadata.priorityTurnStatePayload` when the sqlite cursor advanced.
    /// Caller already owns the save transaction.
    private func persistPriorityTurnsCursorIfChanged(
        previous: CodexDecodedBaseline,
        cache: CostUsageCache) -> Bool
    {
        guard previous.decoded.codexPriorityTurnsCursor != cache.codexPriorityTurnsCursor else {
            return true
        }
        guard let payload = Self.priorityTurnStatePayload(cache: cache) else { return false }
        var metadata = previous.persistence.metadata
        metadata.priorityTurnStatePayload = payload
        return self.setMetadata(metadata)
    }

    private static func normalizingScanComplete(_ usage: CostUsageFileUsage) -> CostUsageFileUsage {
        var usage = usage
        usage.codexScanComplete = usage.codexScanComplete ?? true
        return usage
    }

    private static func budgetProtectionWindow(
        cache: CostUsageCache,
        requestedScanWindow: (sinceKey: String, untilKey: String)) -> (sinceKey: String, untilKey: String)
    {
        // Report and dashboard windows are projections, not retention boundaries. Preserve the
        // cache's retained coverage while still protecting any newly requested extension.
        guard let retainedSinceKey = cache.scanSinceKey,
              let retainedUntilKey = cache.scanUntilKey,
              retainedSinceKey <= retainedUntilKey
        else { return requestedScanWindow }
        return (
            sinceKey: min(retainedSinceKey, requestedScanWindow.sinceKey),
            untilKey: max(retainedUntilKey, requestedScanWindow.untilKey))
    }
}

// MARK: - Cache conversion

extension CostUsageStore {
    private struct StoredFileDetails: Codable {
        var lastTotals: CostUsageCodexTotals?
        var projectPath: String?
        var canonicalProjectPath: String?
        var costCacheComplete: Bool?
        var session: CostUsageCodexSessionMetadata?
        var workspaceFingerprint: String?
        var hasRows: Bool
        var hasTurnIDs: Bool
        var hasTokenSnapshots: Bool
        var hasSeenRawTotals: Bool
        var divergentTotals: Bool?
        var interleavedTotals: Bool?
    }

    private struct StoredPriorityState: Codable {
        var turnKeys: [String: String]?
        var turnIDsByDay: [String: [String]]?
        var turnsCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?

        enum CodingKeys: String, CodingKey {
            case turnKeys
            case turnIDsByDay
            case turnsCursor
        }

        init(
            turnKeys: [String: String]?,
            turnIDsByDay: [String: [String]]?,
            turnsCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?)
        {
            self.turnKeys = turnKeys
            self.turnIDsByDay = turnIDsByDay
            self.turnsCursor = turnsCursor
        }

        /// Cursor decode is best-effort so a malformed `turnsCursor` cannot drop load-bearing
        /// `turnKeys` / `turnIDsByDay`. `encode(to:)` stays synthesized.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.turnKeys = try container.decodeIfPresent([String: String].self, forKey: .turnKeys)
            self.turnIDsByDay = try container.decodeIfPresent([String: [String]].self, forKey: .turnIDsByDay)
            self.turnsCursor = try? container.decodeIfPresent(
                CostUsageScanner.CodexPriorityTurnsPersistedCursor.self,
                forKey: .turnsCursor)
        }
    }

    private struct DayModelKey: Hashable {
        var day: String
        var model: String
    }

    private struct PersistedFileBaseline {
        var file: CostUsageStoreFile?
        var snapshotCount: Int
        var rowCount: Int
        var canReuseRows: Bool
    }

    private struct CurrentCodexRootDevice {
        var path: String
        var device: String
    }

    private struct RestoredCodexScanState {
        var identity: String?
        var isComplete: Bool
        var validatedCurrentSnapshot = false
    }

    private static func cache(
        from snapshot: CostUsageStoreSnapshot,
        recorder: CostUsageStoreReadWorkRecorder?,
        retryPresence: [String: CostUsageCodexRetryBufferPresence]? = nil) -> CostUsageCache
    {
        self.reconciledCodexCache(
            self.decodeCodexCache(from: snapshot, recorder: recorder, retryPresence: retryPresence),
            persistence: CodexPersistenceState(snapshot: snapshot))
    }

    static func decodeCodexCache(
        from snapshot: CostUsageStoreSnapshot,
        recorder: CostUsageStoreReadWorkRecorder?,
        retryPresence: [String: CostUsageCodexRetryBufferPresence]? = nil) -> CostUsageCache
    {
        recorder?.recordCacheConversion()
        var cache = CostUsageCache()
        let metadata = snapshot.metadata
        cache.lastScanUnixMs = metadata.lastScanUnixMs
        cache.scanSinceKey = metadata.scanSinceDay
        cache.scanUntilKey = metadata.scanUntilDay
        cache.timeZoneIdentifier = metadata.timeZoneIdentifier
        cache.codexPricingKey = metadata.pricingKey
        cache.codexPriorityMetadataKey = metadata.priorityMetadataKey
        cache.codexScanCatchUpPending = metadata.catchUpPending
        cache.codexScanProcessedBytes = metadata.processedBytes
        cache.codexScanTotalBytes = metadata.totalBytes
        cache.codexScanCompletedFiles = metadata.completedFiles
        cache.codexScanTotalFiles = metadata.totalFiles
        cache.codexScanInventoryPaths = metadata.scanInventoryPaths
        cache.roots = metadata.rootMtimes
        cache.codexProjectMetadataVersion = metadata.projectMetadataVersion
        cache.codexPreviousReport = metadata.previousReportPayload.flatMap {
            try? JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: $0)
        }
        if let priority = metadata.priorityTurnStatePayload.flatMap({
            try? JSONDecoder().decode(StoredPriorityState.self, from: $0)
        }) {
            cache.codexPriorityTurnKeys = priority.turnKeys
            cache.codexPriorityTurnIDsByDay = priority.turnIDsByDay
            cache.codexPriorityTurnsCursor = priority.turnsCursor
        }
        cache.codexSessionDiscovery = snapshot.discoveryState.flatMap(Self.discovery(from:))
        cache.codexActiveLookbackState = snapshot.lookbackState.map(Self.lookback(from:))

        let snapshotsByPath = Dictionary(grouping: snapshot.tokenSnapshots, by: \.path)
        let rowsByPath = Dictionary(grouping: snapshot.usageRows, by: \.path)
        let aggregatesByPath = Dictionary(grouping: snapshot.fileDayAggregates, by: \.path)
        let lineageByPath = Dictionary(uniqueKeysWithValues: snapshot.forkLineage.map { ($0.path, $0) })
        let buffersByPath = Dictionary(grouping: snapshot.bufferedLines, by: \.path)
        let accumulatorByPath = Dictionary(uniqueKeysWithValues: snapshot.accumulators.map { ($0.path, $0) })

        for file in snapshot.files {
            guard let detailsData = file.scanState.detailsPayload,
                  let details = try? JSONDecoder().decode(StoredFileDetails.self, from: detailsData)
            else { continue }
            let aggregates = (aggregatesByPath[file.path] ?? []).map(\.aggregate)
            recorder?.recordUsageRowDecodes(count: rowsByPath[file.path]?.count ?? 0)
            let rows = (rowsByPath[file.path] ?? []).compactMap {
                try? JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: $0.payload)
            }
            let restoredRows = rows.isEmpty ? Self.aggregateRows(from: aggregates) : rows
            let tokenSnapshots = (snapshotsByPath[file.path] ?? []).map(Self.tokenSnapshot(from:))
            let lineage = lineageByPath[file.path]
            let accumulator = accumulatorByPath[file.path]
            let buffers = buffersByPath[file.path] ?? []
            let usage = CostUsageFileUsage(
                mtimeUnixMs: file.mtimeUnixMs,
                size: file.size,
                days: Self.days(from: aggregates),
                parsedBytes: file.parsedBytes,
                lastModel: file.scanState.lastModel,
                lastTotals: details.lastTotals,
                lastCountedTotals: Self.totals(from: accumulator?.countedTotals),
                lastRawTotalsBaseline: Self.totals(from: accumulator?.rawTotalsBaseline),
                lastRawTotalsWatermark: Self.totals(from: accumulator?.rawTotalsWatermark),
                seenRawTotals: details.hasSeenRawTotals
                    ? accumulator?.seenRawTotals.compactMap(Self.totals(from:)) ?? []
                    : nil,
                hasDivergentTotals: details.divergentTotals,
                hasInterleavedTotals: details.interleavedTotals,
                lastCodexTurnID: file.scanState.lastTurnID,
                sessionId: file.sessionID,
                forkedFromId: lineage?.forkedFromID,
                forkBaselineDependencyKey: lineage?.dependencyKey,
                projectPath: details.projectPath,
                canonicalProjectPath: details.canonicalProjectPath,
                codexCostCacheComplete: details.costCacheComplete,
                codexSession: details.session,
                codexCostNanos: Self.authoritativeCosts(from: aggregates),
                codexPrioritySurchargeNanos: nil,
                codexStandardCostNanos: nil,
                codexPriorityCostNanos: nil,
                codexStandardTokens: Self.modeTokens(from: aggregates, priority: false),
                codexPriorityTokens: Self.modeTokens(from: aggregates, priority: true),
                codexTurnIDs: details.hasTurnIDs ? CostUsageScanner.codexTurnIDs(rows: rows) ?? [] : nil,
                codexWorkspaceContentFingerprint: details.workspaceFingerprint,
                codexRows: details.hasRows ? restoredRows : nil,
                codexTokenSnapshots: details.hasTokenSnapshots ? tokenSnapshots : nil,
                codexTokenCheckpoints: details.hasTokenSnapshots
                    ? CostUsageScanner.codexTokenCheckpoints(for: tokenSnapshots) : nil,
                codexTokenTimestampsMonotonic: file.scanState.tokenTimestampsMonotonic,
                codexTokenIndexAnchor: file.anchor.map {
                    CostUsageCodexTokenIndexAnchor(
                        indexedBytes: $0.indexedBytes,
                        windowStart: $0.windowStart,
                        sha256: $0.sha256)
                },
                claudeRows: nil,
                codexScanFileId: file.scanState.fileIdentity,
                codexScanTargetSize: file.scanState.targetSize,
                codexScanComplete: file.scanState.isComplete,
                codexJSONLResumeState: file.scanState.resumePayload.flatMap {
                    try? JSONDecoder().decode(CostUsageJsonl.ResumeState.self, from: $0)
                },
                codexBufferedSubagentLines: Self.bufferedLines(buffers, kind: .subagent),
                codexBufferedUnresolvedForkLines: Self.bufferedLines(buffers, kind: .unresolvedFork),
                codexReadRetryBufferPresence: retryPresence.map { $0[file.path] ?? .init() })
            cache.files[file.path] = usage
        }
        cache.days = Self.days(from: snapshot.dayAggregates)
        return cache
    }

    static func reconciledCodexCache(
        _ decoded: CostUsageCache,
        persistence: CodexPersistenceState) -> CostUsageCache
    {
        var cache = decoded
        let metadata = persistence.metadata
        let currentRootDevices = Self.currentCodexRootDevices(rootMtimes: metadata.rootMtimes)
        var remainingIdentityValidationVisits = CostUsageScanner.codexCatchUpScanCandidateLimit
        var deferredIdentityValidationPaths: [String] = []
        var completedIdentityValidationPaths: [String] = []
        var invalidatedIdentityValidationPaths: [String] = []

        for file in persistence.files {
            guard var usage = cache.files[file.path] else { continue }
            let normalizedIdentity = Self.normalizedCodexFileIdentity(
                file: file,
                currentRootDevices: currentRootDevices)
            let identityNeedsValidation = normalizedIdentity != file.scanState.fileIdentity
            let restoredScanState: RestoredCodexScanState
            if identityNeedsValidation, remainingIdentityValidationVisits > 0 {
                Self.codexCatchUpReconciliationVisitForTesting?()
                remainingIdentityValidationVisits -= 1
                restoredScanState = Self.restoredCodexScanState(
                    file: file,
                    currentRootDevices: currentRootDevices,
                    validateMetadata: true)
                if restoredScanState.isComplete, restoredScanState.validatedCurrentSnapshot {
                    completedIdentityValidationPaths.append(file.path)
                } else {
                    invalidatedIdentityValidationPaths.append(file.path)
                }
            } else if identityNeedsValidation {
                deferredIdentityValidationPaths.append(file.path)
                restoredScanState = RestoredCodexScanState(
                    identity: file.scanState.fileIdentity,
                    isComplete: file.scanState.isComplete)
            } else {
                restoredScanState = RestoredCodexScanState(
                    identity: normalizedIdentity,
                    isComplete: file.scanState.isComplete)
            }
            usage.codexScanFileId = restoredScanState.identity
            usage.codexScanComplete = restoredScanState.isComplete
            cache.files[file.path] = usage
        }
        Self.enqueueDeferredCodexIdentityValidation(
            deferredIdentityValidationPaths + invalidatedIdentityValidationPaths,
            metadata: metadata,
            cache: &cache)
        Self.removeCompletedCodexIdentityValidation(
            completedIdentityValidationPaths,
            cache: &cache)
        Self.reconcileCompletedCodexCatchUp(
            cache: &cache,
            visitLimit: remainingIdentityValidationVisits)
        return cache
    }

    private static func enqueueDeferredCodexIdentityValidation(
        _ paths: [String],
        metadata: CostUsageStoreMetadata,
        cache: inout CostUsageCache)
    {
        guard !paths.isEmpty, let scanSinceKey = metadata.scanSinceDay else { return }
        let rootPaths = (metadata.rootMtimes ?? [:]).keys.map { path in
            Self.normalizedCodexPath(
                URL(fileURLWithPath: path, isDirectory: true)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path)
        }.sorted()
        guard !rootPaths.isEmpty else { return }
        var lookback = cache.codexActiveLookbackState ?? CostUsageCodexActiveLookbackState(
            scanSinceKey: scanSinceKey,
            rootPaths: rootPaths,
            completedRootPaths: rootPaths,
            currentWindowNextDayKeyByRoot: [:],
            currentWindowDirectoryOffsetByRoot: [:],
            completedCurrentWindowRootPaths: rootPaths,
            currentWindowFlatDirectoryOffsetByRoot: [:],
            completedCurrentWindowFlatRootPaths: rootPaths)
        var pendingPaths = Set(lookback.pendingFilePaths)
        lookback.pendingFilePaths.append(contentsOf: paths.filter { pendingPaths.insert($0).inserted })
        cache.codexActiveLookbackState = lookback
        cache.codexScanCatchUpPending = true
    }

    private static func removeCompletedCodexIdentityValidation(
        _ paths: [String],
        cache: inout CostUsageCache)
    {
        guard !paths.isEmpty, var lookback = cache.codexActiveLookbackState else { return }
        let completedPathKeys = Set(paths.map(Self.normalizedCodexPath))
        lookback.pendingFilePaths.removeAll { path in
            completedPathKeys.contains(Self.normalizedCodexPath(path))
        }
        cache.codexActiveLookbackState = lookback
    }

    private static func currentCodexRootDevices(
        rootMtimes: [String: Int64]?) -> [CurrentCodexRootDevice]
    {
        (rootMtimes ?? [:]).keys.compactMap { path in
            let rootURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: rootURL)
            guard let device = Self.device(from: metadata.fileId) else { return nil }
            return CurrentCodexRootDevice(path: Self.normalizedCodexPath(rootURL.path), device: device)
        }.sorted { $0.path.count > $1.path.count }
    }

    private static func normalizedCodexFileIdentity(
        file: CostUsageStoreFile,
        currentRootDevices: [CurrentCodexRootDevice]) -> String?
    {
        guard let identity = file.scanState.fileIdentity,
              let inode = Self.inode(from: identity)
        else { return file.scanState.fileIdentity }
        if let persistedInode = file.inode, persistedInode != inode {
            return identity
        }
        let filePath = Self.normalizedCodexPath(file.path)
        guard let root = currentRootDevices.first(where: { root in
            if filePath == root.path {
                return true
            }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return filePath.hasPrefix(prefix)
        }) else { return identity }
        return "\(root.device):\(inode)"
    }

    private static func restoredCodexScanState(
        file: CostUsageStoreFile,
        currentRootDevices: [CurrentCodexRootDevice],
        validateMetadata: Bool) -> RestoredCodexScanState
    {
        let identity = Self.normalizedCodexFileIdentity(
            file: file,
            currentRootDevices: currentRootDevices)
        guard validateMetadata else {
            return RestoredCodexScanState(identity: identity, isComplete: file.scanState.isComplete)
        }

        let fileURL = URL(fileURLWithPath: file.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        guard let currentIdentity = metadata.fileId else {
            return RestoredCodexScanState(identity: identity, isComplete: file.scanState.isComplete)
        }
        let metadataIsUnchanged = identity == currentIdentity
            && file.mtimeUnixMs == metadata.mtimeUnixMs
            && file.size == metadata.size
        if metadataIsUnchanged {
            return RestoredCodexScanState(
                identity: identity,
                isComplete: file.scanState.isComplete,
                validatedCurrentSnapshot: true)
        }

        let isAppend = identity == currentIdentity && metadata.size > file.size
        return RestoredCodexScanState(
            identity: isAppend ? identity : nil,
            isComplete: false)
    }

    private static func normalizedCodexPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func reconcileCompletedCodexCatchUp(
        cache: inout CostUsageCache,
        visitLimit: Int = CostUsageScanner.codexCatchUpScanCandidateLimit)
    {
        if var lookback = cache.codexActiveLookbackState {
            let reconciliationLimit = max(0, min(
                visitLimit,
                CostUsageScanner.codexCatchUpScanCandidateLimit))
            let candidatePaths = lookback.pendingFilePaths.prefix(reconciliationLimit)
            var completedIdentityValidationPathKeys: Set<String> = []
            for path in candidatePaths {
                Self.codexCatchUpReconciliationVisitForTesting?()
                let fileURL = URL(fileURLWithPath: path)
                let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
                guard let fileId = metadata.fileId,
                      let cachedEntry = Self.cachedCodexUsageEntry(for: path, cache: cache),
                      cachedEntry.usage.codexScanComplete != false,
                      !cachedEntry.usage.hasBufferedCodexForkRetryLines
                else {
                    continue
                }

                guard Self.matchesCompletedCodexFileSnapshot(
                    usage: cachedEntry.usage,
                    metadata: metadata,
                    fileURL: fileURL)
                else {
                    continue
                }

                // APFS can expose the same volume with a different st_dev value after relaunch.
                // Retain the inode and validate the indexed content before adopting the current identity.
                if cachedEntry.usage.codexScanFileId != fileId,
                   var normalized = cache.files[cachedEntry.path]
                {
                    normalized.codexScanFileId = fileId
                    cache.files[cachedEntry.path] = normalized
                    completedIdentityValidationPathKeys.insert(Self.normalizedCodexPath(path))
                }
            }
            if !completedIdentityValidationPathKeys.isEmpty {
                lookback.pendingFilePaths.removeAll { path in
                    completedIdentityValidationPathKeys.contains(Self.normalizedCodexPath(path))
                }
            }
            let rootPaths = Set(lookback.rootPaths)
            let lookbackIsComplete = Set(lookback.completedRootPaths) == rootPaths
                && Set(lookback.completedCurrentWindowRootPaths ?? []) == rootPaths
                && Set(lookback.completedCurrentWindowFlatRootPaths ?? []) == rootPaths
                && lookback.pendingFilePaths.isEmpty
                && lookback.legacyRecursivePendingRootPaths.isEmpty
            let awaitingExactValidation = cache.codexScanCatchUpPending == true
                && cache.codexScanInventoryPaths == nil
            cache.codexActiveLookbackState = lookbackIsComplete && !awaitingExactValidation ? nil : lookback
        }

        guard cache.codexScanCatchUpPending == true,
              cache.codexActiveLookbackState == nil
        else { return }
        let discoveryHasPendingWork = cache.codexSessionDiscovery.map {
            !$0.isComplete && (!$0.pendingSessionIds.isEmpty || $0.headScan != nil)
        } ?? false
        guard !discoveryHasPendingWork else { return }
        let filesHavePendingWork = cache.files.values.contains {
            $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
        }
        guard !filesHavePendingWork else { return }
        let expectedTotalFiles = max(0, cache.codexScanTotalFiles ?? 0)
        let reconciliationLimit = CostUsageScanner.codexCatchUpScanCandidateLimit
        guard expectedTotalFiles <= reconciliationLimit,
              (cache.codexScanInventoryPaths?.count ?? 0) <= reconciliationLimit
        else { return }
        guard let completedInventory = Self.completedCodexScanInventory(
            cache: cache,
            expectedTotalFiles: expectedTotalFiles)
        else { return }

        cache.codexScanCatchUpPending = false
        cache.codexScanProcessedBytes = completedInventory.totalBytes
        cache.codexScanTotalBytes = completedInventory.totalBytes
        cache.codexScanCompletedFiles = completedInventory.fileCount
        cache.codexScanTotalFiles = completedInventory.fileCount
        cache.codexPreviousReport = nil
    }

    private static func cachedCodexUsageEntry(
        for path: String,
        cache: CostUsageCache) -> (path: String, usage: CostUsageFileUsage)?
    {
        let normalizedPath = Self.normalizedCodexPath(path)
        var candidatePaths = [path]
        if normalizedPath != path {
            candidatePaths.append(normalizedPath)
        }
        if normalizedPath.hasPrefix("/var/") {
            candidatePaths.append("/private" + normalizedPath)
        }
        var seenPaths: Set<String> = []
        for candidatePath in candidatePaths where seenPaths.insert(candidatePath).inserted {
            if let usage = cache.files[candidatePath] {
                return (candidatePath, usage)
            }
        }
        return nil
    }

    private static func completedCodexScanInventory(
        cache: CostUsageCache,
        expectedTotalFiles: Int) -> (fileCount: Int, totalBytes: Int64)?
    {
        guard expectedTotalFiles > 0,
              let inventoryPaths = cache.codexScanInventoryPaths,
              !inventoryPaths.isEmpty
        else { return nil }

        let cachedFilesByIdentity = cache.files.values.reduce(
            into: [String: CostUsageFileUsage]())
        { result, usage in
            guard let identity = usage.codexScanFileId else { return }
            result[identity] = usage
        }
        let cachedFilesByNormalizedPath = cache.files.reduce(
            into: [String: CostUsageFileUsage]())
        { result, entry in
            result[Self.normalizedCodexPath(entry.key)] = entry.value
        }

        var seenIdentities: Set<String> = []
        var totalBytes: Int64 = 0
        for path in inventoryPaths {
            let fileURL = URL(fileURLWithPath: path)
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            guard let fileId = metadata.fileId else { return nil }
            guard seenIdentities.insert(fileId).inserted else { continue }
            guard let usage = cache.files[path]
                ?? cachedFilesByNormalizedPath[Self.normalizedCodexPath(path)]
                ?? cachedFilesByIdentity[fileId],
                usage.codexScanComplete != false,
                !usage.hasBufferedCodexForkRetryLines,
                Self.matchesCompletedCodexFileSnapshot(
                    usage: usage,
                    metadata: metadata,
                    fileURL: fileURL)
            else { return nil }
            totalBytes += max(0, metadata.size)
        }

        guard seenIdentities.count == expectedTotalFiles else { return nil }
        return (seenIdentities.count, totalBytes)
    }

    private static func matchesCompletedCodexFileSnapshot(
        usage: CostUsageFileUsage,
        metadata: CostUsageScanner.CodexFileMetadata,
        fileURL: URL) -> Bool
    {
        guard usage.mtimeUnixMs == metadata.mtimeUnixMs,
              usage.size == metadata.size,
              let cachedIdentity = usage.codexScanFileId,
              let currentIdentity = metadata.fileId
        else { return false }
        if cachedIdentity == currentIdentity {
            return true
        }
        guard Self.inode(from: cachedIdentity) == Self.inode(from: currentIdentity) else {
            return false
        }
        if metadata.size == 0 {
            return true
        }
        guard let anchor = usage.codexTokenIndexAnchor else { return false }
        return CostUsageScanner.codexTokenIndexAnchorMatches(
            anchor,
            fileURL: fileURL,
            metadata: metadata)
    }

    private func persistFile(
        path: String,
        usage: CostUsageFileUsage,
        baseline: PersistedFileBaseline,
        calendar: Calendar)
    {
        let sourceSnapshots = usage.codexTokenSnapshots ?? []
        let sourceRows = usage.codexRows ?? []
        let snapshotCount = sourceSnapshots.count
        let rowCount = sourceRows.count
        let details = StoredFileDetails(
            lastTotals: usage.lastTotals,
            projectPath: usage.projectPath,
            canonicalProjectPath: usage.canonicalProjectPath,
            costCacheComplete: usage.codexCostCacheComplete,
            session: usage.codexSession,
            workspaceFingerprint: usage.codexWorkspaceContentFingerprint,
            hasRows: usage.codexRows != nil,
            hasTurnIDs: usage.codexTurnIDs != nil,
            hasTokenSnapshots: usage.codexTokenSnapshots != nil,
            hasSeenRawTotals: usage.seenRawTotals != nil,
            divergentTotals: usage.hasDivergentTotals,
            interleavedTotals: usage.hasInterleavedTotals)
        let file = CostUsageStoreFile(
            path: path,
            inode: Self.inode(from: usage.codexScanFileId),
            mtimeUnixMs: usage.mtimeUnixMs,
            size: usage.size,
            parsedBytes: usage.parsedBytes,
            anchor: usage.codexTokenIndexAnchor.map {
                CostUsageStoreValidationAnchor(
                    indexedBytes: $0.indexedBytes,
                    windowStart: $0.windowStart,
                    sha256: $0.sha256)
            },
            scanState: CostUsageStoreScanState(
                targetSize: usage.codexScanTargetSize,
                isComplete: usage.codexScanComplete != false,
                resumePayload: usage.codexJSONLResumeState.flatMap { try? JSONEncoder().encode($0) },
                tokenTimestampsMonotonic: usage.codexTokenTimestampsMonotonic,
                nextUsageRowIndex: CostUsageScanner.nextCodexUsageRowIndex(usage.codexRows),
                lastModel: usage.lastModel,
                lastTurnID: usage.lastCodexTurnID,
                fileIdentity: usage.codexScanFileId,
                detailsPayload: try? JSONEncoder().encode(details)),
            sessionID: usage.sessionId,
            coverageSinceDay: usage.days.keys.min(),
            coverageUntilDay: usage.days.keys.max(),
            updatedAtUnixMs: max(usage.mtimeUnixMs, usage.codexSession?.latestActivityUnixMs ?? 0))
        _ = self.upsertFile(file)

        let oldParsedBytes = baseline.file?.parsedBytes ?? 0
        let newParsedBytes = file.parsedBytes ?? 0
        let appendSafe = baseline.canReuseRows
            && baseline.file?.scanState.fileIdentity == file.scanState.fileIdentity
            && oldParsedBytes < newParsedBytes
        let stableCursor = oldParsedBytes == newParsedBytes
        let snapshotAction = CostUsagePersistencePlanner.action(
            canReuse: baseline.canReuseRows,
            stableCursor: stableCursor,
            appendSafe: appendSafe,
            persistedCount: baseline.snapshotCount,
            sourceCount: snapshotCount)
        let snapshots = snapshotAction.materialize(sourceSnapshots) { index, snapshot in
            Self.tokenSnapshot(path: path, eventIndex: index, snapshot: snapshot, calendar: calendar)
        }
        switch snapshotAction {
        case .reuse:
            break
        case .append:
            _ = self.appendTokenSnapshots(snapshots)
        case .replace:
            _ = self.replaceTokenSnapshots(path: path, snapshots: snapshots)
        }

        let rowAction = CostUsagePersistencePlanner.action(
            canReuse: baseline.canReuseRows,
            stableCursor: stableCursor,
            appendSafe: appendSafe,
            persistedCount: baseline.rowCount,
            sourceCount: rowCount)
        let rows: [CostUsageStoreUsageRow] = rowAction.materialize(sourceRows) { index, row in
            guard let payload = try? JSONEncoder().encode(row) else { return nil }
            return CostUsageStoreUsageRow(path: path, rowIndex: index, payload: payload)
        }
        switch rowAction {
        case .reuse:
            break
        case .append:
            _ = self.appendUsageRows(rows)
        case .replace:
            _ = self.replaceUsageRows(path: path, rows: rows)
        }
        _ = self.replaceFileDayAggregates(path: path, aggregates: Self.fileAggregates(
            usage, recorder: self.scopedReadWorkRecorderForTesting))
        _ = self.upsertForkLineage(CostUsageStoreForkLineage(
            path: path,
            sessionID: usage.sessionId,
            forkedFromID: usage.forkedFromId,
            forkTimestamp: nil,
            dependencyKey: usage.forkBaselineDependencyKey,
            subagentState: nil,
            accountingState: nil))
        self.persistBuffers(path: path, usage: usage)
        _ = self.upsertAccumulator(CostUsageStoreAccumulator(
            path: path,
            eventCount: snapshotCount,
            nextUsageRowIndex: CostUsageScanner.nextCodexUsageRowIndex(usage.codexRows),
            countedTotals: Self.totals(usage.lastCountedTotals),
            rawTotalsBaseline: Self.totals(usage.lastRawTotalsBaseline),
            rawTotalsWatermark: Self.totals(usage.lastRawTotalsWatermark),
            sawDivergentTotals: usage.hasDivergentTotals ?? false,
            sawInterleavedTotals: usage.hasInterleavedTotals ?? false,
            seenRawTotals: (usage.seenRawTotals ?? []).map(Self.totals),
            updatedAtUnixMs: file.updatedAtUnixMs))
    }
}

// MARK: - Aggregate and metadata conversion

extension CostUsageStore {
    private static func metadata(cache: CostUsageCache, calendar: Calendar) -> CostUsageStoreMetadata {
        CostUsageStoreMetadata(
            lastScanUnixMs: cache.lastScanUnixMs,
            scanSinceDay: cache.scanSinceKey,
            scanUntilDay: cache.scanUntilKey,
            timeZoneIdentifier: calendar.timeZone.identifier,
            pricingKey: cache.codexPricingKey,
            priorityMetadataKey: cache.codexPriorityMetadataKey,
            catchUpPending: cache.codexScanCatchUpPending == true,
            processedBytes: cache.codexScanProcessedBytes,
            totalBytes: cache.codexScanTotalBytes,
            completedFiles: cache.codexScanCompletedFiles,
            totalFiles: cache.codexScanTotalFiles,
            scanInventoryPaths: cache.codexScanInventoryPaths,
            rootMtimes: cache.roots,
            previousReportPayload: cache.codexPreviousReport.flatMap { try? JSONEncoder().encode($0) },
            priorityTurnStatePayload: self.priorityTurnStatePayload(cache: cache),
            projectMetadataVersion: cache.codexProjectMetadataVersion)
    }

    private static func priorityTurnStatePayload(cache: CostUsageCache) -> Data? {
        try? JSONEncoder().encode(StoredPriorityState(
            turnKeys: cache.codexPriorityTurnKeys,
            turnIDsByDay: cache.codexPriorityTurnIDsByDay,
            turnsCursor: cache.codexPriorityTurnsCursor))
    }

    private static func previousReport(
        cache: CostUsageCache,
        calendar: Calendar,
        reportWindow: (sinceKey: String, untilKey: String)?) -> CostUsageCodexPreviousReport?
    {
        guard let sinceKey = reportWindow?.sinceKey ?? cache.scanSinceKey,
              let untilKey = reportWindow?.untilKey ?? cache.scanUntilKey,
              let since = CostUsageScanner.parseDayKey(sinceKey, calendar: calendar),
              let until = CostUsageScanner.parseDayKey(untilKey, calendar: calendar)
        else { return nil }
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: calendar)
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        return CostUsageCodexPreviousReport(
            report: report,
            cache: cache,
            reportSinceKey: sinceKey,
            reportUntilKey: untilKey)
    }

    private static func fileAggregates(
        _ usage: CostUsageFileUsage,
        recorder: CostUsageStoreReadWorkRecorder?) -> [CostUsageStoreDayAggregate]
    {
        var keys = Set<DayModelKey>()
        func addKeys(_ map: [String: [String: some Any]]?) {
            for (day, models) in map ?? [:] {
                for model in models.keys {
                    keys.insert(DayModelKey(day: day, model: model))
                }
            }
        }
        addKeys(usage.days)
        addKeys(usage.codexCostNanos)
        addKeys(usage.codexPrioritySurchargeNanos)
        addKeys(usage.codexStandardCostNanos)
        addKeys(usage.codexPriorityCostNanos)
        addKeys(usage.codexStandardTokens)
        addKeys(usage.codexPriorityTokens)
        var values: [DayModelKey: CostUsageStoreDayAggregate] = [:]
        for row in usage.codexRows ?? [] {
            recorder?.recordAggregateGroupingRowVisit()
            let key = DayModelKey(day: row.day, model: row.model)
            keys.insert(key)
            var aggregate = values[key] ?? .zero(day: row.day, model: row.model)
            aggregate.reasoningTokens += Int64(row.reasoning ?? 0)
            aggregate.requestCount += 1
            let isPriority = row.pricingMode == "priority"
            let total = Int64(max(0, row.input) + max(0, row.output))
            if isPriority {
                aggregate.priorityTokens += total
            } else {
                aggregate.standardTokens += total
            }
            if let cost = row.knownCostNanos {
                aggregate.authoritativeCostNanos += cost
            } else if isPriority {
                aggregate.priorityInputTokens += Int64(row.input)
                aggregate.priorityCachedTokens += Int64(row.cached)
                aggregate.priorityOutputTokens += Int64(row.output)
            } else {
                aggregate.standardInputTokens += Int64(row.input)
                aggregate.standardCachedTokens += Int64(row.cached)
                aggregate.standardOutputTokens += Int64(row.output)
            }
            values[key] = aggregate
        }
        return keys.map { key in
            var aggregate = values[key] ?? .zero(day: key.day, model: key.model)
            // Packed totals remain authoritative; rows supply pricing and request detail only.
            let packed = usage.days[key.day]?[key.model] ?? []
            aggregate.inputTokens = Int64(packed[safe: 0] ?? 0)
            aggregate.cachedTokens = Int64(packed[safe: 1] ?? 0)
            aggregate.outputTokens = Int64(packed[safe: 2] ?? 0)
            return aggregate
        }.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    private static func globalAggregates(
        cache: CostUsageCache,
        recorder: CostUsageStoreReadWorkRecorder?) -> [CostUsageStoreDayAggregate]
    {
        var values: [DayModelKey: CostUsageStoreDayAggregate] = [:]
        for (day, models) in cache.days {
            for (model, packed) in models {
                var aggregate = CostUsageStoreDayAggregate.zero(day: day, model: model)
                aggregate.inputTokens = Int64(packed[safe: 0] ?? 0)
                aggregate.cachedTokens = Int64(packed[safe: 1] ?? 0)
                aggregate.outputTokens = Int64(packed[safe: 2] ?? 0)
                values[DayModelKey(day: day, model: model)] = aggregate
            }
        }
        for usage in cache.files.values {
            for aggregate in self.fileAggregates(usage, recorder: recorder) {
                let key = DayModelKey(day: aggregate.day, model: aggregate.model)
                guard var value = values[key] else { continue }
                value.reasoningTokens += aggregate.reasoningTokens
                value.requestCount += aggregate.requestCount
                value.authoritativeCostNanos += aggregate.authoritativeCostNanos
                value.standardInputTokens += aggregate.standardInputTokens
                value.standardCachedTokens += aggregate.standardCachedTokens
                value.standardOutputTokens += aggregate.standardOutputTokens
                value.priorityInputTokens += aggregate.priorityInputTokens
                value.priorityCachedTokens += aggregate.priorityCachedTokens
                value.priorityOutputTokens += aggregate.priorityOutputTokens
                value.standardTokens += aggregate.standardTokens
                value.priorityTokens += aggregate.priorityTokens
                values[key] = value
            }
        }
        return values.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    private static func authoritativeCosts(
        from aggregates: [CostUsageStoreDayAggregate]) -> [String: [String: Int64]]?
    {
        var values: [String: [String: Int64]] = [:]
        for aggregate in aggregates where aggregate.authoritativeCostNanos != 0 {
            values[aggregate.day, default: [:]][aggregate.model] = aggregate.authoritativeCostNanos
        }
        return values.isEmpty ? nil : values
    }

    private static func aggregateRows(
        from aggregates: [CostUsageStoreDayAggregate]) -> [CostUsageScanner.CodexUsageRow]
    {
        aggregates.flatMap { aggregate -> [CostUsageScanner.CodexUsageRow] in
            var rows: [CostUsageScanner.CodexUsageRow] = []
            func append(input: Int64, cached: Int64, output: Int64, mode: String) {
                guard input != 0 || cached != 0 || output != 0 else { return }
                rows.append(CostUsageScanner.CodexUsageRow(
                    day: aggregate.day,
                    model: aggregate.model,
                    turnID: nil,
                    eventIndex: nil,
                    input: Self.int(input),
                    cached: Self.int(cached),
                    output: Self.int(output),
                    pricingModel: aggregate.model,
                    pricingMode: mode))
            }
            append(
                input: aggregate.standardInputTokens,
                cached: aggregate.standardCachedTokens,
                output: aggregate.standardOutputTokens,
                mode: "standard")
            append(
                input: aggregate.priorityInputTokens,
                cached: aggregate.priorityCachedTokens,
                output: aggregate.priorityOutputTokens,
                mode: "priority")
            if aggregate.authoritativeCostNanos != 0 {
                rows.append(CostUsageScanner.CodexUsageRow(
                    day: aggregate.day,
                    model: aggregate.model,
                    turnID: nil,
                    eventIndex: nil,
                    input: 0,
                    cached: 0,
                    output: 0,
                    knownCostNanos: aggregate.authoritativeCostNanos,
                    pricingModel: aggregate.model,
                    pricingMode: "standard"))
            }
            return rows
        }
    }

    private static func modeTokens(
        from aggregates: [CostUsageStoreDayAggregate],
        priority: Bool) -> [String: [String: Int]]?
    {
        var values: [String: [String: Int]] = [:]
        for aggregate in aggregates {
            let count = priority ? aggregate.priorityTokens : aggregate.standardTokens
            guard count > 0 else { continue }
            values[aggregate.day, default: [:]][aggregate.model] = Self.int(count)
        }
        return values.isEmpty ? nil : values
    }

    private static func days(from aggregates: [CostUsageStoreDayAggregate]) -> [String: [String: [Int]]] {
        var values: [String: [String: [Int]]] = [:]
        for aggregate in aggregates {
            values[aggregate.day, default: [:]][aggregate.model] = [
                Self.int(aggregate.inputTokens),
                Self.int(aggregate.cachedTokens),
                Self.int(aggregate.outputTokens),
            ]
        }
        return values
    }
}

// MARK: - Opaque state conversion

extension CostUsageStore {
    private static func discoveryState(_ value: CostUsageCodexSessionDiscovery?) -> CostUsageStoreDiscoveryState? {
        value.map {
            CostUsageStoreDiscoveryState(
                roots: $0.roots,
                generation: $0.generation,
                directoryPaths: $0.directoryPaths,
                nextDirectoryIndex: $0.nextDirectoryIndex,
                filePaths: $0.filePaths,
                nextFileIndex: $0.nextFileIndex,
                filePathBySessionID: $0.filePathBySessionId,
                missingSessionIDs: $0.missingSessionIds,
                pendingSessionIDs: $0.pendingSessionIds,
                validationDirectoryIndex: $0.validationDirectoryIndex,
                isComplete: $0.isComplete,
                payload: try? JSONEncoder().encode($0))
        }
    }

    private static func discovery(from value: CostUsageStoreDiscoveryState) -> CostUsageCodexSessionDiscovery? {
        value.payload.flatMap { try? JSONDecoder().decode(CostUsageCodexSessionDiscovery.self, from: $0) }
    }

    private static func lookbackState(_ value: CostUsageCodexActiveLookbackState?) -> CostUsageStoreLookbackState? {
        value.map {
            CostUsageStoreLookbackState(
                scanSinceDay: $0.scanSinceKey,
                rootPaths: $0.rootPaths,
                nextDayByRoot: $0.nextDayKeyByRoot,
                nextDirectoryOffsetByRoot: $0.nextDirectoryOffsetByRoot,
                completedRootPaths: $0.completedRootPaths,
                pendingFilePaths: $0.pendingFilePaths,
                legacyRecursivePendingRootPaths: $0.legacyRecursivePendingRootPaths,
                currentWindowNextDayKeyByRoot: $0.currentWindowNextDayKeyByRoot,
                currentWindowDirectoryOffsetByRoot: $0.currentWindowDirectoryOffsetByRoot,
                completedCurrentWindowRootPaths: $0.completedCurrentWindowRootPaths,
                currentWindowFlatDirectoryOffsetByRoot: $0.currentWindowFlatDirectoryOffsetByRoot,
                completedCurrentWindowFlatRootPaths: $0.completedCurrentWindowFlatRootPaths,
                cacheWideMigrationQueueActive: $0.cacheWideMigrationQueueActive)
        }
    }

    private static func lookback(from value: CostUsageStoreLookbackState) -> CostUsageCodexActiveLookbackState {
        CostUsageCodexActiveLookbackState(
            scanSinceKey: value.scanSinceDay,
            rootPaths: value.rootPaths,
            nextDayKeyByRoot: value.nextDayByRoot,
            nextDirectoryOffsetByRoot: value.nextDirectoryOffsetByRoot,
            completedRootPaths: value.completedRootPaths,
            pendingFilePaths: value.pendingFilePaths,
            legacyRecursivePendingRootPaths: value.legacyRecursivePendingRootPaths,
            currentWindowNextDayKeyByRoot: value.currentWindowNextDayKeyByRoot,
            currentWindowDirectoryOffsetByRoot: value.currentWindowDirectoryOffsetByRoot,
            completedCurrentWindowRootPaths: value.completedCurrentWindowRootPaths,
            currentWindowFlatDirectoryOffsetByRoot: value.currentWindowFlatDirectoryOffsetByRoot,
            completedCurrentWindowFlatRootPaths: value.completedCurrentWindowFlatRootPaths,
            cacheWideMigrationQueueActive: value.cacheWideMigrationQueueActive)
    }

    private static func tokenSnapshot(
        path: String,
        eventIndex: Int,
        snapshot: CostUsageCodexTokenSnapshot,
        calendar: Calendar) -> CostUsageStoreTokenSnapshot
    {
        let date = CostUsageScanner.dateFromTimestamp(snapshot.timestamp)
        return CostUsageStoreTokenSnapshot(
            path: path,
            eventIndex: eventIndex,
            timestamp: snapshot.timestamp,
            timestampUnixMs: date.map { Int64($0.timeIntervalSince1970 * 1000) },
            day: date.map { CostUsageScanner.CostUsageDayRange.dayKey(from: $0, calendar: calendar) },
            last: Self.totals(snapshot.last),
            total: Self.totals(snapshot.total),
            endOffset: snapshot.endOffset)
    }

    private static func tokenSnapshot(from value: CostUsageStoreTokenSnapshot) -> CostUsageCodexTokenSnapshot {
        CostUsageCodexTokenSnapshot(
            timestamp: value.timestamp,
            last: self.totals(from: value.last),
            total: self.totals(from: value.total),
            endOffset: value.endOffset)
    }

    private func persistBuffers(path: String, usage: CostUsageFileUsage) {
        let pairs: [(CostUsageStoreBufferedLineKind, [CostUsageScanner.CodexBufferedFastLine]?)] = [
            (.subagent, usage.codexBufferedSubagentLines),
            (.unresolvedFork, usage.codexBufferedUnresolvedForkLines),
        ]
        for (kind, source) in pairs {
            let lines = (source ?? []).enumerated().compactMap { index, line -> CostUsageStoreBufferedLine? in
                guard let payload = try? JSONEncoder().encode(line) else { return nil }
                return CostUsageStoreBufferedLine(
                    path: path,
                    kind: kind,
                    lineIndex: index,
                    ordinal: nil,
                    endOffset: nil,
                    payload: payload)
            }
            _ = self.replaceBufferedLines(path: path, kind: kind, lines: lines)
        }
    }

    private static func bufferedLines(
        _ values: [CostUsageStoreBufferedLine],
        kind: CostUsageStoreBufferedLineKind) -> [CostUsageScanner.CodexBufferedFastLine]?
    {
        let lines = values.filter { $0.kind == kind }.compactMap {
            try? JSONDecoder().decode(CostUsageScanner.CodexBufferedFastLine.self, from: $0.payload)
        }
        return lines.isEmpty ? nil : lines
    }

    private func deleteRemovedFiles(
        previous: CodexPersistenceState,
        cache: CostUsageCache)
    {
        for path in previous.files.map(\.path) where cache.files[path] == nil {
            _ = self.deleteFile(path: path)
        }
    }

    private static func inode(from identity: String?) -> Int64? {
        identity?.split(separator: ":").last.flatMap { Int64($0) }
    }

    private static func device(from identity: String?) -> String? {
        identity?.split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    private static func totals(_ value: CostUsageCodexTotals?) -> CostUsageStoreTotals? {
        value.map { CostUsageStoreTotals(
            input: Int64($0.input),
            cached: Int64($0.cached),
            output: Int64($0.output),
            reasoning: $0.reasoning.map(Int64.init)) }
    }

    private static func totals(_ value: CostUsageCodexTotals) -> CostUsageStoreTotals {
        CostUsageStoreTotals(
            input: Int64(value.input),
            cached: Int64(value.cached),
            output: Int64(value.output),
            reasoning: value.reasoning.map(Int64.init))
    }

    private static func totals(from value: CostUsageStoreTotals?) -> CostUsageCodexTotals? {
        value.map { CostUsageCodexTotals(
            input: Self.int($0.input),
            cached: Self.int($0.cached),
            output: Self.int($0.output),
            reasoning: $0.reasoning.map(Self.int)) }
    }

    private static func int(_ value: Int64) -> Int {
        Int(exactly: value) ?? (value < 0 ? Int.min : Int.max)
    }
}

// MARK: - Synchronous scanner bridge

struct CostUsageStoreLoad: @unchecked Sendable {
    var store: CostUsageStore
    var cache: CostUsageCache
    var receipt: CostUsageStore.CodexBaselineReceipt

    func release() {
        self.store.syncReleaseCodexBaseline(self.receipt)
    }
}

enum CostUsageStoreAccess {
    static func readView(
        cacheRoot: URL?,
        calendar: Calendar,
        purpose: CostUsageStoreReadPurpose) -> CostUsageStoreReadView
    {
        CostUsageStore(cacheRoot: cacheRoot).syncLoadCodexReadView(calendar: calendar, purpose: purpose)
    }

    static func load(cacheRoot: URL?, calendar: Calendar) -> CostUsageStoreLoad {
        let store = CostUsageStore(cacheRoot: cacheRoot)
        return store.syncLoadCodexScan(calendar: calendar)
    }

    static func read(cacheRoot: URL?, calendar: Calendar = .current) -> CostUsageCache {
        CostUsageStore(cacheRoot: cacheRoot).syncLoadCodexCache(calendar: calendar)
    }

    /// Test and maintenance mutation seam for metadata-only edits. Scanner writes should keep
    /// using the loaded store instance so one actor owns the full read/scan/write cycle.
    @discardableResult
    static func replace(
        cacheRoot: URL?,
        cache: CostUsageCache,
        calendar: Calendar = .current) -> CostUsageStoreBudgetResult
    {
        let loaded = self.load(cacheRoot: cacheRoot, calendar: calendar)
        defer { loaded.release() }
        let since = cache.scanSinceKey ?? "0000-01-01"
        let until = cache.scanUntilKey ?? "9999-12-31"
        return self.save(
            store: loaded.store,
            cache: cache,
            calendar: calendar,
            requestedScanWindow: (sinceKey: since, untilKey: until),
            receipt: loaded.receipt)
    }

    @discardableResult
    static func save(
        store: CostUsageStore,
        cache: CostUsageCache,
        calendar: Calendar,
        requestedScanWindow: (sinceKey: String, untilKey: String),
        reportWindow: (sinceKey: String, untilKey: String)? = nil,
        skipIdenticalContent: Bool = false,
        receipt: CostUsageStore.CodexBaselineReceipt? = nil) -> CostUsageStoreBudgetResult
    {
        store.syncSaveCodexCache(
            cache,
            calendar: calendar,
            requestedScanWindow: requestedScanWindow,
            reportWindow: reportWindow,
            skipIdenticalContent: skipIdenticalContent,
            receipt: receipt)
    }
}

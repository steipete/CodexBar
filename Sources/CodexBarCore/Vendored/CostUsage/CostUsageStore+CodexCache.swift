import Foundation

extension CostUsageStore {
    static let defaultRowBudget = 25000
    static let defaultFileBudgetBytes: Int64 = 256 * 1024 * 1024

    func loadCodexCache(calendar: Calendar) -> CostUsageCache {
        _ = self.removeLegacyCodexArtifactIfPresent()
        let snapshot = self.readSnapshot()
        guard snapshot.metadata.timeZoneIdentifier == nil
            || snapshot.metadata.timeZoneIdentifier == calendar.timeZone.identifier
        else { return CostUsageCache() }
        return Self.cache(from: snapshot)
    }

    @discardableResult
    func saveCodexCache(
        _ cache: CostUsageCache,
        calendar: Calendar,
        requestedScanWindow: (sinceKey: String, untilKey: String),
        reportWindow: (sinceKey: String, untilKey: String)? = nil,
        rowBudget: Int = CostUsageStore.defaultRowBudget,
        fileBudgetBytes: Int64 = CostUsageStore.defaultFileBudgetBytes) -> CostUsageStoreBudgetResult
    {
        let previous = self.readSnapshot()
        let canReuseStoredRows = previous.metadata.timeZoneIdentifier == calendar.timeZone.identifier
        self.deleteRemovedFiles(previous: previous, cache: cache)
        let previousFilesByPath = Dictionary(uniqueKeysWithValues: previous.files.map { ($0.path, $0) })
        let snapshotCountsByPath = previous.tokenSnapshots
            .reduce(into: [String: Int]()) { $0[$1.path, default: 0] += 1 }
        let rowCountsByPath = previous.usageRows.reduce(into: [String: Int]()) { $0[$1.path, default: 0] += 1 }
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            self.persistFile(
                path: path,
                usage: usage,
                baseline: PersistedFileBaseline(
                    file: previousFilesByPath[path],
                    snapshotCount: snapshotCountsByPath[path] ?? 0,
                    rowCount: rowCountsByPath[path] ?? 0,
                    canReuseRows: canReuseStoredRows),
                calendar: calendar)
        }
        _ = self.replaceDayAggregates(Self.globalAggregates(cache: cache))
        _ = self.setMetadata(Self.metadata(cache: cache, calendar: calendar))
        _ = self.setDiscoveryState(Self.discoveryState(cache.codexSessionDiscovery))
        _ = self.setLookbackState(Self.lookbackState(cache.codexActiveLookbackState))
        let result = self.enforceBudgets(
            maxRows: rowBudget,
            maxFileBytes: fileBudgetBytes,
            requestedSinceDay: requestedScanWindow.sinceKey,
            requestedUntilDay: requestedScanWindow.untilKey,
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

    private static func cache(from snapshot: CostUsageStoreSnapshot) -> CostUsageCache {
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
                codexBufferedUnresolvedForkLines: Self.bufferedLines(buffers, kind: .unresolvedFork))
            cache.files[file.path] = usage
        }
        cache.days = Self.days(from: snapshot.dayAggregates)
        return cache
    }

    private func persistFile(
        path: String,
        usage: CostUsageFileUsage,
        baseline: PersistedFileBaseline,
        calendar: Calendar)
    {
        let snapshots = (usage.codexTokenSnapshots ?? []).enumerated().map {
            Self.tokenSnapshot(path: path, eventIndex: $0.offset, snapshot: $0.element, calendar: calendar)
        }
        let rows = (usage.codexRows ?? []).enumerated().compactMap { index, row -> CostUsageStoreUsageRow? in
            guard let payload = try? JSONEncoder().encode(row) else { return nil }
            return CostUsageStoreUsageRow(path: path, rowIndex: index, payload: payload)
        }
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
        if baseline.canReuseRows, oldParsedBytes == newParsedBytes, baseline.snapshotCount == snapshots.count {
            // Stable cursor: the persisted prefix is already authoritative.
        } else if appendSafe, baseline.snapshotCount <= snapshots.count {
            _ = self.appendTokenSnapshots(Array(snapshots.dropFirst(baseline.snapshotCount)))
        } else {
            _ = self.replaceTokenSnapshots(path: path, snapshots: snapshots)
        }
        if baseline.canReuseRows, oldParsedBytes == newParsedBytes, baseline.rowCount == rows.count {
            // Stable cursor: metadata/aggregate updates do not rewrite historical rows.
        } else if appendSafe, baseline.rowCount <= rows.count {
            _ = self.appendUsageRows(Array(rows.dropFirst(baseline.rowCount)))
        } else {
            _ = self.replaceUsageRows(path: path, rows: rows)
        }
        _ = self.replaceFileDayAggregates(path: path, aggregates: Self.fileAggregates(usage))
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
            eventCount: snapshots.count,
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
        let priority = StoredPriorityState(
            turnKeys: cache.codexPriorityTurnKeys,
            turnIDsByDay: cache.codexPriorityTurnIDsByDay)
        return CostUsageStoreMetadata(
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
            rootMtimes: cache.roots,
            previousReportPayload: cache.codexPreviousReport.flatMap { try? JSONEncoder().encode($0) },
            priorityTurnStatePayload: try? JSONEncoder().encode(priority),
            projectMetadataVersion: cache.codexProjectMetadataVersion)
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
        guard var previous = CostUsageCodexPreviousReport(report: report, cache: cache) else { return nil }
        previous.scanSinceKey = reportWindow?.sinceKey ?? cache.scanSinceKey
        previous.scanUntilKey = reportWindow?.untilKey ?? cache.scanUntilKey
        return previous
    }

    private static func fileAggregates(_ usage: CostUsageFileUsage) -> [CostUsageStoreDayAggregate] {
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
        for row in usage.codexRows ?? [] {
            keys.insert(DayModelKey(day: row.day, model: row.model))
        }
        return keys.map { key in
            let packed = usage.days[key.day]?[key.model] ?? []
            let rows = (usage.codexRows ?? []).filter { $0.day == key.day && $0.model == key.model }
            var aggregate = CostUsageStoreDayAggregate(
                day: key.day,
                model: key.model,
                inputTokens: Int64(packed[safe: 0] ?? 0),
                cachedTokens: Int64(packed[safe: 1] ?? 0),
                outputTokens: Int64(packed[safe: 2] ?? 0),
                reasoningTokens: Int64(rows.compactMap(\.reasoning).reduce(0, +)),
                requestCount: Int64(rows.count),
                authoritativeCostNanos: 0,
                standardInputTokens: 0,
                standardCachedTokens: 0,
                standardOutputTokens: 0,
                priorityInputTokens: 0,
                priorityCachedTokens: 0,
                priorityOutputTokens: 0,
                standardTokens: 0,
                priorityTokens: 0)
            for row in rows {
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
            }
            return aggregate
        }.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    private static func globalAggregates(cache: CostUsageCache) -> [CostUsageStoreDayAggregate] {
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
            for aggregate in self.fileAggregates(usage) {
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
                completedRootPaths: $0.completedRootPaths,
                pendingFilePaths: $0.pendingFilePaths,
                legacyRecursivePendingRootPaths: $0.legacyRecursivePendingRootPaths)
        }
    }

    private static func lookback(from value: CostUsageStoreLookbackState) -> CostUsageCodexActiveLookbackState {
        CostUsageCodexActiveLookbackState(
            scanSinceKey: value.scanSinceDay,
            rootPaths: value.rootPaths,
            nextDayKeyByRoot: value.nextDayByRoot,
            completedRootPaths: value.completedRootPaths,
            pendingFilePaths: value.pendingFilePaths,
            legacyRecursivePendingRootPaths: value.legacyRecursivePendingRootPaths)
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
        previous: CostUsageStoreSnapshot,
        cache: CostUsageCache)
    {
        for path in previous.files.map(\.path) where cache.files[path] == nil {
            _ = self.deleteFile(path: path)
        }
    }

    private static func inode(from identity: String?) -> Int64? {
        identity?.split(separator: ":").last.flatMap { Int64($0) }
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
}

enum CostUsageStoreAccess {
    static func load(cacheRoot: URL?, calendar: Calendar) -> CostUsageStoreLoad {
        let store = CostUsageStore(cacheRoot: cacheRoot)
        let cache = store.syncLoadCodexCache(calendar: calendar)
        return CostUsageStoreLoad(store: store, cache: cache)
    }

    static func read(cacheRoot: URL?, calendar: Calendar = .current) -> CostUsageCache {
        self.load(cacheRoot: cacheRoot, calendar: calendar).cache
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
        let since = cache.scanSinceKey ?? "0000-01-01"
        let until = cache.scanUntilKey ?? "9999-12-31"
        return self.save(
            store: loaded.store,
            cache: cache,
            calendar: calendar,
            requestedScanWindow: (sinceKey: since, untilKey: until))
    }

    @discardableResult
    static func save(
        store: CostUsageStore,
        cache: CostUsageCache,
        calendar: Calendar,
        requestedScanWindow: (sinceKey: String, untilKey: String),
        reportWindow: (sinceKey: String, untilKey: String)? = nil) -> CostUsageStoreBudgetResult
    {
        store.syncSaveCodexCache(
            cache,
            calendar: calendar,
            requestedScanWindow: requestedScanWindow,
            reportWindow: reportWindow)
    }
}

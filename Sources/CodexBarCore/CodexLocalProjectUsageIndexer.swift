import Foundation

enum CodexLocalProjectUsageIndexer {
    enum IndexError: Error, Equatable {
        case cacheScopeMismatch
    }

    struct Options: Sendable {
        var scannerOptions: CostUsageScanner.Options

        init(scannerOptions: CostUsageScanner.Options = CostUsageScanner.Options()) {
            self.scannerOptions = scannerOptions
        }
    }

    static func cachedSnapshot(
        now: Date = Date(),
        historyDays: Int = 30,
        options: Options = Options()) -> CodexLocalProjectUsageSnapshot?
    {
        _ = now
        let clampedHistoryDays = max(1, min(365, historyDays))
        let stableScopeSignature = self.stableScopeSignature(options: options.scannerOptions)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: options.scannerOptions.cacheRoot)
        let catalogResult = CodexThreadCatalogReader.loadResult(options: options.scannerOptions)
        let sourceStatus = CodexLocalProjectUsageSourceStatus(catalog: catalogResult.completeness)
        if let snapshot = sidecar.loadLatestSnapshot(
            scopeSignature: stableScopeSignature,
            historyDays: clampedHistoryDays,
            catalog: catalogResult.isComplete ? catalogResult.catalog : nil)
        {
            return self.projecting(snapshot, sourceStatus: sourceStatus)
        }
        return nil
    }

    static func loadSnapshot(
        now: Date = Date(),
        historyDays: Int = 30,
        forceRefresh: Bool = false,
        options: Options = Options(),
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CodexLocalProjectUsageSnapshot
    {
        let refreshSignpost = CodexModelsTelemetry.begin("IndexRefresh")
        defer { CodexModelsTelemetry.end("IndexRefresh", id: refreshSignpost) }
        let clampedHistoryDays = max(1, min(365, historyDays))
        let until = now
        var scannerOptions = options.scannerOptions
        if forceRefresh {
            scannerOptions.refreshMinIntervalSeconds = 0
        }
        let since = scannerOptions.calendar.date(
            byAdding: .day,
            value: -(clampedHistoryDays - 1),
            to: now) ?? now
        let comparisonSince = self.modelsAnalyticsScanStart(
            since: since,
            until: until,
            calendar: scannerOptions.calendar)

        progress?(CodexLocalProjectUsageIndexProgress(phase: .scanningLogs))
        _ = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: comparisonSince,
            until: until,
            now: now,
            options: scannerOptions,
            checkCancellation: checkCancellation)
        try checkCancellation?()

        var cache = CostUsageStoreAccess.read(
            cacheRoot: scannerOptions.cacheRoot,
            calendar: scannerOptions.calendar)
        let modelsDevLoad = ModelsDevCache.load(now: now, cacheRoot: scannerOptions.cacheRoot)
        cache.codexPricingKey = CostUsageScanner.codexPricingKey(modelsDevArtifact: modelsDevLoad.artifact)
        let catalogResult = CodexThreadCatalogReader.loadResult(options: scannerOptions)
        let catalog = catalogResult.catalog
        let sourceStatus = CodexLocalProjectUsageSourceStatus(catalog: catalogResult.completeness)
        let rootsFingerprint = self.rootsFingerprint(CostUsageScanner.codexRootsFingerprint(options: scannerOptions))
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: scannerOptions.cacheRoot)
        if !forceRefresh {
            if let snapshot = sidecar.loadLatestSnapshot(
                scopeSignature: self.stableScopeSignature(options: scannerOptions),
                historyDays: clampedHistoryDays,
                rootsFingerprint: rootsFingerprint,
                cache: cache,
                catalog: catalogResult.isComplete ? catalog : nil)
            {
                CodexModelsTelemetry.cacheHit(historyDays: clampedHistoryDays)
                return self.projecting(snapshot, sourceStatus: sourceStatus)
            }
        }

        // Import only scanner-derived deltas, then aggregate from the
        // sidecar's normalized rows. The raw cache remains the cursor and
        // cumulative-token authority; it is no longer the aggregation source.
        try sidecar.synchronizeSources(
            cache: cache,
            catalog: catalog,
            catalogIsComplete: catalogResult.isComplete)
        var sidecarCache = try sidecar.usageCache(roots: rootsFingerprint)
        sidecarCache.codexPricingKey = cache.codexPricingKey
        let snapshot = try self.buildSnapshotFromCostCache(
            now: now,
            historyDays: clampedHistoryDays,
            since: since,
            until: until,
            options: scannerOptions,
            cacheOverride: sidecarCache,
            modelsDevCatalogOverride: modelsDevLoad.artifact?.catalog,
            catalogOverride: catalog,
            sourceStatus: sourceStatus,
            progress: progress,
            checkCancellation: checkCancellation)
        progress?(CodexLocalProjectUsageIndexProgress(phase: .saving))
        try sidecar.synchronize(
            snapshot: snapshot,
            cache: cache,
            catalog: catalog,
            catalogIsComplete: catalogResult.isComplete,
            rootsFingerprint: rootsFingerprint)
        return snapshot
    }

    private static func projecting(
        _ snapshot: CodexLocalProjectUsageSnapshot,
        sourceStatus: CodexLocalProjectUsageSourceStatus) -> CodexLocalProjectUsageSnapshot
    {
        guard snapshot.sourceStatus != sourceStatus else { return snapshot }
        return CodexLocalProjectUsageSnapshot(
            updatedAt: snapshot.updatedAt,
            historyDays: snapshot.historyDays,
            scopeSignature: snapshot.scopeSignature,
            rootsFingerprint: snapshot.rootsFingerprint,
            indexedFileCount: snapshot.indexedFileCount,
            skippedFileCount: snapshot.skippedFileCount,
            total: snapshot.total,
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            modelBreakdowns: snapshot.modelBreakdowns,
            daily: snapshot.daily,
            sourceStatus: sourceStatus,
            modelsAnalytics: snapshot.modelsAnalytics)
    }

    static func buildSnapshotFromCostCache(
        now: Date = Date(),
        historyDays: Int = 30,
        since: Date,
        until: Date,
        options: CostUsageScanner.Options = CostUsageScanner.Options(),
        cacheOverride: CostUsageCache? = nil,
        modelsDevCatalogOverride: ModelsDevCatalog? = nil,
        catalogOverride: CodexThreadCatalog? = nil,
        sourceStatus: CodexLocalProjectUsageSourceStatus = .complete,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CodexLocalProjectUsageSnapshot
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let range = CostUsageScanner.CostUsageDayRange(
            since: since,
            until: until,
            calendar: options.calendar)
        let cache = cacheOverride ?? CostUsageStoreAccess.read(
            cacheRoot: options.cacheRoot,
            calendar: options.calendar)
        let catalog = catalogOverride ?? CodexThreadCatalogReader.load(options: options)
        let pricing = PricingContext(
            modelsDevCatalog: modelsDevCatalogOverride
                ?? CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot),
            cacheRoot: options.cacheRoot)
        let expectedRoots = CostUsageScanner.codexRootsFingerprint(options: options)
        let scopeSignature = self.stableScopeSignature(options: options)
        let rootsFingerprint = self.rootsFingerprint(expectedRoots)

        guard cache.roots == expectedRoots else {
            // The cost cache belongs to a different Codex home. Publishing an
            // empty replacement would erase a still-valid last-complete view.
            throw IndexError.cacheScopeMismatch
        }

        let indexed = try self.sessionBuckets(
            from: cache,
            range: range,
            context: SessionBucketContext(catalog: catalog, pricing: pricing),
            progress: progress,
            checkCancellation: checkCancellation)
        let indexedFiles = indexed.indexedFiles
        let skippedFiles = indexed.skippedFiles
        let sessionBuckets = indexed.sessionBuckets

        let sessions = sessionBuckets.values.map { bucket in
            CodexLocalSessionUsage(
                id: bucket.id,
                projectId: bucket.projectId,
                displayTitle: self.sessionTitle(
                    explicitTitle: bucket.title,
                    startedAt: bucket.startedAt,
                    latestActivity: bucket.latestActivity,
                    model: bucket.topModel),
                cwd: bucket.cwd,
                startedAt: bucket.startedAt,
                latestActivity: bucket.latestActivity,
                totals: bucket.total,
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: bucket.costNanos) ?? 0,
                    unknownTokens: bucket.unknownCostTokens),
                topModel: bucket.displayModel,
                daily: self.dailyPoints(from: bucket.dailyTotals))
        }.sorted { lhs, rhs in
            self.sortSessions(lhs, rhs)
        }

        let projectBuckets = Dictionary(grouping: sessionBuckets.values, by: \.projectId)
        let rawProjects = projectBuckets.values.map { buckets in
            let sortedSessions = buckets.map { bucket in
                CodexLocalSessionUsage(
                    id: bucket.id,
                    projectId: bucket.projectId,
                    displayTitle: self.sessionTitle(
                        explicitTitle: bucket.title,
                        startedAt: bucket.startedAt,
                        latestActivity: bucket.latestActivity,
                        model: bucket.topModel),
                    cwd: bucket.cwd,
                    startedAt: bucket.startedAt,
                    latestActivity: bucket.latestActivity,
                    totals: bucket.total,
                    costEstimate: CodexLocalCostEstimate(
                        knownUSD: self.usd(fromNanos: bucket.costNanos) ?? 0,
                        unknownTokens: bucket.unknownCostTokens),
                    topModel: bucket.displayModel,
                    daily: self.dailyPoints(from: bucket.dailyTotals))
            }.sorted { lhs, rhs in
                self.sortSessions(lhs, rhs)
            }
            var total = CodexLocalUsageTotals.empty
            var costNanos: Int64?
            var unknownCostTokens = 0
            var latestActivity: Date?
            var modelTotals: [String: ModelTotals] = [:]
            var dailyTotals: [String: DailyTotals] = [:]
            for bucket in buckets {
                total = total.adding(bucket.total)
                costNanos = self.addCost(costNanos, bucket.costNanos)
                unknownCostTokens += bucket.unknownCostTokens
                latestActivity = self.later(latestActivity, bucket.latestActivity)
                for (day, daily) in bucket.dailyTotals {
                    self.mergeDailyTotals(&dailyTotals, day: day, totals: daily)
                }
                for (model, totals) in bucket.modelTotals {
                    self.mergeModelTotals(&modelTotals, model: model, totals: totals)
                }
            }
            let first = buckets[0]
            return CodexLocalProjectUsage(
                id: first.projectId,
                displayName: first.projectDisplayName,
                path: first.projectPath,
                totals: total,
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: costNanos) ?? 0,
                    unknownTokens: unknownCostTokens),
                sessionCount: buckets.count,
                latestActivity: latestActivity,
                topModel: self.topModel(from: modelTotals),
                topSessions: Array(sortedSessions.prefix(5)),
                modelBreakdowns: self.modelBreakdowns(from: modelTotals),
                daily: self.dailyPoints(from: dailyTotals))
        }.sorted { lhs, rhs in
            self.sortProjects(lhs, rhs)
        }
        let projects = rawProjects

        var globalDailyTotals: [String: DailyTotals] = [:]
        for bucket in sessionBuckets.values {
            for (day, totals) in bucket.dailyTotals {
                self.mergeDailyTotals(&globalDailyTotals, day: day, totals: totals)
            }
        }

        return try CodexLocalProjectUsageSnapshot(
            updatedAt: now,
            historyDays: clampedHistoryDays,
            scopeSignature: scopeSignature,
            rootsFingerprint: rootsFingerprint,
            indexedFileCount: indexedFiles,
            skippedFileCount: skippedFiles,
            total: self.total(from: projects),
            projects: projects,
            sessions: sessions,
            modelBreakdowns: self.globalModelBreakdowns(from: sessionBuckets.values),
            daily: self.dailyPoints(from: globalDailyTotals),
            sourceStatus: sourceStatus,
            modelsAnalytics: self.modelsAnalyticsPayload(
                context: ModelsAnalyticsContext(
                    currentBuckets: sessionBuckets,
                    cache: cache,
                    catalog: catalog,
                    projects: projects,
                    sourceStatus: sourceStatus,
                    pricing: pricing),
                window: ModelsAnalyticsWindow(
                    since: since,
                    until: until,
                    historyDays: clampedHistoryDays,
                    generatedAt: now,
                    calendar: options.calendar),
                identity: ModelsAnalyticsIdentity(
                    scopeSignature: scopeSignature,
                    rootsFingerprint: rootsFingerprint),
                checkCancellation: checkCancellation))
    }
}

extension CodexLocalProjectUsageIndexer {
    fileprivate struct PricingContext {
        let modelsDevCatalog: ModelsDevCatalog?
        let cacheRoot: URL?
    }

    fileprivate struct SessionBucketContext {
        let catalog: CodexThreadCatalog
        let pricing: PricingContext
    }

    fileprivate struct ModelsAnalyticsContext {
        let currentBuckets: [String: SessionBucket]
        let cache: CostUsageCache
        let catalog: CodexThreadCatalog
        let projects: [CodexLocalProjectUsage]
        let sourceStatus: CodexLocalProjectUsageSourceStatus
        let pricing: PricingContext
    }

    fileprivate struct ModelsAnalyticsWindow {
        let since: Date
        let until: Date
        let historyDays: Int
        let generatedAt: Date
        let calendar: Calendar
    }

    fileprivate struct ModelsAnalyticsIdentity {
        let scopeSignature: String
        let rootsFingerprint: [String: Int64]
    }

    fileprivate struct FileTotals {
        var totals: CodexLocalUsageTotals
        var costNanos: Int64?
        var unknownCostTokens: Int
        var modelTotals: [String: ModelTotals]
        var dailyTotals: [String: DailyTotals]
        var modelDailyTotals: [String: [String: ModelDailyTotals]]
        var topModel: String?
    }

    fileprivate struct DailyTotals {
        var totalTokens: Int
        var cachedInputTokens: Int
        var costNanos: Int64?
        var unknownCostTokens: Int
    }

    fileprivate struct ModelTotals {
        var totalTokens: Int
        var costNanos: Int64?
        var unknownCostTokens: Int
    }

    fileprivate struct ModelDailyTotals {
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var costNanos: Int64?
        var unknownCostTokens: Int
    }

    fileprivate struct ReadTimePricingTotals {
        var costNanos: Int64?
        var coveredTokens = 0
        var unknownCostTokens = 0
        var hasAuthoritativeCost = false
    }

    fileprivate struct SessionBucket {
        var id: String
        var projectId: String
        var projectDisplayName: String
        var projectPath: String?
        var cwd: String?
        var title: String?
        var startedAt: Date?
        var latestActivity: Date?
        var catalogModel: String?
        var modelTotals: [String: ModelTotals]
        var dailyTotals: [String: DailyTotals]
        var modelDailyTotals: [String: [String: ModelDailyTotals]]
        var usageRows: [CostUsageScanner.CodexUsageRow]
        var hasCompleteEventRows: Bool
        var total: CodexLocalUsageTotals
        var costNanos: Int64?
        var unknownCostTokens: Int

        var topModel: String? {
            CodexLocalProjectUsageIndexer.topModel(from: self.modelTotals)
        }

        var displayModel: String? {
            self.catalogModel ?? self.topModel
        }
    }

    fileprivate struct Metadata {
        var sessionId: String?
        var cwd: String?
        var title: String?
        var startedAt: Date?
        var latestActivity: Date?
    }

    fileprivate struct BucketMergeInput {
        var sessionId: String
        var projectIdentity: CodexLocalProjectRootResolver.ProjectIdentity
        var metadata: Metadata
        var started: Date?
        var latest: Date?
        var catalogModel: String?
        var model: String?
        var fileTotals: FileTotals
        var usageRows: [CostUsageScanner.CodexUsageRow]
        var hasCompleteEventRows: Bool
    }

    fileprivate static func sessionBuckets(
        from cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        context: SessionBucketContext,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)?,
        checkCancellation: CostUsageScanner.CancellationCheck?)
        throws -> (sessionBuckets: [String: SessionBucket], indexedFiles: Int, skippedFiles: Int)
    {
        var indexedFiles = 0
        var skippedFiles = 0
        var sessionBuckets: [String: SessionBucket] = [:]
        let files = cache.files.sorted(by: { $0.key < $1.key }).filter {
            $0.value.touchesCodexScanWindow(sinceKey: range.sinceKey, untilKey: range.untilKey)
        }
        progress?(CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 0,
            totalFileCount: files.count))

        for (offset, entry) in files.enumerated() {
            try checkCancellation?()
            let path = entry.key
            let usage = entry.value
            guard let fileTotals = self.fileTotals(from: usage, range: range, pricing: context.pricing) else {
                skippedFiles += 1
                self.reportProgressIfNeeded(
                    progress,
                    processedFiles: offset + 1,
                    totalFiles: files.count,
                    indexedFiles: indexedFiles,
                    skippedFiles: skippedFiles)
                continue
            }
            indexedFiles += 1
            let fileURL = URL(fileURLWithPath: path)
            let cachedMetadata = self.metadata(from: usage, catalogEntry: nil)
            let catalogEntry = context.catalog.entry(
                sessionId: cachedMetadata.sessionId ?? usage.sessionId,
                rolloutPath: path)
            let metadata = self.metadata(from: usage, catalogEntry: catalogEntry)
            let sessionId = metadata.sessionId ?? usage.sessionId ?? fileURL.deletingPathExtension().lastPathComponent
            let projectIdentity = CodexLocalProjectRootResolver.projectIdentity(for: metadata.cwd)
            let latest = metadata.latestActivity ?? self.latestDate(from: usage.days.keys)
            let started = metadata.startedAt ?? self.earliestDate(from: usage.days.keys)
            let model = catalogEntry?.model ?? usage.lastModel ?? fileTotals.topModel
            sessionBuckets[sessionId] = self.mergedBucket(
                sessionBuckets[sessionId],
                input: BucketMergeInput(
                    sessionId: sessionId,
                    projectIdentity: projectIdentity,
                    metadata: metadata,
                    started: started,
                    latest: latest,
                    catalogModel: catalogEntry?.model,
                    model: model,
                    fileTotals: fileTotals,
                    usageRows: (usage.codexRows ?? []).filter {
                        CostUsageScanner.CostUsageDayRange.isInRange(
                            dayKey: $0.day,
                            since: range.sinceKey,
                            until: range.untilKey)
                    },
                    hasCompleteEventRows: usage.days.isEmpty || !(usage.codexRows?.isEmpty ?? true)
                        &&
                        (usage.codexRows?
                            .allSatisfy { $0.eventIndex != nil && $0.timestampUnixMs != nil } ?? false)))
            self.reportProgressIfNeeded(
                progress,
                processedFiles: offset + 1,
                totalFiles: files.count,
                indexedFiles: indexedFiles,
                skippedFiles: skippedFiles)
        }

        return (sessionBuckets, indexedFiles, skippedFiles)
    }

    fileprivate static func reportProgressIfNeeded(
        _ progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)?,
        processedFiles: Int,
        totalFiles: Int,
        indexedFiles: Int,
        skippedFiles: Int)
    {
        guard processedFiles == 1 || processedFiles == totalFiles || processedFiles.isMultiple(of: 25) else {
            return
        }
        progress?(CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: processedFiles,
            totalFileCount: totalFiles,
            indexedFileCount: indexedFiles,
            skippedFileCount: skippedFiles))
    }

    fileprivate static func mergedBucket(
        _ current: SessionBucket?,
        input: BucketMergeInput) -> SessionBucket
    {
        var bucket = current ?? SessionBucket(
            id: input.sessionId,
            projectId: input.projectIdentity.id,
            projectDisplayName: input.projectIdentity.displayName,
            projectPath: input.projectIdentity.path,
            cwd: input.metadata.cwd,
            title: input.metadata.title,
            startedAt: input.started,
            latestActivity: input.latest,
            catalogModel: input.catalogModel,
            modelTotals: [:],
            dailyTotals: [:],
            modelDailyTotals: [:],
            usageRows: [],
            hasCompleteEventRows: true,
            total: .empty,
            costNanos: nil,
            unknownCostTokens: 0)
        if self.shouldUseProjectIdentity(input.projectIdentity, over: bucket, latestActivity: input.latest) {
            bucket.projectId = input.projectIdentity.id
            bucket.projectDisplayName = input.projectIdentity.displayName
            bucket.projectPath = input.projectIdentity.path
        }
        bucket.cwd = bucket.cwd ?? input.metadata.cwd
        bucket.title = input.metadata.title ?? bucket.title
        bucket.catalogModel = input.catalogModel ?? bucket.catalogModel
        bucket.startedAt = self.earlier(bucket.startedAt, input.started)
        bucket.latestActivity = self.later(bucket.latestActivity, input.latest)
        bucket.total = bucket.total.adding(input.fileTotals.totals)
        bucket.usageRows.append(contentsOf: input.usageRows)
        bucket.hasCompleteEventRows = bucket.hasCompleteEventRows && input.hasCompleteEventRows
        bucket.costNanos = self.addCost(bucket.costNanos, input.fileTotals.costNanos)
        bucket.unknownCostTokens += input.fileTotals.unknownCostTokens
        for (modelName, totals) in input.fileTotals.modelTotals {
            self.mergeModelTotals(&bucket.modelTotals, model: modelName, totals: totals)
        }
        for (day, totals) in input.fileTotals.dailyTotals {
            self.mergeDailyTotals(&bucket.dailyTotals, day: day, totals: totals)
        }
        for (day, models) in input.fileTotals.modelDailyTotals {
            for (model, totals) in models {
                self.mergeModelDailyTotals(&bucket.modelDailyTotals, day: day, model: model, totals: totals)
            }
        }
        if let model = input.model, !model.isEmpty, bucket.modelTotals[model] == nil {
            bucket.modelTotals[model] = ModelTotals(totalTokens: 0, costNanos: nil, unknownCostTokens: 0)
        }
        return bucket
    }

    fileprivate static func shouldUseProjectIdentity(
        _ identity: CodexLocalProjectRootResolver.ProjectIdentity,
        over bucket: SessionBucket,
        latestActivity: Date?) -> Bool
    {
        guard identity.id != CodexLocalProjectRootResolver.chatsProjectId else {
            return bucket.projectId == CodexLocalProjectRootResolver.chatsProjectId
        }
        guard bucket.projectId != CodexLocalProjectRootResolver.chatsProjectId else {
            return true
        }
        let currentLatest = bucket.latestActivity ?? .distantPast
        let incomingLatest = latestActivity ?? .distantPast
        return incomingLatest >= currentLatest
    }

    fileprivate static func fileTotals(
        from usage: CostUsageFileUsage,
        range: CostUsageScanner.CostUsageDayRange,
        pricing: PricingContext) -> FileTotals?
    {
        var input = 0
        var cached = 0
        var output = 0
        var costNanos: Int64?
        var unknownCostTokens = 0
        var modelTotals: [String: ModelTotals] = [:]
        var dailyTotals: [String: DailyTotals] = [:]
        var modelDailyTotals: [String: [String: ModelDailyTotals]] = [:]
        let pricingTotals = self.readTimePricingTotals(from: usage, range: range, pricing: pricing)

        for (day, models) in usage.days where CostUsageScanner.CostUsageDayRange
            .isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
        {
            for (model, values) in models {
                let modelInput = max(0, values[safe: 0] ?? 0)
                let modelCached = max(0, values[safe: 1] ?? 0)
                let modelOutput = max(0, values[safe: 2] ?? 0)
                let modelTotal = modelInput + modelOutput
                guard modelTotal > 0 else { continue }
                input += modelInput
                cached += min(modelCached, modelInput)
                output += modelOutput
                let resolved = pricingTotals[day]?[model]
                let modelCostNanos = resolved?.costNanos
                let uncoveredTokens = max(0, modelTotal - min(modelTotal, resolved?.coveredTokens ?? 0))
                let modelUnknownCostTokens = (resolved?.unknownCostTokens ?? 0)
                    + (resolved?.hasAuthoritativeCost == true ? 0 : uncoveredTokens)
                self.addModelTotals(
                    &modelTotals,
                    model: model,
                    tokens: modelTotal,
                    costNanos: modelCostNanos,
                    unknownCostTokens: modelUnknownCostTokens)
                costNanos = self.addCost(costNanos, modelCostNanos)
                unknownCostTokens += modelUnknownCostTokens
                self.addDailyTotals(
                    &dailyTotals,
                    day: day,
                    totals: DailyTotals(
                        totalTokens: modelTotal,
                        cachedInputTokens: min(modelCached, modelInput),
                        costNanos: modelCostNanos,
                        unknownCostTokens: modelUnknownCostTokens))
                self.mergeModelDailyTotals(
                    &modelDailyTotals,
                    day: day,
                    model: model,
                    totals: ModelDailyTotals(
                        inputTokens: modelInput,
                        cachedInputTokens: min(modelCached, modelInput),
                        outputTokens: modelOutput,
                        costNanos: modelCostNanos,
                        unknownCostTokens: modelUnknownCostTokens))
            }
        }

        guard input + output > 0 else { return nil }
        return FileTotals(
            totals: CodexLocalUsageTotals(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: nil,
                totalTokens: input + output),
            costNanos: costNanos,
            unknownCostTokens: unknownCostTokens,
            modelTotals: modelTotals,
            dailyTotals: dailyTotals,
            modelDailyTotals: modelDailyTotals,
            topModel: self.topModel(from: modelTotals))
    }

    fileprivate static func readTimePricingTotals(
        from usage: CostUsageFileUsage,
        range: CostUsageScanner.CostUsageDayRange,
        pricing: PricingContext) -> [String: [String: ReadTimePricingTotals]]
    {
        var totals: [String: [String: ReadTimePricingTotals]] = [:]
        for row in CostUsageScanner.codexRowsForReadTimePricing(usage) where CostUsageScanner.CostUsageDayRange
            .isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
        {
            let tokenCount = max(0, row.input) + max(0, row.output)
            var value = totals[row.day]?[row.model] ?? ReadTimePricingTotals()
            value.coveredTokens += tokenCount
            value.hasAuthoritativeCost = value.hasAuthoritativeCost || row.knownCostNanos != nil
            let resolvedCost = CostUsageScanner.codexResolvedCostNanos(
                for: row,
                modelsDevCatalog: pricing.modelsDevCatalog,
                modelsDevCacheRoot: pricing.cacheRoot)
            if let resolvedCost {
                value.costNanos = self.addCost(value.costNanos, resolvedCost)
            } else {
                value.unknownCostTokens += tokenCount
            }
            totals[row.day, default: [:]][row.model] = value
        }
        return totals
    }

    static func modelsAnalyticsPeriods(
        since: Date,
        until: Date,
        calendar: Calendar = .current) -> CodexModelsAnalyticsPeriods
    {
        let currentStart = calendar.startOfDay(for: since)
        let currentEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until)) ?? until
        let current = DateInterval(start: currentStart, end: currentEnd)
        let previousEnd = current.start
        let previousStart = previousEnd.addingTimeInterval(-current.duration)
        return CodexModelsAnalyticsPeriods(
            current: current,
            previous: DateInterval(start: previousStart, end: previousEnd))
    }

    static func modelsAnalyticsScanStart(
        since: Date,
        until: Date,
        calendar: Calendar = .current) -> Date
    {
        let periods = self.modelsAnalyticsPeriods(since: since, until: until, calendar: calendar)
        return calendar.startOfDay(for: periods.previous.start)
    }

    fileprivate static func modelsAnalyticsPayload(
        context: ModelsAnalyticsContext,
        window: ModelsAnalyticsWindow,
        identity: ModelsAnalyticsIdentity,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> CodexModelsAnalyticsPayload
    {
        let aggregationSignpost = CodexModelsTelemetry.begin("SnapshotAggregation")
        defer { CodexModelsTelemetry.end("SnapshotAggregation", id: aggregationSignpost) }
        let periods = self.modelsAnalyticsPeriods(
            since: window.since,
            until: window.until,
            calendar: window.calendar)
        let previousInterval = periods.previous
        let previousRange = CostUsageScanner.CostUsageDayRange(
            since: previousInterval.start,
            until: previousInterval.end.addingTimeInterval(-1),
            calendar: window.calendar)
        let previousBuckets = try self.sessionBuckets(
            from: context.cache,
            range: previousRange,
            context: SessionBucketContext(catalog: context.catalog, pricing: context.pricing),
            progress: nil,
            checkCancellation: checkCancellation).sessionBuckets
        let currentFragments = self.analyticsFragments(
            from: context.currentBuckets.values,
            calendar: window.calendar,
            pricing: context.pricing)
        let previousFragments = self.analyticsFragments(
            from: previousBuckets.values,
            calendar: window.calendar,
            pricing: context.pricing)
        let currentBucketsByProject = Dictionary(grouping: context.currentBuckets.values, by: \.projectId)
        let previousBucketsByProject = Dictionary(grouping: previousBuckets.values, by: \.projectId)
        let currentFragmentsByProject = Dictionary(grouping: currentFragments, by: \.workspaceID)
        let previousFragmentsByProject = Dictionary(grouping: previousFragments, by: \.workspaceID)
        let revisionParts = identity.rootsFingerprint.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let indexRevision = ([
            identity.scopeSignature,
            CostUsageStore.cacheGeneration,
            context.cache.codexPricingKey ?? "",
        ] + revisionParts)
            .joined(separator: "|")
        let builder = CodexModelsAnalyticsBuilder()
        let source = CodexModelsAnalyticsSource(current: currentFragments, previous: previousFragments)
        let revision = CodexModelsAnalyticsRevision(generatedAt: window.generatedAt, indexRevision: indexRevision)
        // Catalog failures can make workspace attribution incomplete, while aggregate-only
        // cache rows cannot prove exact timestamp-boundary coverage. Treat either condition
        // conservatively so an observed partial period is never presented as a full comparison.
        let metadataIsComplete = context.sourceStatus == .complete
        let currentIsComplete = metadataIsComplete
            && context.currentBuckets.values.allSatisfy(\.hasCompleteEventRows)
        let previousIsComplete = metadataIsComplete
            && previousBuckets.values.allSatisfy(\.hasCompleteEventRows)
        let all = builder.build(CodexModelsAnalyticsRequest(
            source: source,
            scopeID: nil,
            periods: periods,
            revision: revision,
            legacy: self.legacyBaseline(
                current: Array(context.currentBuckets.values),
                previous: Array(previousBuckets.values)),
            currentIsComplete: currentIsComplete,
            previousIsComplete: previousIsComplete))

        let workspaces = Dictionary(uniqueKeysWithValues: context.projects.map { project in
            let projectBuckets = currentBucketsByProject[project.id] ?? []
            let previousProjectBuckets = previousBucketsByProject[project.id] ?? []
            let currentProjectIsComplete = metadataIsComplete
                && projectBuckets.allSatisfy(\.hasCompleteEventRows)
            let previousProjectIsComplete = metadataIsComplete
                && previousProjectBuckets.allSatisfy(\.hasCompleteEventRows)
            return (
                project.id,
                builder.build(CodexModelsAnalyticsRequest(
                    source: CodexModelsAnalyticsSource(
                        current: currentFragmentsByProject[project.id] ?? [],
                        previous: previousFragmentsByProject[project.id] ?? []),
                    scopeID: project.id,
                    periods: periods,
                    revision: revision,
                    legacy: self.legacyBaseline(
                        current: Array(projectBuckets),
                        previous: Array(previousProjectBuckets)),
                    currentIsComplete: currentProjectIsComplete,
                    previousIsComplete: previousProjectIsComplete)))
        })
        CodexModelsTelemetry.parity(
            dimensions: all.diagnostics.mismatchDimensions ?? [],
            rowCount: all.rows.count)
        return CodexModelsAnalyticsPayload(allWorkspaces: all, workspaces: workspaces)
    }

    fileprivate static func legacyBaseline(
        current: [SessionBucket],
        previous: [SessionBucket]) -> CodexModelsLegacyBaseline
    {
        struct LegacyModelAggregates {
            var tokens: Int64 = 0
            var costNanos: Int64?
            var unpricedTokens: Int64 = 0
            var sessionIDs: Set<String> = []
        }

        struct LegacyAggregates {
            let tokens: Int64
            let cost: Decimal
            let pricedTokens: Int64
            let unpricedTokens: Int64
            let modelIDs: [String]
            let topModelID: String?
            let sessionReferences: Int
            let models: [CodexModelsLegacyModelBaseline]
        }

        func aggregates(_ buckets: [SessionBucket]) -> LegacyAggregates {
            let tokens = Int64(buckets.reduce(0) { $0 + ($1.total.totalTokens ?? 0) })
            let costNanos = buckets.reduce(Int64.zero) { $0 + ($1.costNanos ?? 0) }
            let unpricedTokens = Int64(buckets.reduce(0) { $0 + $1.unknownCostTokens })
            var models: [String: LegacyModelAggregates] = [:]
            for bucket in buckets {
                for (model, totals) in bucket.modelTotals {
                    guard totals.totalTokens > 0 else { continue }
                    let canonical = CostUsagePricing.normalizeCodexModel(
                        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                    var values = models[canonical, default: LegacyModelAggregates()]
                    values.tokens += Int64(totals.totalTokens)
                    values.costNanos = self.addCost(values.costNanos, totals.costNanos)
                    values.unpricedTokens += Int64(totals.unknownCostTokens)
                    values.sessionIDs.insert(bucket.id)
                    models[canonical] = values
                }
            }
            let modelIDs = models.keys.sorted()
            let topModelID = models.max {
                if $0.value.tokens != $1.value.tokens {
                    return $0.value.tokens < $1.value.tokens
                }
                return $0.key > $1.key
            }?.key
            let modelBaselines = models.sorted { $0.key < $1.key }.map { modelID, values in
                CodexModelsLegacyModelBaseline(
                    modelID: modelID,
                    totalTokens: values.tokens,
                    knownCost: values.costNanos.map { Decimal($0) / 1_000_000_000 },
                    pricedTokens: max(0, values.tokens - values.unpricedTokens),
                    unpricedTokens: values.unpricedTokens,
                    sessionReferences: values.sessionIDs.count)
            }
            return LegacyAggregates(
                tokens: tokens,
                cost: Decimal(costNanos) / 1_000_000_000,
                pricedTokens: max(0, tokens - unpricedTokens),
                unpricedTokens: unpricedTokens,
                modelIDs: modelIDs,
                topModelID: topModelID,
                sessionReferences: models.values.reduce(0) { $0 + $1.sessionIDs.count },
                models: modelBaselines)
        }

        let currentValues = aggregates(current)
        let previousValues = aggregates(previous)
        return CodexModelsLegacyBaseline(
            totalTokens: currentValues.tokens,
            modelIDs: currentValues.modelIDs,
            knownCost: currentValues.cost,
            pricedTokens: currentValues.pricedTokens,
            unpricedTokens: currentValues.unpricedTokens,
            activeModelCount: currentValues.modelIDs.count,
            topModelID: currentValues.topModelID,
            sessionReferenceTotal: currentValues.sessionReferences,
            previousTotalTokens: previousValues.tokens,
            previousKnownCost: previousValues.cost,
            previousUnpricedTokens: previousValues.unpricedTokens,
            previousSessionReferenceTotal: previousValues.sessionReferences,
            currentModels: currentValues.models,
            previousModels: previousValues.models)
    }

    fileprivate static func analyticsFragments(
        from buckets: Dictionary<String, SessionBucket>.Values,
        calendar: Calendar,
        pricing: PricingContext) -> [CodexModelsUsageFragment]
    {
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        return buckets.flatMap { bucket in
            if bucket.hasCompleteEventRows, !bucket.usageRows.isEmpty {
                return bucket.usageRows.compactMap { row -> CodexModelsUsageFragment? in
                    guard let timestampUnixMs = row.timestampUnixMs else { return nil }
                    let timestamp = Date(timeIntervalSince1970: Double(timestampUnixMs) / 1000)
                    let day = calendar.startOfDay(for: timestamp)
                    let inputTokens = max(0, row.input)
                    let outputTokens = max(0, row.output)
                    let totalTokens = Int64(inputTokens + outputTokens)
                    let costNanos = CostUsageScanner.codexResolvedCostNanos(
                        for: row,
                        modelsDevCatalog: pricing.modelsDevCatalog,
                        modelsDevCacheRoot: pricing.cacheRoot)
                    return CodexModelsUsageFragment(
                        workspaceID: bucket.projectId,
                        sessionID: bucket.id,
                        day: day,
                        timestamp: timestamp,
                        rawModelID: row.rawModel ?? row.model,
                        inputTokens: Int64(inputTokens),
                        cachedInputTokens: Int64(max(0, row.cached)),
                        outputTokens: Int64(outputTokens),
                        reasoningTokens: row.reasoning.map(Int64.init),
                        costNanos: costNanos,
                        unpricedTokens: costNanos == nil ? totalTokens : 0)
                }
            }
            return bucket.modelDailyTotals.flatMap { day, models -> [CodexModelsUsageFragment] in
                guard let parsedDate = CostUsageScanner.parseDayKey(day, calendar: calendar) else { return [] }
                let date = calendar.startOfDay(for: parsedDate)
                return models.map { model, totals in
                    CodexModelsUsageFragment(
                        workspaceID: bucket.projectId,
                        sessionID: bucket.id,
                        day: date,
                        rawModelID: model,
                        inputTokens: Int64(totals.inputTokens),
                        cachedInputTokens: Int64(totals.cachedInputTokens),
                        outputTokens: Int64(totals.outputTokens),
                        reasoningTokens: nil,
                        costNanos: totals.costNanos,
                        unpricedTokens: Int64(totals.unknownCostTokens))
                }
            }
        }
    }

    fileprivate static func metadata(
        from usage: CostUsageFileUsage,
        catalogEntry: CodexThreadCatalogEntry?) -> Metadata
    {
        let session = usage.codexSession
        return Metadata(
            sessionId: catalogEntry?.id ?? session?.sessionId ?? usage.sessionId,
            cwd: catalogEntry?.cwd ?? session?.cwd,
            title: catalogEntry?.title ?? catalogEntry?.preview ?? session?.title,
            startedAt: self.date(fromUnixMilliseconds: catalogEntry?.createdAtUnixMs ?? session?.startedAtUnixMs),
            latestActivity: self
                .date(fromUnixMilliseconds: catalogEntry?.updatedAtUnixMs ?? session?.latestActivityUnixMs))
    }

    fileprivate static func date(fromUnixMilliseconds unixMs: Int64?) -> Date? {
        guard let unixMs else { return nil }
        return Date(timeIntervalSince1970: Double(unixMs) / 1000)
    }

    fileprivate static func scopeSignature(
        options: CostUsageScanner.Options,
        cache: CostUsageCache,
        catalogFingerprint: String? = nil) -> String
    {
        let roots = self.rootsFingerprint(CostUsageScanner.codexRootsFingerprint(options: options))
        var parts = roots.sorted { $0.key < $1.key }.map { "root:\($0.key)=\($0.value)" }
        parts.append("store=\(CostUsageStore.cacheGeneration)")
        parts.append("pricing=\(cache.codexPricingKey ?? "")")
        parts.append("priorityMetadata=\(cache.codexPriorityMetadataKey ?? "")")
        if let catalogFingerprint {
            parts.append("catalog=\(catalogFingerprint)")
        }
        return "codex-local-project:" + parts.joined(separator: "|")
    }

    fileprivate static func stableScopeSignature(options: CostUsageScanner.Options) -> String {
        "\(CodexLocalDataScope.resolve(options: options).identifier)|timeZone=\(options.calendar.timeZone.identifier)"
    }

    fileprivate static func rootsFingerprint(_ roots: [String: Int64]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: roots.sorted { $0.key < $1.key })
    }

    fileprivate static func total(from projects: [CodexLocalProjectUsage]) -> CodexLocalUsageTotals {
        projects.reduce(.empty) { partial, project in
            partial.adding(project.totals)
        }
    }

    fileprivate static func dailyPoints(from totals: [String: DailyTotals]) -> [CodexLocalUsageDailyPoint] {
        totals.sorted { $0.key < $1.key }.map {
            CodexLocalUsageDailyPoint(
                day: $0.key,
                totalTokens: $0.value.totalTokens,
                cachedInputTokens: $0.value.cachedInputTokens,
                estimatedCostUSD: self.usd(fromNanos: $0.value.costNanos))
        }
    }

    fileprivate static func modelBreakdowns(from modelTotals: [String: ModelTotals])
    -> [CodexLocalUsageModelBreakdown] {
        modelTotals.sorted {
            if $0.value.totalTokens != $1.value.totalTokens {
                return $0.value.totalTokens > $1.value.totalTokens
            }
            return $0.key < $1.key
        }.map {
            CodexLocalUsageModelBreakdown(
                model: $0.key,
                totals: CodexLocalUsageTotals(
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    reasoningOutputTokens: nil,
                    totalTokens: $0.value.totalTokens),
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: $0.value.costNanos) ?? 0,
                    unknownTokens: $0.value.unknownCostTokens))
        }
    }

    fileprivate static func globalModelBreakdowns(
        from sessions: Dictionary<String, SessionBucket>.Values) -> [CodexLocalUsageModelBreakdown]
    {
        var modelTotals: [String: ModelTotals] = [:]
        for session in sessions {
            for (model, totals) in session.modelTotals {
                self.mergeModelTotals(&modelTotals, model: model, totals: totals)
            }
        }
        return self.modelBreakdowns(from: modelTotals)
    }

    fileprivate static func topModel(from modelTotals: [String: ModelTotals]) -> String? {
        modelTotals.max {
            if $0.value.totalTokens != $1.value.totalTokens {
                return $0.value.totalTokens < $1.value.totalTokens
            }
            return $0.key > $1.key
        }?.key
    }

    fileprivate static func addModelTotals(
        _ modelTotals: inout [String: ModelTotals],
        model: String,
        tokens: Int,
        costNanos: Int64?,
        unknownCostTokens: Int)
    {
        self.mergeModelTotals(
            &modelTotals,
            model: model,
            totals: ModelTotals(
                totalTokens: tokens,
                costNanos: costNanos,
                unknownCostTokens: unknownCostTokens))
    }

    fileprivate static func addDailyTotals(
        _ dailyTotals: inout [String: DailyTotals],
        day: String,
        totals: DailyTotals)
    {
        self.mergeDailyTotals(
            &dailyTotals,
            day: day,
            totals: totals)
    }

    fileprivate static func mergeDailyTotals(
        _ dailyTotals: inout [String: DailyTotals],
        day: String,
        totals: DailyTotals)
    {
        var current = dailyTotals[day] ?? DailyTotals(
            totalTokens: 0,
            cachedInputTokens: 0,
            costNanos: nil,
            unknownCostTokens: 0)
        current.totalTokens += totals.totalTokens
        current.cachedInputTokens += totals.cachedInputTokens
        current.costNanos = self.addCost(current.costNanos, totals.costNanos)
        current.unknownCostTokens += totals.unknownCostTokens
        dailyTotals[day] = current
    }

    fileprivate static func mergeModelDailyTotals(
        _ modelDailyTotals: inout [String: [String: ModelDailyTotals]],
        day: String,
        model: String,
        totals: ModelDailyTotals)
    {
        var current = modelDailyTotals[day]?[model] ?? ModelDailyTotals(
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            costNanos: nil,
            unknownCostTokens: 0)
        current.inputTokens += totals.inputTokens
        current.cachedInputTokens += totals.cachedInputTokens
        current.outputTokens += totals.outputTokens
        current.costNanos = self.addCost(current.costNanos, totals.costNanos)
        current.unknownCostTokens += totals.unknownCostTokens
        modelDailyTotals[day, default: [:]][model] = current
    }

    fileprivate static func mergeModelTotals(
        _ modelTotals: inout [String: ModelTotals],
        model: String,
        totals: ModelTotals)
    {
        var existing = modelTotals[model] ?? ModelTotals(totalTokens: 0, costNanos: nil, unknownCostTokens: 0)
        existing.totalTokens += totals.totalTokens
        existing.costNanos = self.addCost(existing.costNanos, totals.costNanos)
        existing.unknownCostTokens += totals.unknownCostTokens
        modelTotals[model] = existing
    }

    fileprivate static func sortProjects(_ lhs: CodexLocalProjectUsage, _ rhs: CodexLocalProjectUsage) -> Bool {
        let lTokens = lhs.totals.totalTokens ?? -1
        let rTokens = rhs.totals.totalTokens ?? -1
        if lTokens != rTokens {
            return lTokens > rTokens
        }
        let lCost = lhs.estimatedCostUSD ?? -1
        let rCost = rhs.estimatedCostUSD ?? -1
        if lCost != rCost {
            return lCost > rCost
        }
        if lhs.sessionCount != rhs.sessionCount {
            return lhs.sessionCount > rhs.sessionCount
        }
        if lhs.latestActivity != rhs.latestActivity {
            return (lhs.latestActivity ?? .distantPast) > (rhs.latestActivity ?? .distantPast)
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    fileprivate static func sortSessions(_ lhs: CodexLocalSessionUsage, _ rhs: CodexLocalSessionUsage) -> Bool {
        let lTokens = lhs.totals.totalTokens ?? -1
        let rTokens = rhs.totals.totalTokens ?? -1
        if lTokens != rTokens {
            return lTokens > rTokens
        }
        let lCost = lhs.estimatedCostUSD ?? -1
        let rCost = rhs.estimatedCostUSD ?? -1
        if lCost != rCost {
            return lCost > rCost
        }
        let lDate = lhs.latestActivity ?? .distantPast
        let rDate = rhs.latestActivity ?? .distantPast
        if lDate != rDate {
            return lDate > rDate
        }
        return lhs.id < rhs.id
    }

    fileprivate static func sessionTitle(
        explicitTitle: String?,
        startedAt: Date?,
        latestActivity: Date?,
        model: String?) -> String
    {
        if let explicitTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitTitle.isEmpty
        {
            return explicitTitle
        }
        let date = latestActivity ?? startedAt
        var parts: [String] = []
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        if let model, !model.isEmpty {
            parts.append(model)
        }
        // Core stores a semantic fallback title, never a UI localization key.
        return parts.isEmpty ? CodexLocalSessionUsage.localChatFallbackTitle : parts.joined(separator: " · ")
    }

    fileprivate static func latestDate(from dayKeys: Dictionary<String, [String: [Int]]>.Keys) -> Date? {
        dayKeys.compactMap(CostUsageDateParser.parse).max()
    }

    fileprivate static func earliestDate(from dayKeys: Dictionary<String, [String: [Int]]>.Keys) -> Date? {
        dayKeys.compactMap(CostUsageDateParser.parse).min()
    }

    fileprivate static func addCost(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        return lhs + rhs
    }

    fileprivate static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            min(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }

    fileprivate static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            max(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }

    fileprivate static func usd(fromNanos nanos: Int64?) -> Double? {
        guard let nanos else { return nil }
        return Double(nanos) / 1_000_000_000
    }
}

import Foundation

extension UsageLedgerLoader {
    /// Explicit exports scan native Codex rollouts with cancellation and a disposable cache.
    public static func loadCodex(
        historyDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current) async throws -> UsageLedger
    {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        return try await self.loadCodex(
            historyDays: historyDays,
            now: now,
            options: CostUsageScanner.Options(
                cacheRoot: cacheRoot,
                calendar: calendar,
                maxCodexSessionFileBytes: 0,
                maxCodexScanBytesPerRefresh: 0))
    }

    static func loadCodex(
        historyDays: Int,
        now: Date,
        options: CostUsageScanner.Options) async throws -> UsageLedger
    {
        guard (1...365).contains(historyDays) else {
            throw UsageLedgerError.invalid("History must be between 1 and 365 days.")
        }
        return try await CostUsageScanExecutor.run { checkCancellation in
            var options = options
            options.refreshMinIntervalSeconds = 0
            let since = CostReportingPeriod.rolling(days: historyDays)
                .bounds(now: now, calendar: options.calendar).lowerBound
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: since,
                until: now,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
            try checkCancellation()
            let roots = CostUsageScanner.codexSessionsRoots(options: options)
            let view = CostUsageStoreAccess.readView(
                cacheRoot: options.cacheRoot,
                calendar: options.calendar,
                purpose: .report).scoped(to: roots)
            return view.codexUsageLedger(
                range: .init(since: since, until: now, calendar: options.calendar),
                historyDays: historyDays,
                now: now,
                cacheRoot: options.cacheRoot,
                rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options))
        }
    }

    /// Identity excludes mutable token/model payloads so conflicting observations remain detectable.
    static func codexLedger(
        cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        historyDays: Int,
        now: Date,
        source: (cacheRoot: URL?, coverageIsEstablished: Bool)) -> UsageLedger
    {
        let cacheRoot = source.cacheRoot
        let catalog = ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
            ?? ModelsDevCatalog(providers: [:])
        let pricingResolver = CostUsagePricing.CodexResolver(catalog: catalog)
        let customPricing = CostUsageCustomPricing.load()
        let priorityTurns = CostUsageScanner.validatedPriorityTurns(cache: cache, calendar: range.calendar)
        var records: [UsageLedgerRecord] = []
        var warnings: [String] = []
        var coverage = source.coverageIsEstablished
        var missingTimestamp = false
        var redactedModel = false
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            guard usage.hasCurrentCodexParser else {
                coverage = false
                continue
            }
            for row in usage.codexRows ?? [] {
                guard row.day >= range.sinceKey, row.day <= range.untilKey,
                      OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: row.model)
                else { continue }
                let total = row.input.addingReportingOverflow(row.output)
                guard !total.overflow, row.input >= 0, row.cached >= 0, row.output >= 0 else {
                    coverage = false
                    warnings.append("Invalid native token counts were excluded.")
                    continue
                }
                let identity: UsageLedgerIdentity
                let components: [String]
                if let session = usage.sessionId, let response = row.responseID {
                    identity = .request
                    components = ["codex", "request", session, response]
                } else if let session = usage.sessionId, let timestamp = row.timestampUnixMs,
                          row.turnID != nil || row.eventIndex != nil
                {
                    identity = .legacyEvent
                    components = [
                        "codex", "legacy", session, String(timestamp), row.turnID ?? "",
                        row.eventIndex.map(String.init) ?? "",
                    ]
                } else {
                    identity = .unidentified
                    components = [
                        "codex", "unidentified", path, row.eventIndex.map(String.init) ?? "",
                        row.timestampUnixMs.map(String.init) ?? "",
                    ]
                }
                // Missing timestamps retain the native day bucket without inventing request identity.
                let timestamp = row.timestampUnixMs
                    ?? CostUsageLocalDay.date(fromKey: row.day, calendar: range.calendar)
                    .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                missingTimestamp = missingTimestamp || row.timestampUnixMs == nil
                let cost = (row.unpricedTokens ?? 0) == 0 ? CostUsageScanner.codexResolvedCostUSD(
                    for: row,
                    priorityTurns: priorityTurns,
                    modelsDevCatalog: catalog,
                    modelsDevCacheRoot: cacheRoot,
                    customPricing: customPricing,
                    pricingResolver: pricingResolver) : nil
                let priority = row.turnID.flatMap { priorityTurns[$0] }
                let pricingModel = priority.map {
                    CostUsageScanner.codexPriorityPricingModel(for: row, priorityMetadata: $0)
                } ?? row.pricingModel ?? row.model
                let exportedModel = Self.codexLedgerModel(row.model)
                let exportedPricingModel = Self.codexLedgerModel(pricingModel)
                redactedModel = redactedModel || exportedModel != row.model || exportedPricingModel != pricingModel
                records.append(UsageLedgerRecord(
                    id: UsageLedgerRecord.digest(components),
                    sessionID: usage.sessionId.map { UsageLedgerRecord.digest(["codex", "session", $0]) },
                    identity: identity,
                    timestampUnixMs: timestamp,
                    model: exportedModel,
                    inputTokens: row.input,
                    cacheReadTokens: row.cached,
                    outputTokens: row.output,
                    totalTokens: total.partialValue,
                    costUSD: cost,
                    reasoningTokens: row.reasoning,
                    costProvenance: cost == nil ? .unknown
                        : row.knownCostNanos == nil ? .listPriceEstimate : .vendorMetered,
                    pricingModel: exportedPricingModel,
                    pricingMode: priority != nil || row.pricingMode == "priority" ? "priority" : "standard"))
            }
        }
        if records.contains(where: { $0.identity == .legacyEvent }) {
            warnings.append("Legacy Codex events lack provider request IDs; matching relies on rollout provenance.")
        }
        if records.contains(where: { $0.identity == .unidentified }) {
            warnings.append("Some Codex records lack stable identity and cannot be deduplicated across hosts.")
        }
        if missingTimestamp {
            coverage = false
            warnings.append("Some Codex records have only a day bucket; their timestamp is the native day's start.")
        }
        if redactedModel {
            warnings.append("Non-identifier model metadata was redacted from the numeric export.")
        }
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: catalog,
            modelsDevCacheRoot: cacheRoot,
            priorityTurns: priorityTurns)
        let exportedTokens = CheckedSum.integers(records.map(\.totalTokens))
        let nativeTokens = CheckedSum.integers(report.data.compactMap(\.totalTokens))
        if exportedTokens == nil || nativeTokens == nil || exportedTokens != nativeTokens {
            coverage = false
            warnings.append("Exported Codex records do not reconcile with native totals; coverage is partial.")
        }
        let unresolved = CheckedSum.integers(
            Array(CostUsageScanner.unresolvedForkUnmeteredCounts(cache: cache, range: range).values)) ?? 0
        if unresolved > 0 {
            coverage = false
            warnings.append("Fork usage with an unavailable parent baseline remains unmetered.")
        }
        if !coverage {
            warnings.append("Native Codex history coverage is incomplete; exported usage is partial.")
        }
        var ledger = UsageLedger(
            provider: "codex",
            updatedAt: Date(),
            historyDays: historyDays,
            bucketTimeZone: range.calendar.timeZone.identifier,
            coverageIsEstablished: coverage,
            records: records,
            incompleteRequestCount: unresolved,
            warnings: Array(Set(warnings)).sorted())
        ledger.windowStartUnixMs = CostUsageLocalDay.date(fromKey: range.sinceKey, calendar: range.calendar)
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        ledger.windowEndUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        return ledger
    }

    /// Rollout-controlled strings must be model identifiers, never arbitrary paths or text.
    private static func codexLedgerModel(_ raw: String) -> String {
        let model = CostUsagePricing.normalizeCodexModel(raw)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !model.isEmpty, model.utf8.count <= 128,
              model.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return CostUsagePricing.codexUnattributedModel }
        return model
    }
}

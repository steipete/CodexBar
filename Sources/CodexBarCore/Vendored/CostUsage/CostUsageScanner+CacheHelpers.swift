import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageScanner {
    private final class CodexModelsDevCatalogResolver {
        private var catalog: ModelsDevCatalog?
        private let cacheRoot: URL?

        init(catalog: ModelsDevCatalog?, cacheRoot: URL?) {
            self.catalog = catalog
            self.cacheRoot = cacheRoot
        }

        func load(_ loader: (URL?) -> ModelsDevCatalog?) -> ModelsDevCatalog {
            if let catalog {
                return catalog
            }
            let loaded = loader(self.cacheRoot) ?? ModelsDevCatalog(providers: [:])
            self.catalog = loaded
            return loaded
        }
    }

    static func codexRowsByDayModel(
        rows: [CodexUsageRow],
        range: CostUsageDayRange) -> [String: [String: [CodexUsageRow]]]
    {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]] = [:]
        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }
            rowsByDayModel[row.day, default: [:]][row.model, default: []].append(row)
        }
        return rowsByDayModel
    }

    static func codexCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexCostNanos }
    }

    static func codexStandardTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexStandardTokens }
    }

    static func codexPriorityTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexPriorityTokens }
    }

    static func codexReportDayKeys(cache: CostUsageCache, range: CostUsageDayRange) -> [String] {
        cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
    }

    static func codexNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int64]]?) -> [String: [String: Int64]]
    {
        var out: [String: [String: Int64]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    out[day, default: [:]][model, default: 0] += value
                }
            }
        }
        return out
    }

    static func codexIntByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int]]?) -> [String: [String: Int]]
    {
        var out: [String: [String: Int]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    out[day, default: [:]][model, default: 0] += value
                }
            }
        }
        return out
    }

    struct CodexRowCostBreakdown {
        var standardCostUSD: Double = 0
        var priorityCostUSD: Double = 0
        var standardTokens: Int = 0
        var priorityTokens: Int = 0
        var sawStandardCost = false
        var sawPriorityCost = false
        var hasUnstableTokenRows = false
        var hasTokenOverflow = false
        var hasIncompletePricing = false

        var optionalStandardCostUSD: Double? {
            self.sawStandardCost ? self.standardCostUSD : nil
        }

        var optionalPriorityCostUSD: Double? {
            self.sawPriorityCost ? self.priorityCostUSD : nil
        }

        var optionalStandardTokens: Int? {
            self.standardTokens > 0 ? self.standardTokens : nil
        }

        var optionalPriorityTokens: Int? {
            self.priorityTokens > 0 ? self.priorityTokens : nil
        }

        var totalCostUSD: Double? {
            guard self.sawStandardCost || self.sawPriorityCost else { return nil }
            return self.standardCostUSD + self.priorityCostUSD
        }

        var hasModeSplit: Bool {
            self.sawPriorityCost || self.priorityTokens > 0
        }

        func isTrusted(canonicalTotalTokens: Int) -> Bool {
            let (rowTokenTotal, overflow) = self.standardTokens.addingReportingOverflow(self.priorityTokens)
            return !self.hasUnstableTokenRows
                && !self.hasTokenOverflow
                && !self.hasIncompletePricing
                && !overflow
                && rowTokenTotal == canonicalTotalTokens
        }
    }

    static func codexRowCostBreakdown(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing? = nil) -> CodexRowCostBreakdown
    {
        var breakdown = CodexRowCostBreakdown()
        for row in rows {
            let (tokenCount, tokenOverflow) = max(0, row.input).addingReportingOverflow(max(0, row.output))
            let hasTokens = row.input > 0 || row.cached > 0 || row.output > 0
            if tokenOverflow {
                breakdown.hasTokenOverflow = true
            }
            if hasTokens, row.eventIndex == nil {
                breakdown.hasUnstableTokenRows = true
            }
            if (row.unpricedTokens ?? 0) > 0 {
                breakdown.hasIncompletePricing = true
            }
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil || row.pricingMode == "priority"
            if isPriority {
                let (total, overflow) = breakdown.priorityTokens.addingReportingOverflow(tokenCount)
                breakdown.priorityTokens = overflow ? breakdown.priorityTokens : total
                breakdown.hasTokenOverflow = breakdown.hasTokenOverflow || overflow
            } else {
                let (total, overflow) = breakdown.standardTokens.addingReportingOverflow(tokenCount)
                breakdown.standardTokens = overflow ? breakdown.standardTokens : total
                breakdown.hasTokenOverflow = breakdown.hasTokenOverflow || overflow
            }
            guard let cost = self.codexResolvedCostUSD(
                for: row,
                priorityTurns: priorityTurns,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: customPricing)
            else {
                breakdown.hasIncompletePricing = breakdown.hasIncompletePricing || hasTokens
                continue
            }
            if isPriority {
                breakdown.priorityCostUSD += cost
                breakdown.sawPriorityCost = true
            } else {
                breakdown.standardCostUSD += cost
                breakdown.sawStandardCost = true
            }
        }
        return breakdown
    }

    // MARK: - File cache construction

    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil,
        lastCountedTotals: CostUsageCodexTotals? = nil,
        lastRawTotalsBaseline: CostUsageCodexTotals? = nil,
        lastRawTotalsWatermark: CostUsageCodexTotals? = nil,
        seenRawTotals: [CostUsageCodexTotals]? = nil,
        hasDivergentTotals: Bool? = nil,
        hasInterleavedTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        forkBaselineDependencyKey: String? = nil,
        projectPath: String? = nil,
        canonicalProjectPath: String? = nil,
        codexCostCacheComplete: Bool? = true,
        codexSession: CostUsageCodexSessionMetadata? = nil,
        codexCostNanos: [String: [String: Int64]]? = nil,
        codexPrioritySurchargeNanos: [String: [String: Int64]]? = nil,
        codexStandardCostNanos: [String: [String: Int64]]? = nil,
        codexPriorityCostNanos: [String: [String: Int64]]? = nil,
        codexStandardTokens: [String: [String: Int]]? = nil,
        codexPriorityTokens: [String: [String: Int]]? = nil,
        codexTurnIDs: [String]? = nil,
        codexRows: [CodexUsageRow]? = nil,
        codexTokenSnapshots: [CostUsageCodexTokenSnapshot]? = nil,
        codexTokenCheckpoints: [CostUsageCodexTokenCheckpoint]? = nil,
        codexTokenTimestampsMonotonic: Bool? = nil,
        codexTokenIndexAnchor: CostUsageCodexTokenIndexAnchor? = nil,
        claudeRows: [ClaudeUsageRow]? = nil,
        codexScanFileId: String? = nil,
        codexScanTargetSize: Int64? = nil,
        codexScanComplete: Bool? = nil,
        codexJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        codexBufferedSubagentLines: [CodexBufferedFastLine]? = nil,
        codexBufferedUnresolvedForkLines: [CodexBufferedFastLine]? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            lastCountedTotals: lastCountedTotals,
            lastRawTotalsBaseline: lastRawTotalsBaseline,
            lastRawTotalsWatermark: lastRawTotalsWatermark,
            seenRawTotals: seenRawTotals,
            hasDivergentTotals: hasDivergentTotals,
            hasInterleavedTotals: hasInterleavedTotals,
            lastCodexTurnID: lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostCacheComplete: codexCostCacheComplete,
            codexSession: codexSession,
            codexCostNanos: codexCostNanos,
            codexPrioritySurchargeNanos: codexPrioritySurchargeNanos,
            codexStandardCostNanos: codexStandardCostNanos,
            codexPriorityCostNanos: codexPriorityCostNanos,
            codexStandardTokens: codexStandardTokens,
            codexPriorityTokens: codexPriorityTokens,
            codexTurnIDs: codexTurnIDs,
            codexRows: codexRows,
            codexTokenSnapshots: codexTokenSnapshots,
            codexTokenCheckpoints: codexTokenCheckpoints,
            codexTokenTimestampsMonotonic: codexTokenTimestampsMonotonic,
            codexTokenIndexAnchor: codexTokenIndexAnchor,
            claudeRows: claudeRows,
            codexScanFileId: codexScanFileId,
            codexScanTargetSize: codexScanTargetSize,
            codexScanComplete: codexScanComplete,
            codexJSONLResumeState: codexJSONLResumeState,
            codexBufferedSubagentLines: codexBufferedSubagentLines,
            codexBufferedUnresolvedForkLines: codexBufferedUnresolvedForkLines)
    }

    static func needsCodexPricingMetadata(_ usage: CostUsageFileUsage) -> Bool {
        !(usage.codexRows?.isEmpty ?? true)
            && (usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage))
    }

    static func needsCodexPricingMetadata(_ usage: CostUsageFileUsage, range: CostUsageDayRange) -> Bool {
        guard usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage) else {
            return false
        }
        guard let rows = usage.codexRows, !rows.isEmpty else { return false }
        return rows.contains {
            CostUsageDayRange.isInRange(dayKey: $0.day, since: range.sinceKey, until: range.untilKey)
        }
    }

    static func needsCodexModeSplitCache(_ usage: CostUsageFileUsage) -> Bool {
        let hasStandardCost = !(usage.codexStandardCostNanos?.isEmpty ?? true)
        let hasPriorityCost = !(usage.codexPriorityCostNanos?.isEmpty ?? true)
        let hasStandardTokens = !(usage.codexStandardTokens?.isEmpty ?? true)
        let hasPriorityTokens = !(usage.codexPriorityTokens?.isEmpty ?? true)

        // Token maps are also the completion marker for models with no known pricing.
        guard hasStandardTokens || hasPriorityTokens else { return true }
        return (hasStandardCost && !hasStandardTokens) || (hasPriorityCost && !hasPriorityTokens)
    }

    static func codexFileUsageWithPricingMetadata(
        _ usage: CostUsageFileUsage,
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        self.codexFileUsageWithPricingMetadata(
            usage,
            range: context.range,
            priorityTurns: context.resources.priorityTurns)
    }

    static func codexFileUsageWithPricingMetadata(
        _ usage: CostUsageFileUsage,
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> CostUsageFileUsage
    {
        guard let rows = usage.codexRows, !rows.isEmpty else { return usage }
        var migratedRows: [CodexUsageRow] = []
        for row in rows where CostUsageDayRange.isInRange(
            dayKey: row.day,
            since: range.scanSinceKey,
            until: range.scanUntilKey)
        {
            migratedRows.append(row)
        }
        guard !migratedRows.isEmpty else { return usage }

        let modeTokens = Self.codexModeTokenMaps(
            rows: migratedRows,
            range: range,
            priorityTurns: priorityTurns)
        var updated = usage
        updated.codexCostNanos = Self.mergeMissingCostMaps(
            usage.codexCostNanos,
            Self.codexCostNanos(rows: migratedRows, range: range))
        updated.codexPrioritySurchargeNanos = nil
        updated.codexStandardCostNanos = nil
        updated.codexPriorityCostNanos = nil
        updated.codexStandardTokens = Self.mergeMissingIntMaps(
            usage.codexStandardTokens,
            modeTokens.standard)
        updated.codexPriorityTokens = Self.mergeMissingIntMaps(
            usage.codexPriorityTokens,
            modeTokens.priority)
        updated.codexCostCacheComplete = true
        updated.codexTurnIDs = Self.mergeCodexTurnIDs(usage.codexTurnIDs, rows: migratedRows)
        updated.codexRows = Self.codexRowsWithPricingMetadata(
            rows,
            priorityTurns: priorityTurns)
        return updated.refreshingCodexWorkspaceUsageFingerprint()
    }

    static func codexRowsWithPricingMetadata(
        _ rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> [CodexUsageRow]
    {
        rows.map { row in
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil || row.pricingMode == "priority"
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.pricingModel
                ?? row.model
            return CodexUsageRow(
                day: row.day,
                model: row.model,
                rawModel: row.rawModel,
                turnID: row.turnID,
                eventIndex: row.eventIndex,
                timestampUnixMs: row.timestampUnixMs,
                input: row.input,
                cached: row.cached,
                output: row.output,
                reasoning: row.reasoning,
                knownCostNanos: row.knownCostNanos,
                unpricedTokens: row.unpricedTokens,
                pricingModel: pricedModel,
                pricingMode: isPriority ? "priority" : "standard")
        }
    }

    static func codexMergedCostMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexCostNanos(rows: deltaRows, range: context.range))
    }

    static func codexCostNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange) -> [String: [String: Int64]]?
    {
        var out: [String: [String: Int64]] = [:]
        for row in rows where CostUsageDayRange.isInRange(
            dayKey: row.day,
            since: range.sinceKey,
            until: range.untilKey)
        {
            guard let cost = row.knownCostNanos else { continue }
            out[row.day, default: [:]][row.model, default: 0] += cost
        }
        return out.isEmpty ? nil : out
    }

    static func codexModeTokenMaps(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> (
        standard: [String: [String: Int]]?,
        priority: [String: [String: Int]]?)
    {
        var standardTokens: [String: [String: Int]] = [:]
        var priorityTokens: [String: [String: Int]] = [:]

        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }

            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil || row.pricingMode == "priority"

            if isPriority {
                priorityTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            } else {
                standardTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            }
        }

        return (
            standardTokens.isEmpty ? nil : standardTokens,
            priorityTokens.isEmpty ? nil : priorityTokens)
    }

    static func codexTurnIDs(rows: [CodexUsageRow]) -> [String]? {
        let ids = Set(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCodexTurnIDs(_ existing: [String]?, rows: [CodexUsageRow]) -> [String]? {
        var ids = Set(existing ?? [])
        ids.formUnion(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCodexRows(
        _ existing: [CodexUsageRow]?,
        rows: [CodexUsageRow],
        sessionId: String?) -> [CodexUsageRow]?
    {
        var merged = (existing ?? []).filter { self.hasStableCodexRowIdentity($0) }
        let existingKeys = Set(merged.map { Self.codexUsageRowKey(sessionId: sessionId, row: $0) })
        for row in rows where !existingKeys.contains(Self.codexUsageRowKey(sessionId: sessionId, row: row)) {
            merged.append(row)
        }
        return merged.isEmpty ? nil : merged
    }

    static func hasStableCodexRowIdentity(_ row: CodexUsageRow) -> Bool {
        row.eventIndex != nil
    }

    static func codexRowsNeedIdentityRescan(_ rows: [CodexUsageRow]) -> Bool {
        rows.contains { !Self.hasStableCodexRowIdentity($0) }
    }

    static func cachedCodexRowsNeedIdentityRescan(_ usage: CostUsageFileUsage) -> Bool {
        let rows = usage.codexRows ?? []
        return (!usage.days.isEmpty && rows.isEmpty) || Self.codexRowsNeedIdentityRescan(rows)
    }

    static func nextCodexUsageRowIndex(_ rows: [CodexUsageRow]?) -> Int {
        guard let rows, !rows.isEmpty else { return 0 }
        if let maxIndex = rows.compactMap(\.eventIndex).max() {
            return maxIndex + 1
        }
        return rows.count
    }

    static func codexUsageRowKey(
        sessionId: String?,
        fileIdentity: String? = nil,
        row: CodexUsageRow) -> String
    {
        [
            sessionId.map { "session:\($0)" } ?? "file:\(fileIdentity ?? "")",
            row.turnID ?? "",
            row.eventIndex.map(String.init) ?? "",
            row.day,
            row.model,
            String(row.input),
            String(row.cached),
            String(row.output),
        ].joined(separator: "\u{1F}")
    }

    static func uniqueCodexRows(
        rows: [CodexUsageRow],
        sessionId: String?,
        fileIdentity: String,
        state: inout CodexScanState) -> [CodexUsageRow]
    {
        var unique: [CodexUsageRow] = []
        var acceptedKeys = Set<String>()
        for row in rows {
            let key = Self.codexUsageRowKey(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
            if !state.seenCodexUsageRowKeys.contains(key) {
                unique.append(row)
                acceptedKeys.insert(key)
            }
        }
        state.seenCodexUsageRowKeys.formUnion(acceptedKeys)
        return unique
    }

    static func rememberCodexRows(
        _ rows: [CodexUsageRow],
        sessionId: String?,
        fileIdentity: String,
        state: inout CodexScanState)
    {
        for row in rows {
            state.seenCodexUsageRowKeys.insert(self.codexUsageRowKey(
                sessionId: sessionId,
                fileIdentity: fileIdentity,
                row: row))
        }
    }

    static func codexFileDays(rows: [CodexUsageRow]) -> [String: [String: [Int]]] {
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            let packed = days[row.day]?[row.model] ?? []
            days[row.day, default: [:]][row.model] = Self.addPacked(
                a: packed,
                b: [row.input, row.cached, row.output],
                sign: 1)
        }
        return days
    }

    static func codexFileUsageByFilteringRows(
        _ usage: CostUsageFileUsage,
        rows: [CodexUsageRow],
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        var days = Self.fileDaysOutsideScanWindow(usage.days, range: context.range)
        let rowsInScanWindow = rows.filter {
            CostUsageDayRange.isInRange(
                dayKey: $0.day,
                since: context.range.scanSinceKey,
                until: context.range.scanUntilKey)
        }
        Self.mergeFileDays(existing: &days, delta: Self.codexFileDays(rows: rowsInScanWindow))
        let modeTokens = Self.codexModeTokenMaps(
            rows: rows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns)

        return Self.makeFileUsage(
            mtimeUnixMs: usage.mtimeUnixMs,
            size: usage.size,
            days: days,
            parsedBytes: usage.parsedBytes,
            lastModel: usage.lastModel,
            lastTotals: usage.lastTotals,
            lastCountedTotals: usage.lastCountedTotals,
            lastRawTotalsBaseline: usage.lastRawTotalsBaseline,
            lastRawTotalsWatermark: usage.lastRawTotalsWatermark,
            seenRawTotals: usage.seenRawTotals,
            hasDivergentTotals: usage.hasDivergentTotals,
            hasInterleavedTotals: usage.hasInterleavedTotals,
            lastCodexTurnID: usage.lastCodexTurnID,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            forkBaselineDependencyKey: usage.forkBaselineDependencyKey,
            projectPath: usage.projectPath,
            canonicalProjectPath: usage.canonicalProjectPath,
            codexCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexCostNanos, range: context.range),
                Self.codexCostNanos(rows: rows, range: context.range)),
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexStandardTokens, range: context.range),
                modeTokens.standard),
            codexPriorityTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexPriorityTokens, range: context.range),
                modeTokens.priority),
            codexTurnIDs: Self.mergeCodexTurnIDs(nil, rows: rows),
            codexRows: rows,
            codexTokenSnapshots: usage.codexTokenSnapshots,
            codexTokenCheckpoints: usage.codexTokenCheckpoints,
            codexTokenTimestampsMonotonic: usage.codexTokenTimestampsMonotonic,
            codexTokenIndexAnchor: usage.codexTokenIndexAnchor,
            codexScanFileId: usage.codexScanFileId,
            codexScanTargetSize: usage.codexScanTargetSize,
            codexScanComplete: usage.codexScanComplete,
            codexJSONLResumeState: usage.codexJSONLResumeState,
            codexBufferedSubagentLines: usage.codexBufferedSubagentLines,
            codexBufferedUnresolvedForkLines: usage.codexBufferedUnresolvedForkLines)
            .refreshingCodexWorkspaceUsageFingerprint()
    }

    static func mergeCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func costMapOutsideScanWindow(
        _ map: [String: [String: Int64]]?,
        range: CostUsageDayRange) -> [String: [String: Int64]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    static func intMapOutsideScanWindow(
        _ map: [String: [String: Int]]?,
        range: CostUsageDayRange) -> [String: [String: Int]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    // MARK: - File scan orchestration

    struct CodexFileMetadata {
        let path: String
        let mtimeUnixMs: Int64
        let size: Int64
        let fileId: String?
    }

    struct CodexFileScanInput {
        let fileURL: URL
        let metadata: CodexFileMetadata
        let cached: CostUsageFileUsage?
    }

    static func codexFileMetadata(fileURL: URL) -> CodexFileMetadata {
        let path = fileURL.path
        var info = stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            return CodexFileMetadata(path: path, mtimeUnixMs: 0, size: 0, fileId: nil)
        }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #endif
        return CodexFileMetadata(
            path: path,
            mtimeUnixMs: modifiedSeconds * 1000 + modifiedNanoseconds / 1_000_000,
            size: Int64(info.st_size),
            fileId: "\(info.st_dev):\(info.st_ino)")
    }

    static func dropCachedCodexFile(
        path: String,
        cached: CostUsageFileUsage?,
        cache: inout CostUsageCache)
    {
        if let cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        cache.files.removeValue(forKey: path)
    }

    static func rememberScannedCodexFile(
        input: CodexFileScanInput,
        session: CodexScannedSession,
        rows: [CodexUsageRow],
        context: CodexFileScanContext,
        state: inout CodexScanState)
    {
        if let sessionId = session.id {
            context.resources.fileIndex.remember(fileURL: input.fileURL, sessionId: sessionId)
            if session.contributedUsage {
                state.contributingSessionIds.insert(sessionId)
            }
        }
        Self.rememberCodexRows(
            rows,
            sessionId: session.id,
            fileIdentity: input.metadata.path,
            state: &state)
        if let fileId = input.metadata.fileId {
            state.seenFileIds.insert(fileId)
        }
    }

    static func keepCachedCodexFileIfFresh(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        guard let cached = input.cached else { return false }
        let needsSessionId = cached.sessionId == nil
        guard cached.mtimeUnixMs == input.metadata.mtimeUnixMs,
              cached.size == input.metadata.size,
              cached.codexScanComplete != false,
              !needsSessionId,
              !context.forceFullScan
        else { return false }

        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }

        let sessionAlreadyContributed = cached.sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let cachedRows = cached.codexRows ?? []
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        if let parentSessionId = cached.forkedFromId {
            guard let cachedDependencyKey = cached.forkBaselineDependencyKey else { return false }
            if cachedDependencyKey != Self.codexForkDependencyNotRequiredKey {
                guard let currentDependencyKey = try context.resources.inheritedResolver
                    .currentDependencyKey(for: parentSessionId)
                else { return false }
                guard cachedDependencyKey == currentDependencyKey else { return false }
            }
        }

        if sessionAlreadyContributed {
            guard !cachedRows.isEmpty else { return false }
            let uniqueRows = Self.uniqueCodexRows(
                rows: cachedRows,
                sessionId: cached.sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
            guard !uniqueRows.isEmpty else {
                Self.dropCachedCodexFile(path: input.metadata.path, cached: cached, cache: &cache)
                return true
            }
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            let filtered = Self.codexFileUsageByFilteringRows(cached, rows: uniqueRows, context: context)
            cache.files[input.metadata.path] = filtered
            Self.applyFileDays(cache: &cache, fileDays: filtered.days, sign: 1)
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: filtered.days),
                rows: uniqueRows,
                context: context,
                state: &state)
            return true
        }

        let current = if Self.needsCodexPricingMetadata(cached, range: context.range) {
            Self.codexFileUsageWithPricingMetadata(cached, context: context)
        } else {
            cached
        }
        cache.files[input.metadata.path] = current
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: current.sessionId, days: current.days),
            rows: cachedRows,
            context: context,
            state: &state)
        return true
    }

    static func cachedCodexFileNeedsPriorityRescan(
        _ cached: CostUsageFileUsage,
        context: CodexFileScanContext) -> Bool
    {
        if cached.codexTurnIDs == nil {
            return context.requiresTurnIDCache
        }
        guard !context.changedPriorityTurnIDs.isEmpty else { return false }
        return !(Set(cached.codexTurnIDs ?? []).isDisjoint(with: context.changedPriorityTurnIDs))
    }

    /// Replays any compact fork buffer without reading JSONL when the indexed file is unchanged.
    /// This remains safe for subagents because no appended lineage can change their classification.
    static func isValidatedSameSizeBufferedCodexForkRetry(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        let startOffset = cached.parsedBytes ?? cached.size
        guard cached.forkedFromId != nil,
              cached.forkBaselineDependencyKey == nil,
              cached.hasBufferedCodexForkRetryLines,
              cached.codexScanComplete != false,
              cached.codexJSONLResumeState == nil,
              cached.codexScanFileId == metadata.fileId,
              startOffset > 0,
              startOffset == metadata.size,
              cached.codexTokenIndexAnchor?.indexedBytes == startOffset
        else { return false }
        return cached.codexTokenIndexAnchor.map {
            Self.codexTokenIndexAnchorMatches(
                $0,
                fileURL: URL(fileURLWithPath: metadata.path),
                metadata: metadata)
        } == true
    }

    /// Reuses compact ordinary-fork events for a validated appended suffix.
    /// Appended subagent buffers still require a full rescan because later lineage can change attribution.
    static func isAppendSafeBufferedCodexForkResume(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        let startOffset = cached.parsedBytes ?? cached.size
        guard cached.codexScanComplete != false,
              cached.forkedFromId != nil,
              cached.codexBufferedSubagentLines?.isEmpty != false,
              cached.codexBufferedUnresolvedForkLines?.isEmpty == false,
              cached.codexJSONLResumeState == nil,
              cached.codexScanFileId != nil,
              cached.codexScanFileId == metadata.fileId,
              startOffset > 0,
              startOffset <= metadata.size,
              cached.codexTokenIndexAnchor?.indexedBytes == startOffset
        else { return false }
        return cached.codexTokenIndexAnchor.map {
            Self.codexTokenIndexAnchorMatches(
                $0,
                fileURL: URL(fileURLWithPath: metadata.path),
                metadata: metadata)
        } == true
    }

    // swiftlint:disable:next function_body_length
    static func appendCodexFileIncrementIfPossible(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws -> Bool
    {
        try context.checkCancellation?()
        guard let cached = input.cached, cached.sessionId != nil, !context.forceFullScan else { return false }
        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        // Subagent shape depends on the complete lineage prefix. Appended metadata can change an
        // independent counter into a copied-prefix rollout, so a tail-only parse is not sound.
        let startOffset = cached.parsedBytes ?? cached.size
        let hasMatchingResumeOffset = cached.codexJSONLResumeState?.offset == nil
            || cached.codexJSONLResumeState?.offset == startOffset
        let isResumablePartial = cached.codexScanComplete == false
            && cached.codexScanFileId != nil
            && cached.codexScanFileId == input.metadata.fileId
            && startOffset > 0
            && startOffset <= input.metadata.size
            && cached.codexTokenIndexAnchor?.indexedBytes == startOffset
            && cached.codexTokenIndexAnchor.map {
                CostUsageScanner.codexTokenIndexAnchorMatches(
                    $0,
                    fileURL: input.fileURL,
                    metadata: input.metadata)
            } == true
            && hasMatchingResumeOffset
        let isBufferedForkRetry = Self.isValidatedSameSizeBufferedCodexForkRetry(
            metadata: input.metadata,
            cached: cached)
        let isOrdinaryUnresolvedForkResume = !isBufferedForkRetry
            && Self.isAppendSafeBufferedCodexForkResume(
                metadata: input.metadata,
                cached: cached)
        let isBufferedForkResume = isBufferedForkRetry || isOrdinaryUnresolvedForkResume
        if cached.codexScanComplete == false, !isResumablePartial {
            return false
        }
        if !isResumablePartial, !isBufferedForkResume, try Self.codexFileIsSubagentThread(
            fileURL: input.fileURL,
            checkCancellation: context.checkCancellation)
        {
            return false
        }
        let initialCountedTotals = cached.lastCountedTotals ?? cached.lastTotals
        let initialRawTotalsBaseline = cached.lastRawTotalsBaseline ?? cached.lastTotals
        let initialHasDivergentTotals = cached.hasDivergentTotals ?? (cached.lastTotals == nil)
        let initialAccumulatorState = CostUsageCodexTokenAccumulatorState(
            countedTotals: initialCountedTotals,
            rawTotalsBaseline: initialRawTotalsBaseline,
            sawDivergentTotals: initialHasDivergentTotals,
            rawTotalsWatermark: cached.lastRawTotalsWatermark,
            seenRawTotals: cached.seenRawTotals ?? [],
            sawInterleavedTotals: cached.hasInterleavedTotals ?? false)
        // Correctness-critical interleave state is watermark + interleaved flag (+ counted/raw).
        // `seenRawTotals` is optional precision only and must not gate incremental resume (#2037).
        let hasIncompleteInterleaveState =
            (cached.hasInterleavedTotals == true && cached.lastRawTotalsWatermark == nil)
            || (cached.lastRawTotalsWatermark != nil && cached.hasInterleavedTotals == nil)
            || (initialHasDivergentTotals && cached.lastRawTotalsWatermark == nil)
        let canIncremental = startOffset > 0
            && startOffset <= input.metadata.size
            && (isResumablePartial
                || isBufferedForkResume
                || (input.metadata.size > cached.size
                    && initialCountedTotals != nil
                    && cached.forkedFromId == nil
                    && !hasIncompleteInterleaveState))
        guard canIncremental else { return false }

        let delta = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            startOffset: startOffset,
            initialModel: cached.lastModel,
            initialTotals: initialCountedTotals,
            initialRawTotalsBaseline: initialRawTotalsBaseline,
            initialRawTotalsWatermark: cached.lastRawTotalsWatermark,
            initialSeenRawTotals: cached.seenRawTotals ?? [],
            initialHasDivergentTotals: initialHasDivergentTotals,
            initialHasInterleavedTotals: cached.hasInterleavedTotals ?? false,
            initialCodexTurnID: cached.lastCodexTurnID,
            initialCodexUsageRowIndex: Self.nextCodexUsageRowIndex(cached.codexRows),
            initialBufferedSubagentLines: cached.codexBufferedSubagentLines,
            initialBufferedUnresolvedForkLines: cached.codexBufferedUnresolvedForkLines,
            initialJSONLResumeState: cached.codexJSONLResumeState,
            maxBytesToRead: maxBytesToRead,
            shouldStopReading: context.scanBudget.map { budget in
                { bytesRead in budget.shouldYield(additionalBytes: bytesRead) }
            },
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation)
        if delta.forkedFromId != nil, !isResumablePartial, !isBufferedForkResume {
            return false
        }
        let migrated = Self.codexFileUsageWithPricingMetadata(cached, context: context)
        let cachedSessionMetadata = migrated.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: migrated.sessionId,
            forkedFromId: migrated.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let codexSession = cachedSessionMetadata.merging(delta.codexSession)
        let sessionId = codexSession.sessionId ?? delta.sessionId ?? cached.sessionId
        let projectPath = delta.projectPath ?? cached.projectPath
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: delta.forkedFromId,
            dependsOnParentTotals: delta.dependsOnParentTotals,
            inheritedResolver: context.resources.inheritedResolver)
        let canonicalProjectPath = delta.projectPath.map {
            context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? cached.canonicalProjectPath ?? context.resources.projectPathResolver.canonicalProjectPath(for: projectPath)
        let sessionAlreadyContributed = sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let cachedRows = cached.codexRows ?? []
        let retainedCachedRows: [CodexUsageRow]
        if sessionAlreadyContributed {
            retainedCachedRows = Self.uniqueCodexRows(
                rows: cachedRows,
                sessionId: sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
        } else {
            Self.rememberCodexRows(
                cachedRows,
                sessionId: sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
            retainedCachedRows = cachedRows
        }
        let uniqueRows = Self.uniqueCodexRows(
            rows: delta.rows,
            sessionId: sessionId,
            fileIdentity: input.metadata.path,
            state: &state)
        let classifiedUniqueRows = Self.codexRowsWithPricingMetadata(
            uniqueRows,
            priorityTurns: context.resources.priorityTurns)
        context.workRecorder?.record(processed: uniqueRows.count, repriced: classifiedUniqueRows.count)

        let migratedCached = sessionAlreadyContributed
            ? Self.codexFileUsageByFilteringRows(migrated, rows: retainedCachedRows, context: context)
            : migrated
        if sessionAlreadyContributed, migratedCached.days.isEmpty, uniqueRows.isEmpty {
            Self.dropCachedCodexFile(path: input.metadata.path, cached: cached, cache: &cache)
            return true
        }
        let uniqueDays = Self.codexFileDays(rows: uniqueRows)

        if sessionAlreadyContributed {
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            Self.applyFileDays(cache: &cache, fileDays: migratedCached.days, sign: 1)
        }
        if !uniqueDays.isEmpty {
            Self.applyFileDays(cache: &cache, fileDays: uniqueDays, sign: 1)
        }

        var mergedDays = migratedCached.days
        Self.mergeFileDays(existing: &mergedDays, delta: uniqueDays)
        let modeTokens = Self.codexModeTokenMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns)
        let mergedTokenSnapshots = isBufferedForkResume && startOffset == input.metadata.size
            ? (migratedCached.codexTokenSnapshots ?? [])
            : (migratedCached.codexTokenSnapshots ?? []) + delta.tokenSnapshots
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: mergedDays,
            parsedBytes: delta.parsedBytes,
            lastModel: delta.lastModel,
            lastTotals: delta.lastTotals,
            lastCountedTotals: delta.lastCountedTotals,
            lastRawTotalsBaseline: delta.lastRawTotalsBaseline,
            lastRawTotalsWatermark: delta.lastRawTotalsWatermark,
            seenRawTotals: delta.seenRawTotals,
            hasDivergentTotals: delta.hasDivergentTotals,
            hasInterleavedTotals: delta.hasInterleavedTotals,
            lastCodexTurnID: delta.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: codexSession.forkedFromId ?? delta.forkedFromId ?? migratedCached.forkedFromId,
            // A buffered fork replay can discover that its previous dependency is no longer
            // usable while the replacement parent is still queued for this refresh. Preserve
            // that nil so the post-parent retry runs; retaining the old missing-parent key would
            // incorrectly mark the child reusable and leave its buffered usage unpublished.
            forkBaselineDependencyKey: isBufferedForkResume
                ? forkBaselineDependencyKey
                : forkBaselineDependencyKey ?? migratedCached.forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexSession: codexSession.isEmpty ? nil : codexSession,
            codexCostNanos: Self.codexMergedCostMap(
                migratedCached.codexCostNanos,
                deltaRows: uniqueRows,
                context: context),
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: Self.mergeIntMaps(
                migratedCached.codexStandardTokens,
                modeTokens.standard),
            codexPriorityTokens: Self.mergeIntMaps(
                migratedCached.codexPriorityTokens,
                modeTokens.priority),
            codexTurnIDs: Self.mergeCodexTurnIDs(migratedCached.codexTurnIDs, rows: uniqueRows),
            codexRows: Self.mergeCodexRows(
                retainedCachedRows,
                rows: classifiedUniqueRows,
                sessionId: sessionId),
            codexTokenSnapshots: mergedTokenSnapshots,
            codexTokenCheckpoints: isBufferedForkResume && startOffset == input.metadata.size
                ? migratedCached.codexTokenCheckpoints
                : Self.appendingCodexTokenCheckpoints(
                    delta.tokenSnapshots,
                    to: migratedCached.codexTokenCheckpoints ?? [],
                    startingEventIndex: migratedCached.codexTokenSnapshots?.count ?? 0,
                    initialState: initialAccumulatorState),
            codexTokenTimestampsMonotonic: Self.codexTokenTimestampsAreMonotonic(mergedTokenSnapshots),
            codexTokenIndexAnchor: Self.codexTokenIndexAnchor(
                fileURL: input.fileURL,
                indexedBytes: delta.parsedBytes),
            codexScanFileId: input.metadata.fileId,
            codexScanTargetSize: input.metadata.size,
            codexScanComplete: delta.parsedBytes >= input.metadata.size && delta.jsonlResumeState == nil,
            codexJSONLResumeState: delta.jsonlResumeState,
            codexBufferedSubagentLines: delta.bufferedSubagentLines,
            codexBufferedUnresolvedForkLines: delta.bufferedUnresolvedForkLines)
            .refreshingCodexWorkspaceUsageFingerprint()
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: sessionId, days: mergedDays),
            rows: uniqueRows,
            context: context,
            state: &state)
        return true
    }

    static func rescanCodexFile(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws
    {
        try context.checkCancellation?()
        if let cached = input.cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        let migratedCached = input.cached.map { Self.codexFileUsageWithPricingMetadata($0, context: context) }
        var usageDays = context.dropDeferredCodexRows
            ? [:]
            : Self.fileDaysOutsideScanWindow(migratedCached?.days ?? [:], range: context.range)

        let parsed = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            maxBytesToRead: maxBytesToRead,
            shouldStopReading: context.scanBudget.map { budget in
                { bytesRead in budget.shouldYield(additionalBytes: bytesRead) }
            },
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation)
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: parsed.forkedFromId,
            dependsOnParentTotals: parsed.dependsOnParentTotals,
            inheritedResolver: context.resources.inheritedResolver)
        let cachedSessionMetadata = input.cached?.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: input.cached?.sessionId,
            forkedFromId: input.cached?.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let parsedCodexSession = cachedSessionMetadata.merging(parsed.codexSession)
        let sessionId = parsedCodexSession.sessionId ?? parsed.sessionId ?? input.cached?.sessionId
        let projectPath = parsed.projectPath ?? input.cached?.projectPath
        let canonicalProjectPath = parsed.projectPath.map {
            context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? input.cached?.canonicalProjectPath ?? context.resources.projectPathResolver
            .canonicalProjectPath(for: projectPath)
        let uniqueRows = Self.uniqueCodexRows(
            rows: parsed.rows,
            sessionId: sessionId,
            fileIdentity: input.metadata.path,
            state: &state)
        context.workRecorder?.record(processed: uniqueRows.count, repriced: uniqueRows.count)
        if let sessionId,
           state.contributingSessionIds.contains(sessionId),
           uniqueRows.isEmpty,
           usageDays.isEmpty,
           parsed.bufferedSubagentLines == nil,
           parsed.bufferedUnresolvedForkLines == nil
        {
            cache.files.removeValue(forKey: input.metadata.path)
            return
        }
        let uniqueDays = Self.codexFileDays(rows: uniqueRows)
        Self.mergeFileDays(existing: &usageDays, delta: uniqueDays)
        let modeTokens = Self.codexModeTokenMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns)

        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: usageDays,
            parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel,
            lastTotals: parsed.lastTotals,
            lastCountedTotals: parsed.lastCountedTotals,
            lastRawTotalsBaseline: parsed.lastRawTotalsBaseline,
            lastRawTotalsWatermark: parsed.lastRawTotalsWatermark,
            seenRawTotals: parsed.seenRawTotals,
            hasDivergentTotals: parsed.hasDivergentTotals,
            hasInterleavedTotals: parsed.hasInterleavedTotals,
            lastCodexTurnID: parsed.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: parsedCodexSession.forkedFromId ?? parsed.forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexSession: parsedCodexSession.isEmpty ? nil : parsedCodexSession,
            codexCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexCostNanos, range: context.range),
                Self.codexCostNanos(rows: uniqueRows, range: context.range)),
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexStandardTokens, range: context.range),
                modeTokens.standard),
            codexPriorityTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexPriorityTokens, range: context.range),
                modeTokens.priority),
            codexTurnIDs: context.dropDeferredCodexRows
                ? Self.codexTurnIDs(rows: uniqueRows)
                : Self.mergeCodexTurnIDs(migratedCached?.codexTurnIDs, rows: uniqueRows),
            codexRows: Self.codexRowsWithPricingMetadata(
                context.dropDeferredCodexRows
                    ? uniqueRows
                    : Self.mergeCodexRows(
                        migratedCached?.codexRows,
                        rows: uniqueRows,
                        sessionId: sessionId) ?? [],
                priorityTurns: context.resources.priorityTurns),
            codexTokenSnapshots: parsed.tokenSnapshots,
            codexTokenCheckpoints: Self.codexTokenCheckpoints(for: parsed.tokenSnapshots),
            codexTokenTimestampsMonotonic: Self.codexTokenTimestampsAreMonotonic(parsed.tokenSnapshots),
            codexTokenIndexAnchor: Self.codexTokenIndexAnchor(
                fileURL: input.fileURL,
                indexedBytes: parsed.parsedBytes),
            codexScanFileId: input.metadata.fileId,
            codexScanTargetSize: input.metadata.size,
            codexScanComplete: parsed.parsedBytes >= input.metadata.size && parsed.jsonlResumeState == nil,
            codexJSONLResumeState: parsed.jsonlResumeState,
            codexBufferedSubagentLines: parsed.bufferedSubagentLines,
            codexBufferedUnresolvedForkLines: parsed.bufferedUnresolvedForkLines)
            .refreshingCodexWorkspaceUsageFingerprint()
        Self.applyFileDays(cache: &cache, fileDays: cache.files[input.metadata.path]?.days ?? [:], sign: 1)
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: sessionId, days: usageDays),
            rows: uniqueRows,
            context: context,
            state: &state)
    }

    static func codexForkBaselineDependencyKey(
        parentSessionId: String?,
        dependsOnParentTotals: Bool,
        inheritedResolver: CodexInheritedTotalsResolver) -> String?
    {
        guard let parentSessionId else { return nil }
        guard dependsOnParentTotals else { return Self.codexForkDependencyNotRequiredKey }

        // A nil key means the parent changed while its snapshots were read (or no stable
        // snapshot was resolved). Preserve nil so the child cannot be reused on the next scan.
        return inheritedResolver.dependencyKeyUsed(for: parentSessionId)
    }

    static func mergeFileDays(
        existing: inout [String: [String: [Int]]],
        delta: [String: [String: [Int]]])
    {
        for (day, models) in delta {
            var dayModels = existing[day] ?? [:]
            for (model, packed) in models {
                let existingPacked = dayModels[model] ?? []
                let merged = self.addPacked(a: existingPacked, b: packed, sign: 1)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                existing.removeValue(forKey: day)
            } else {
                existing[day] = dayModels
            }
        }
    }

    static func fileDaysOutsideScanWindow(
        _ days: [String: [String: [Int]]],
        range: CostUsageDayRange) -> [String: [String: [Int]]]
    {
        days.filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
    }

    static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
        for (day, models) in fileDays {
            var dayModels = cache.days[day] ?? [:]
            for (model, packed) in models {
                let existing = dayModels[model] ?? []
                let merged = self.addPacked(a: existing, b: packed, sign: sign)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                cache.days.removeValue(forKey: day)
            } else {
                cache.days[day] = dayModels
            }
        }
    }

    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func pruneForceRescanFilesOutsideWindow(
        cache: inout CostUsageCache,
        range: CostUsageDayRange,
        isForceRescan: Bool)
    {
        guard isForceRescan else { return }
        for key in cache.files.keys {
            guard let old = cache.files[key] else { continue }
            guard !old.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey,
                calendar: range.calendar)
            else { continue }
            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
            cache.files.removeValue(forKey: key)
        }
    }

    static func requestedWindowExpandsCache(range: CostUsageDayRange, cache: CostUsageCache) -> Bool {
        guard let cachedSince = cache.scanSinceKey,
              let cachedUntil = cache.scanUntilKey
        else {
            return cache.lastScanUnixMs != 0 || !cache.files.isEmpty || !cache.days.isEmpty
        }
        return range.scanSinceKey < cachedSince || range.scanUntilKey > cachedUntil
    }

    static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
        let len = max(a.count, b.count)
        var out: [Int] = Array(repeating: 0, count: len)
        for idx in 0..<len {
            let next = (a[safe: idx] ?? 0) + sign * (b[safe: idx] ?? 0)
            out[idx] = max(0, next)
        }
        return out
    }

    static func buildCodexReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> CostUsageDailyReport
    {
        let catalogResolver = CodexModelsDevCatalogResolver(
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        var reportCache = cache
        for (path, usage) in cache.files where self.needsCodexPricingMetadata(usage, range: range) {
            reportCache.files[path] = self.codexFileUsageWithPricingMetadata(
                usage,
                range: range,
                priorityTurns: priorityTurns)
        }
        var entries: [CostUsageDailyReport.Entry] = []
        var (totalInput, totalCacheRead, totalOutput, totalReasoning, totalTokens) = (0, 0, 0, 0, 0)
        var (totalCost, costSeen) = (0.0, false)

        let unmeteredByDay = Self.unresolvedForkUnmeteredCounts(cache: reportCache, range: range)
        let dayKeys = Array(Set(self.codexReportDayKeys(cache: reportCache, range: range) + unmeteredByDay.keys))
            .sorted()
            .filter {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
            }
        let catalog = catalogResolver.load(modelsDevCatalogLoader)
        var pricing = CodexReportDayPricingContext(
            rowsByDayModel: [:],
            unresolvedRowGroups: [],
            modeOwnershipMismatchGroups: [],
            priorityEvidenceGroups: [],
            incompletePricingEvidenceGroups: [],
            authoritativeCostEvidenceGroups: [],
            priorityTurns: priorityTurns,
            modelsDevCatalog: catalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: CostUsagePricing.customPricingOverlay())
        for usage in reportCache.files.values {
            let reconciled = self.codexCanonicalPricingRows(usage)
            pricing.unresolvedRowGroups.formUnion(reconciled.unresolvedGroups)
            let modeEvidence = self.codexPricingModeEvidence(
                usage: usage,
                reconciledRows: reconciled.rows,
                range: range,
                priorityTurns: priorityTurns)
            pricing.modeOwnershipMismatchGroups.formUnion(modeEvidence.mismatchGroups)
            pricing.priorityEvidenceGroups.formUnion(modeEvidence.priorityGroups)
            pricing.incompletePricingEvidenceGroups.formUnion(self.codexIncompletePricingEvidenceGroups(
                usage: usage,
                range: range,
                priorityTurns: priorityTurns,
                modelsDevCatalog: catalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: pricing.customPricing))
            for row in usage.codexRows ?? [] where (row.knownCostNanos ?? 0) != 0 {
                pricing.authoritativeCostEvidenceGroups.insert(CodexDayModelKey(day: row.day, model: row.model))
            }
            for row in reconciled.rows
                where CostUsageDayRange.isInRange(
                    dayKey: row.day,
                    since: range.sinceKey,
                    until: range.untilKey)
                && OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: row.model)
            {
                pricing.rowsByDayModel[row.day, default: [:]][row.model, default: []].append(row)
            }
        }

        for day in dayKeys {
            let unmetered = unmeteredByDay[day] ?? 0
            guard let models = reportCache.days[day] else {
                if let entry = Self.unmeteredForkReportEntry(day: day, unmetered: unmetered) {
                    entries.append(entry)
                }
                continue
            }
            guard let entry = Self.makeCodexBilledDayEntry(
                day: day,
                models: models,
                unmetered: unmetered,
                pricing: pricing)
            else { continue }
            entries.append(entry)
            totalInput += entry.inputTokens ?? 0
            totalCacheRead += entry.cacheReadTokens ?? 0
            totalOutput += entry.outputTokens ?? 0
            totalReasoning += entry.reasoningTokens ?? 0
            totalTokens += entry.totalTokens ?? 0
            if let entryCost = entry.costUSD {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead > 0 ? totalCacheRead : nil,
                reasoningTokens: totalReasoning > 0 ? totalReasoning : nil,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            if lhs.modelName != rhs.modelName {
                return lhs.modelName > rhs.modelName
            }
            let lhsAttribution = lhs.attribution?.deterministicSortKey ?? ""
            let rhsAttribution = rhs.attribution?.deterministicSortKey ?? ""
            return lhsAttribution > rhsAttribution
        }
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }

        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }
}

extension Data {
    func containsAscii(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        return self.range(of: n) != nil
    }
}

extension [Int] {
    subscript(safe index: Int) -> Int? {
        if index < 0 {
            return nil
        }
        if index >= self.count {
            return nil
        }
        return self[index]
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        if index < 0 {
            return nil
        }
        if index >= self.count {
            return nil
        }
        return self[index]
    }
}

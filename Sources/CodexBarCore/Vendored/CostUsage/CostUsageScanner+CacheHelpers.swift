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
            if let catalog { return catalog }
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

    static func codexPrioritySurchargeNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPrioritySurchargeNanos }
    }

    static func codexStandardCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexStandardCostNanos }
    }

    static func codexPriorityCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPriorityCostNanos }
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

    static func codexRowsCostUSD(
        rows: [CodexUsageRow],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            guard let cost = CostUsagePricing.codexCostUSD(
                model: row.model,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            else { continue }
            total += cost
            seen = true
        }
        return seen ? total : nil
    }

    static func codexPrioritySurchargeUSD(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            guard let turnID = row.turnID, let priorityMetadata = priorityTurns[turnID] else { continue }
            let pricedModel = Self.codexPriorityPricingModel(for: row, priorityMetadata: priorityMetadata)
            guard let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot),
                let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                    model: pricedModel,
                    inputTokens: row.input,
                    cachedInputTokens: row.cached,
                    outputTokens: row.output)
            else { continue }
            total += max(priorityCost - baseCost, 0)
            seen = true
        }
        return seen ? total : nil
    }

    private static func codexPriorityPricingModel(
        for row: CodexUsageRow,
        priorityMetadata: CodexPriorityTurnMetadata) -> String
    {
        guard let model = priorityMetadata.model,
              CostUsagePricing.codexPriorityCostUSD(
                  model: model,
                  inputTokens: row.input,
                  cachedInputTokens: row.cached,
                  outputTokens: row.output) != nil
        else { return row.model }
        return model
    }

    struct CodexRowCostBreakdown {
        var standardCostUSD: Double = 0
        var priorityCostUSD: Double = 0
        var standardTokens: Int = 0
        var priorityTokens: Int = 0
        var sawStandardCost = false
        var sawPriorityCost = false

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
    }

    static func codexRowCostBreakdown(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CodexRowCostBreakdown
    {
        var breakdown = CodexRowCostBreakdown()
        for row in rows {
            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil
            if isPriority {
                breakdown.priorityTokens += tokenCount
            } else {
                breakdown.standardTokens += tokenCount
            }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output)
            {
                breakdown.priorityCostUSD += max(priorityCost, baseCost ?? priorityCost)
                breakdown.sawPriorityCost = true
            } else if isPriority, let baseCost {
                breakdown.priorityCostUSD += baseCost
                breakdown.sawPriorityCost = true
            } else if let baseCost {
                breakdown.standardCostUSD += baseCost
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
        hasDivergentTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        projectPath: String? = nil,
        canonicalProjectPath: String? = nil,
        codexCostCacheComplete: Bool? = true,
        codexCostNanos: [String: [String: Int64]]? = nil,
        codexPrioritySurchargeNanos: [String: [String: Int64]]? = nil,
        codexStandardCostNanos: [String: [String: Int64]]? = nil,
        codexPriorityCostNanos: [String: [String: Int64]]? = nil,
        codexStandardTokens: [String: [String: Int]]? = nil,
        codexPriorityTokens: [String: [String: Int]]? = nil,
        codexTurnIDs: [String]? = nil,
        codexRows: [CodexUsageRow]? = nil,
        claudeRows: [ClaudeUsageRow]? = nil) -> CostUsageFileUsage
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
            hasDivergentTotals: hasDivergentTotals,
            lastCodexTurnID: lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostCacheComplete: codexCostCacheComplete,
            codexCostNanos: codexCostNanos,
            codexPrioritySurchargeNanos: codexPrioritySurchargeNanos,
            codexStandardCostNanos: codexStandardCostNanos,
            codexPriorityCostNanos: codexPriorityCostNanos,
            codexStandardTokens: codexStandardTokens,
            codexPriorityTokens: codexPriorityTokens,
            codexTurnIDs: codexTurnIDs,
            codexRows: codexRows,
            claudeRows: claudeRows)
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage) -> Bool {
        !(usage.codexRows?.isEmpty ?? true)
            && (usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage))
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage, range: CostUsageDayRange) -> Bool {
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

    static func codexFileUsageWithCostCache(
        _ usage: CostUsageFileUsage,
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        self.codexFileUsageWithCostCache(
            usage,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
    }

    static func codexFileUsageWithCostCache(
        _ usage: CostUsageFileUsage,
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CostUsageFileUsage
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

        let splitMaps = Self.codexModeSplitMaps(
            rows: migratedRows,
            range: range,
            priorityTurns: priorityTurns,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        var updated = usage
        updated.codexCostNanos = Self.mergeMissingCostMaps(
            usage.codexCostNanos,
            Self.codexCostNanos(
                rows: migratedRows,
                range: range,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot))
        updated.codexPrioritySurchargeNanos = Self.mergeMissingCostMaps(
            usage.codexPrioritySurchargeNanos,
            Self.codexPrioritySurchargeNanos(
                rows: migratedRows,
                range: range,
                priorityTurns: priorityTurns,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot))
        updated.codexStandardCostNanos = Self.mergeMissingCostMaps(
            usage.codexStandardCostNanos,
            splitMaps.standardCostNanos)
        updated.codexPriorityCostNanos = Self.mergeMissingCostMaps(
            usage.codexPriorityCostNanos,
            splitMaps.priorityCostNanos)
        updated.codexStandardTokens = Self.mergeMissingIntMaps(
            usage.codexStandardTokens,
            splitMaps.standardTokens)
        updated.codexPriorityTokens = Self.mergeMissingIntMaps(
            usage.codexPriorityTokens,
            splitMaps.priorityTokens)
        updated.codexCostCacheComplete = true
        updated.codexTurnIDs = Self.mergeCodexTurnIDs(usage.codexTurnIDs, rows: migratedRows)
        updated.codexRows = rows
        return updated
    }

    static func codexMergedCostMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexCostNanos(
                rows: deltaRows,
                range: context.range,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexMergedPrioritySurchargeMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexPrioritySurchargeNanos(
                rows: deltaRows,
                range: context.range,
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexCostNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let cost = Self.codexRowsCostUSD(
                    rows: rows,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((cost * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexPrioritySurchargeNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        guard !priorityTurns.isEmpty else { return nil }
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let surcharge = Self.codexPrioritySurchargeUSD(
                    rows: rows,
                    priorityTurns: priorityTurns,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((surcharge * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexModeSplitMaps(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> (
        standardCostNanos: [String: [String: Int64]]?,
        priorityCostNanos: [String: [String: Int64]]?,
        standardTokens: [String: [String: Int]]?,
        priorityTokens: [String: [String: Int]]?)
    {
        var standardCostNanos: [String: [String: Int64]] = [:]
        var priorityCostNanos: [String: [String: Int64]] = [:]
        var standardTokens: [String: [String: Int]] = [:]
        var priorityTokens: [String: [String: Int]] = [:]

        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }

            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model
            let isPriority = priorityMetadata != nil

            if isPriority {
                priorityTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            } else {
                standardTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            }

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)

            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output)
            {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (max(priorityCost, baseCost ?? priorityCost) * Self.costScale).rounded())
            } else if isPriority, let baseCost {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            } else if let baseCost {
                standardCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            }
        }

        return (
            standardCostNanos.isEmpty ? nil : standardCostNanos,
            priorityCostNanos.isEmpty ? nil : priorityCostNanos,
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
        let splitMaps = Self.codexModeSplitMaps(
            rows: rows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)

        return Self.makeFileUsage(
            mtimeUnixMs: usage.mtimeUnixMs,
            size: usage.size,
            days: days,
            parsedBytes: usage.parsedBytes,
            lastModel: usage.lastModel,
            lastTotals: usage.lastTotals,
            lastCountedTotals: usage.lastCountedTotals,
            lastRawTotalsBaseline: usage.lastRawTotalsBaseline,
            hasDivergentTotals: usage.hasDivergentTotals,
            lastCodexTurnID: usage.lastCodexTurnID,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            projectPath: usage.projectPath,
            canonicalProjectPath: usage.canonicalProjectPath,
            codexCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexCostNanos, range: context.range),
                Self.codexCostNanos(
                    rows: rows,
                    range: context.range,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexPrioritySurchargeNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexPrioritySurchargeNanos, range: context.range),
                Self.codexPrioritySurchargeNanos(
                    rows: rows,
                    range: context.range,
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexStandardCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexStandardCostNanos, range: context.range),
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexPriorityCostNanos, range: context.range),
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexStandardTokens, range: context.range),
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexPriorityTokens, range: context.range),
                splitMaps.priorityTokens),
            codexTurnIDs: Self.mergeCodexTurnIDs(nil, rows: rows),
            codexRows: rows)
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
        state: inout CodexScanState) -> Bool
    {
        guard let cached = input.cached else { return false }
        let needsSessionId = cached.sessionId == nil
        guard cached.mtimeUnixMs == input.metadata.mtimeUnixMs,
              cached.size == input.metadata.size,
              !needsSessionId,
              !context.forceFullScan
        else { return false }

        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }

        let sessionAlreadyContributed = cached.sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let cachedRows = cached.codexRows ?? []
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
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

        let current = if Self.needsCodexCostCache(cached, range: context.range) {
            Self.codexFileUsageWithCostCache(cached, context: context)
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

    static func appendCodexFileIncrementIfPossible(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        try context.checkCancellation?()
        guard let cached = input.cached, cached.sessionId != nil, !context.forceFullScan else { return false }
        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        let startOffset = cached.parsedBytes ?? cached.size
        let initialCountedTotals = cached.lastCountedTotals ?? cached.lastTotals
        let initialRawTotalsBaseline = cached.lastRawTotalsBaseline ?? cached.lastTotals
        let canIncremental = input.metadata.size > cached.size && startOffset > 0
            && startOffset <= input.metadata.size
            && initialCountedTotals != nil
            && cached.forkedFromId == nil
        guard canIncremental else { return false }

        let delta = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            startOffset: startOffset,
            initialModel: cached.lastModel,
            initialTotals: initialCountedTotals,
            initialRawTotalsBaseline: initialRawTotalsBaseline,
            initialHasDivergentTotals: cached.hasDivergentTotals ?? (cached.lastTotals == nil),
            initialCodexTurnID: cached.lastCodexTurnID,
            initialCodexUsageRowIndex: Self.nextCodexUsageRowIndex(cached.codexRows),
            checkCancellation: context.checkCancellation)
        if delta.forkedFromId != nil {
            return false
        }
        let sessionId = delta.sessionId ?? cached.sessionId
        let projectPath = delta.projectPath ?? cached.projectPath
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

        let migrated = Self.codexFileUsageWithCostCache(cached, context: context)
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
        let splitMaps = Self.codexModeSplitMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: mergedDays,
            parsedBytes: delta.parsedBytes,
            lastModel: delta.lastModel,
            lastTotals: delta.lastTotals,
            lastCountedTotals: delta.lastCountedTotals,
            lastRawTotalsBaseline: delta.lastRawTotalsBaseline,
            hasDivergentTotals: delta.hasDivergentTotals,
            lastCodexTurnID: delta.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: delta.forkedFromId ?? migratedCached.forkedFromId,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostNanos: Self.codexMergedCostMap(
                migratedCached.codexCostNanos,
                deltaRows: uniqueRows,
                context: context),
            codexPrioritySurchargeNanos: Self.codexMergedPrioritySurchargeMap(
                migratedCached.codexPrioritySurchargeNanos,
                deltaRows: uniqueRows,
                context: context),
            codexStandardCostNanos: Self.mergeCostMaps(
                migratedCached.codexStandardCostNanos,
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                migratedCached.codexPriorityCostNanos,
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                migratedCached.codexStandardTokens,
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                migratedCached.codexPriorityTokens,
                splitMaps.priorityTokens),
            codexTurnIDs: Self.mergeCodexTurnIDs(migratedCached.codexTurnIDs, rows: uniqueRows),
            codexRows: Self.mergeCodexRows(retainedCachedRows, rows: uniqueRows, sessionId: sessionId))
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
        state: inout CodexScanState) throws
    {
        try context.checkCancellation?()
        if let cached = input.cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        let migratedCached = input.cached.map { Self.codexFileUsageWithCostCache($0, context: context) }
        var usageDays = context.dropDeferredCodexRows
            ? [:]
            : Self.fileDaysOutsideScanWindow(migratedCached?.days ?? [:], range: context.range)

        let parsed = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation)
        let sessionId = parsed.sessionId ?? input.cached?.sessionId
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
        if let sessionId,
           state.contributingSessionIds.contains(sessionId),
           uniqueRows.isEmpty,
           usageDays.isEmpty
        {
            cache.files.removeValue(forKey: input.metadata.path)
            return
        }
        let uniqueDays = Self.codexFileDays(rows: uniqueRows)
        Self.mergeFileDays(existing: &usageDays, delta: uniqueDays)
        let splitMaps = Self.codexModeSplitMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)

        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: usageDays,
            parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel,
            lastTotals: parsed.lastTotals,
            lastCountedTotals: parsed.lastCountedTotals,
            lastRawTotalsBaseline: parsed.lastRawTotalsBaseline,
            hasDivergentTotals: parsed.hasDivergentTotals,
            lastCodexTurnID: parsed.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: parsed.forkedFromId,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexCostNanos, range: context.range),
                Self.codexCostNanos(
                    rows: uniqueRows,
                    range: context.range,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexPrioritySurchargeNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPrioritySurchargeNanos, range: context.range),
                Self.codexPrioritySurchargeNanos(
                    rows: uniqueRows,
                    range: context.range,
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexStandardCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexStandardCostNanos, range: context.range),
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPriorityCostNanos, range: context.range),
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexStandardTokens, range: context.range),
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexPriorityTokens, range: context.range),
                splitMaps.priorityTokens),
            codexTurnIDs: context.dropDeferredCodexRows
                ? Self.codexTurnIDs(rows: uniqueRows)
                : Self.mergeCodexTurnIDs(migratedCached?.codexTurnIDs, rows: uniqueRows),
            codexRows: context.dropDeferredCodexRows
                ? nil
                : Self.mergeCodexRows(migratedCached?.codexRows, rows: uniqueRows, sessionId: sessionId))
        Self.applyFileDays(cache: &cache, fileDays: cache.files[input.metadata.path]?.days ?? [:], sign: 1)
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: sessionId, days: usageDays),
            rows: uniqueRows,
            context: context,
            state: &state)
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
            guard !old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
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
        for (path, usage) in cache.files where self.needsCodexCostCache(usage, range: range) {
            reportCache.files[path] = self.codexFileUsageWithCostCache(
                usage,
                range: range,
                priorityTurns: priorityTurns,
                modelsDevCatalog: catalogResolver.load(modelsDevCatalogLoader),
                modelsDevCacheRoot: modelsDevCacheRoot)
        }
        var entries: [CostUsageDailyReport.Entry] = []
        var (totalInput, totalCacheRead, totalOutput, totalTokens) = (0, 0, 0, 0)
        var (totalCost, costSeen) = (0.0, false)

        let dayKeys = self.codexReportDayKeys(cache: reportCache, range: range)
        let costNanosByDayModel = self.codexCostNanosByDayModel(cache: reportCache, range: range)
        let prioritySurchargeNanosByDayModel = self.codexPrioritySurchargeNanosByDayModel(
            cache: reportCache,
            range: range)
        let standardCostNanosByDayModel = self.codexStandardCostNanosByDayModel(cache: reportCache, range: range)
        let priorityCostNanosByDayModel = self.codexPriorityCostNanosByDayModel(cache: reportCache, range: range)
        let standardTokensByDayModel = self.codexStandardTokensByDayModel(cache: reportCache, range: range)
        let priorityTokensByDayModel = self.codexPriorityTokensByDayModel(cache: reportCache, range: range)

        for day in dayKeys {
            guard let models = reportCache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayCacheRead = 0
            var dayOutput = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cached = packed[safe: 1] ?? 0
                let output = packed[safe: 2] ?? 0
                let totalTokens = input + output

                dayInput += input
                dayCacheRead += cached
                dayOutput += output

                let cachedBaseCost = costNanosByDayModel[day]?[model].map { Double($0) / Self.costScale }
                let cachedStandardCost = standardCostNanosByDayModel[day]?[model].map {
                    Double($0) / Self.costScale
                }
                let cachedPriorityCost = priorityCostNanosByDayModel[day]?[model].map {
                    Double($0) / Self.costScale
                }
                let cachedStandardTokens = standardTokensByDayModel[day]?[model]
                let cachedPriorityTokens = priorityTokensByDayModel[day]?[model]
                let standardCost = cachedStandardCost
                let priorityCost = cachedPriorityCost
                let splitTotalCost: Double? = if standardCost != nil || priorityCost != nil {
                    (standardCost ?? 0) + (priorityCost ?? 0)
                } else {
                    nil
                }
                var cost = splitTotalCost
                    ?? cachedBaseCost
                    ?? CostUsagePricing.codexCostUSD(
                        model: model,
                        inputTokens: input,
                        cachedInputTokens: cached,
                        outputTokens: output,
                        modelsDevCatalog: catalogResolver.load(modelsDevCatalogLoader),
                        modelsDevCacheRoot: modelsDevCacheRoot)
                if splitTotalCost == nil,
                   let surchargeNanos = prioritySurchargeNanosByDayModel[day]?[model],
                   cachedBaseCost != nil
                {
                    cost = (cost ?? 0) + (Double(surchargeNanos) / Self.costScale)
                }
                let hasModeSplit = priorityCost != nil || cachedPriorityTokens != nil
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: totalTokens,
                        standardCostUSD: hasModeSplit ? standardCost : nil,
                        priorityCostUSD: hasModeSplit ? priorityCost : nil,
                        standardTokens: hasModeSplit ? cachedStandardTokens : nil,
                        priorityTokens: hasModeSplit ? cachedPriorityTokens : nil))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead > 0 ? dayCacheRead : nil,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedModelBreakdowns(breakdown)))

            totalInput += dayInput
            totalCacheRead += dayCacheRead
            totalOutput += dayOutput
            totalTokens += dayTotal
            if let entryCost {
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

            return lhs.modelName > rhs.modelName
        }
    }

    static func parseDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
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
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}

extension CostUsageFileUsage {
    func touchesCodexScanWindow(sinceKey: String, untilKey: String) -> Bool {
        self.days.keys.contains {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }
    }
}

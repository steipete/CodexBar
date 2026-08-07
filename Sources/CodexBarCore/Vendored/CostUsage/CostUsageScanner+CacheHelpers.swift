// swiftlint:disable file_length

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
                    outputTokens: row.output,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
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
              CostUsagePricing.codexAPIFastMultiplier(model: model) != nil
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
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
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
        lastRawTotalsWatermark: CostUsageCodexTotals? = nil,
        seenRawTotals: [CostUsageCodexTotals]? = nil,
        hasDivergentTotals: Bool? = nil,
        hasInterleavedTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        codexForkTimestamp: String? = nil,
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
        codexTokenSidecarState: CostUsageCodexTokenSidecarState? = nil,
        codexUsageRowSidecarState: CostUsageCodexUsageRowSidecarState? = nil,
        codexUsageRowProducerKey: String? = nil,
        codexForkAccountingState: CostUsageCodexForkAccountingState? = nil,
        claudeRows: [ClaudeUsageRow]? = nil,
        codexScanFileId: String? = nil,
        codexScanChangeUnixNs: Int64? = nil,
        codexScanTargetSize: Int64? = nil,
        codexScanComplete: Bool? = nil,
        codexJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        codexBufferedSubagentLines: [CodexBufferedFastLine]? = nil,
        codexSubagentResumeState: CostUsageCodexSubagentResumeState? = nil,
        codexDeferredReplayState: CostUsageCodexDeferredReplayState? = nil,
        codexBufferedUnresolvedForkLines: [CodexBufferedFastLine]? = nil,
        codexDeferredForkScan: Bool? = nil) -> CostUsageFileUsage
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
            codexForkTimestamp: codexForkTimestamp,
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
            codexTokenSidecarState: codexTokenSidecarState,
            codexUsageRowSidecarState: codexUsageRowSidecarState,
            codexUsageRowProducerKey: codexUsageRowProducerKey,
            codexForkAccountingState: codexForkAccountingState,
            claudeRows: claudeRows,
            codexScanFileId: codexScanFileId,
            codexScanChangeUnixNs: codexScanChangeUnixNs,
            codexScanTargetSize: codexScanTargetSize,
            codexScanComplete: codexScanComplete,
            codexJSONLResumeState: codexJSONLResumeState,
            codexBufferedSubagentLines: codexBufferedSubagentLines,
            codexSubagentResumeState: codexSubagentResumeState,
            codexDeferredReplayState: codexDeferredReplayState,
            codexBufferedUnresolvedForkLines: codexBufferedUnresolvedForkLines,
            codexDeferredForkScan: codexDeferredForkScan)
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
        updated.codexRows = Self.codexRowsWithPricingAudit(
            rows,
            priorityTurns: priorityTurns,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        return updated.refreshingCodexWorkspaceUsageFingerprint()
    }

    static func codexRowsWithPricingAudit(
        _ rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [CodexUsageRow]
    {
        rows.map { row in
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model
            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            let exactCost: Double? = if priorityMetadata != nil,
                                        let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                                            model: pricedModel,
                                            inputTokens: row.input,
                                            cachedInputTokens: row.cached,
                                            outputTokens: row.output,
                                            modelsDevCatalog: modelsDevCatalog,
                                            modelsDevCacheRoot: modelsDevCacheRoot)
            {
                max(priorityCost, baseCost ?? priorityCost)
            } else {
                baseCost
            }
            let totalTokens = max(0, row.input) + max(0, row.output)
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
                knownCostNanos: exactCost.map { Int64(($0 * Self.costScale).rounded()) },
                unpricedTokens: exactCost == nil ? totalTokens : 0,
                pricingModel: pricedModel,
                pricingMode: priorityMetadata == nil ? "standard" : "priority")
        }
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
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
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
        if usage.codexUsageRowSidecarState != nil {
            return false
        }
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
        forkedFromId: String?,
        fileIdentity: String,
        state: inout CodexScanState) -> [CodexUsageRow]
    {
        if self.codexNonForkSourceIsSuppressed(
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            state: state)
        {
            return []
        }
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

    static func codexNonForkSourceIsSuppressed(
        sessionId: String?,
        forkedFromId: String?,
        state: CodexScanState) -> Bool
    {
        guard let sessionId, forkedFromId == nil else { return false }
        return state.authoritativeForkSessionIds.contains(sessionId)
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
            lastRawTotalsWatermark: usage.lastRawTotalsWatermark,
            seenRawTotals: usage.seenRawTotals,
            hasDivergentTotals: usage.hasDivergentTotals,
            hasInterleavedTotals: usage.hasInterleavedTotals,
            lastCodexTurnID: usage.lastCodexTurnID,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            codexForkTimestamp: usage.codexForkTimestamp,
            forkBaselineDependencyKey: usage.forkBaselineDependencyKey,
            projectPath: usage.projectPath,
            canonicalProjectPath: usage.canonicalProjectPath,
            codexSession: usage.codexSession,
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
            codexRows: rows,
            codexTokenSnapshots: usage.codexTokenSnapshots,
            codexTokenCheckpoints: usage.codexTokenCheckpoints,
            codexTokenTimestampsMonotonic: usage.codexTokenTimestampsMonotonic,
            codexTokenIndexAnchor: usage.codexTokenIndexAnchor,
            codexTokenSidecarState: usage.codexTokenSidecarState,
            codexUsageRowSidecarState: usage.codexUsageRowSidecarState,
            codexUsageRowProducerKey: usage.codexUsageRowProducerKey,
            codexForkAccountingState: usage.codexForkAccountingState,
            codexScanFileId: usage.codexScanFileId,
            codexScanChangeUnixNs: usage.codexScanChangeUnixNs,
            codexScanTargetSize: usage.codexScanTargetSize,
            codexScanComplete: usage.codexScanComplete,
            codexJSONLResumeState: usage.codexJSONLResumeState,
            codexBufferedSubagentLines: usage.codexBufferedSubagentLines,
            codexSubagentResumeState: usage.codexSubagentResumeState,
            codexDeferredReplayState: usage.codexDeferredReplayState,
            codexBufferedUnresolvedForkLines: usage.codexBufferedUnresolvedForkLines,
            codexDeferredForkScan: usage.codexDeferredForkScan)
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
        let changeUnixNs: Int64?

        init(
            path: String,
            mtimeUnixMs: Int64,
            size: Int64,
            fileId: String?,
            changeUnixNs: Int64? = nil)
        {
            self.path = path
            self.mtimeUnixMs = mtimeUnixMs
            self.size = size
            self.fileId = fileId
            self.changeUnixNs = changeUnixNs
        }
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
            return CodexFileMetadata(
                path: path,
                mtimeUnixMs: 0,
                size: 0,
                fileId: nil,
                changeUnixNs: nil)
        }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        let changedSeconds = Int64(info.st_ctim.tv_sec)
        let changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        let changedSeconds = Int64(info.st_ctimespec.tv_sec)
        let changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #endif
        let (changedBase, changedOverflow) = changedSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (changeUnixNs, changedAddOverflow) = changedBase.addingReportingOverflow(changedNanoseconds)
        return CodexFileMetadata(
            path: path,
            mtimeUnixMs: modifiedSeconds * 1000 + modifiedNanoseconds / 1_000_000,
            size: Int64(info.st_size),
            fileId: "\(info.st_dev):\(info.st_ino)",
            changeUnixNs: changedOverflow || changedAddOverflow ? nil : changeUnixNs)
    }

    static func codexFileMetadataMatches(
        _ expected: CodexFileMetadata,
        _ actual: CodexFileMetadata) -> Bool
    {
        guard let expectedFileId = expected.fileId else { return false }
        return expected.path == actual.path
            && actual.fileId == expectedFileId
            && expected.mtimeUnixMs == actual.mtimeUnixMs
            && expected.size == actual.size
            && expected.changeUnixNs == actual.changeUnixNs
    }

    struct CodexFileSourceGuard {
        let metadata: CodexFileMetadata
        let prefixAnchor: CostUsageCodexTokenIndexAnchor?
    }

    struct CodexFileSourceObservation {
        let metadata: CodexFileMetadata
        let appended: Bool
    }

    /// Captures an immutable scan target before parsing. The parser is already bounded to this
    /// metadata size; the anchor lets a later pure append preserve the verified prefix instead of
    /// discarding a whole slice. Codex session writers are append-only; same-size stamp changes,
    /// truncation, replacement, and anchor changes remain invalid source mutations.
    static func codexFileSourceGuard(
        input: CodexFileScanInput) -> CodexFileSourceGuard?
    {
        guard self.codexFileMetadataMatches(
            input.metadata,
            self.codexFileMetadata(fileURL: input.fileURL))
        else { return nil }
        let prefixAnchor: CostUsageCodexTokenIndexAnchor?
        if input.metadata.size > 0 {
            guard let anchor = Self.codexTokenIndexAnchor(
                fileURL: input.fileURL,
                indexedBytes: input.metadata.size)
            else { return nil }
            prefixAnchor = anchor
        } else {
            prefixAnchor = nil
        }
        guard Self.codexFileMetadataMatches(
            input.metadata,
            Self.codexFileMetadata(fileURL: input.fileURL))
        else { return nil }
        return CodexFileSourceGuard(metadata: input.metadata, prefixAnchor: prefixAnchor)
    }

    static func observeCodexFileSource(
        sourceGuard: CodexFileSourceGuard,
        fileURL: URL) -> CodexFileSourceObservation?
    {
        let actual = Self.codexFileMetadata(fileURL: fileURL)
        if Self.codexFileMetadataMatches(sourceGuard.metadata, actual) {
            return CodexFileSourceObservation(metadata: actual, appended: false)
        }
        guard let expectedFileId = sourceGuard.metadata.fileId,
              actual.path == sourceGuard.metadata.path,
              actual.fileId == expectedFileId,
              actual.size > sourceGuard.metadata.size,
              let prefixAnchor = sourceGuard.prefixAnchor,
              prefixAnchor.indexedBytes <= sourceGuard.metadata.size,
              Self.codexTokenIndexAnchorMatches(
                  prefixAnchor,
                  fileURL: fileURL,
                  metadata: actual)
        else { return nil }
        return CodexFileSourceObservation(metadata: actual, appended: true)
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

    /// Binds an effective-row projection to the complete set of physical sources that can
    /// contribute the same logical session. A filtered projection can be reused without touching
    /// JSONL while this signature is stable; a deleted, replaced, appended, or newly classified
    /// sibling changes it and forces the rare reconciliation path.
    static func codexUsageRowOwnershipKey(
        sessionId: String?,
        forkedFromId: String?,
        input: CodexFileScanInput,
        cache: CostUsageCache) -> String?
    {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        var descriptors: Set<String> = []
        for (path, usage) in cache.files where path != input.metadata.path && usage.sessionId == sessionId {
            let metadata = Self.codexFileMetadata(fileURL: URL(fileURLWithPath: path))
            guard let fileId = metadata.fileId else { continue }
            descriptors.insert([
                fileId,
                String(metadata.size),
                String(metadata.mtimeUnixMs),
                String(metadata.changeUnixNs ?? -1),
                usage.forkedFromId ?? "independent",
            ].joined(separator: "\u{1F}"))
        }
        guard let currentFileId = input.metadata.fileId else { return nil }
        descriptors.insert([
            currentFileId,
            String(input.metadata.size),
            String(input.metadata.mtimeUnixMs),
            String(input.metadata.changeUnixNs ?? -1),
            forkedFromId ?? "independent",
        ].joined(separator: "\u{1F}"))
        let payload = descriptors.sorted().joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "ownership:v1:\(sessionId):\(digest)"
    }

    static func codexUsageRowOwnershipIsCurrent(
        cached: CostUsageFileUsage,
        input: CodexFileScanInput,
        cache: CostUsageCache) -> Bool
    {
        guard let published = cached.codexUsageRowSidecarState?.ownershipKey else { return true }
        return published == Self.codexUsageRowOwnershipKey(
            sessionId: cached.sessionId,
            forkedFromId: cached.forkedFromId,
            input: input,
            cache: cache)
    }

    /// A cache intentionally retains the union of previously requested windows. When a narrower
    /// view appends to an active rollout, parse the suffix against that retained row coverage so a
    /// back-dated event cannot create a hole in the wider published generation.
    static func codexContextRetainingPublishedRowCoverage(
        cached: CostUsageFileUsage?,
        context: CodexFileScanContext) -> CodexFileScanContext
    {
        guard let state = cached?.codexUsageRowSidecarState else { return context }
        let retainedRange = context.range.retainingScanCoverage(
            sinceKey: state.coverageSinceKey,
            untilKey: state.coverageUntilKey)
        guard retainedRange.scanSinceKey != context.range.scanSinceKey
            || retainedRange.scanUntilKey != context.range.scanUntilKey
        else { return context }
        return CodexFileScanContext(
            range: retainedRange,
            forceFullScan: context.forceFullScan,
            dropDeferredCodexRows: context.dropDeferredCodexRows,
            requiresTurnIDCache: context.requiresTurnIDCache,
            changedPriorityTurnIDs: context.changedPriorityTurnIDs,
            resources: context.resources,
            checkCancellation: context.checkCancellation,
            scanBudget: context.scanBudget)
    }

    /// Keeps an already-published cache entry visible after the caller has successfully claimed
    /// fork ownership. Keeping that transaction in its own frame avoids nesting its rollback
    /// snapshot beneath the row-projection temporaries here.
    @inline(never)
    static func retainCachedCodexFileDuringDeferralAfterOwnershipClaim(
        input: CodexFileScanInput,
        cached: CostUsageFileUsage,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState)
    {
        let sessionAlreadyContributed = cached.sessionId.map {
            state.contributingSessionIds.contains($0)
        } ?? false
        guard sessionAlreadyContributed else {
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                rows: cached.codexUsageRowSidecarState == nil ? cached.codexRows ?? [] : [],
                context: context,
                state: &state)
            return
        }

        guard Self.prepareCodexSessionRowIdentity(
            sessionId: cached.sessionId,
            excludingPath: input.metadata.path,
            cache: &cache,
            context: context,
            state: &state)
        else {
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                rows: [],
                context: context,
                state: &state)
            return
        }
        let cachedRows: [CodexUsageRow]
        switch Self.codexUsageRows(
            usage: cached,
            fileURL: input.fileURL,
            context: context)
        {
        case let .ready(rows):
            cachedRows = rows
        case .needsRebuild:
            cache.files[input.metadata.path] = Self.codexUsageRequiringUsageRowIndexRebuild(cached)
            context.scanBudget?.recordPersistenceDeferral()
            return
        case .temporarilyUnavailable:
            context.scanBudget?.recordPersistenceDeferral()
            return
        }
        let uniqueRows = Self.uniqueCodexRows(
            rows: cachedRows,
            sessionId: cached.sessionId,
            forkedFromId: cached.forkedFromId,
            fileIdentity: input.metadata.path,
            state: &state)
        let projected = Self.codexFileUsageByFilteringRows(
            cached,
            rows: uniqueRows,
            context: context)
        guard let filtered = Self.persistingCodexUsageRowProjection(
            projected,
            rows: uniqueRows,
            fileURL: input.fileURL,
            ownershipKey: Self.codexUsageRowOwnershipKey(
                sessionId: cached.sessionId,
                forkedFromId: cached.forkedFromId,
                input: input,
                cache: cache),
            context: context)
        else {
            context.scanBudget?.recordPersistenceDeferral()
            return
        }
        Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        cache.files[input.metadata.path] = filtered
        Self.applyFileDays(cache: &cache, fileDays: filtered.days, sign: 1)
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: filtered.sessionId, days: filtered.days),
            rows: uniqueRows,
            context: context,
            state: &state)
    }

    /// Holds a claim's working cache and state off the caller's stack. Publication is transactional:
    /// the caller-visible values are replaced only after every sidecar projection and row-identity
    /// reconciliation succeeds.
    private final class CodexForkOwnershipClaimTransaction {
        let input: CodexFileScanInput
        let sessionId: String
        let forkedFromId: String?
        let context: CodexFileScanContext
        var cache: CostUsageCache
        var state: CodexScanState
        var nonForkPaths: [String] = []
        var updates: [CodexForkOwnershipClaimUpdate] = []

        init(
            input: CodexFileScanInput,
            sessionId: String,
            forkedFromId: String?,
            context: CodexFileScanContext,
            cache: CostUsageCache,
            state: CodexScanState)
        {
            self.input = input
            self.sessionId = sessionId
            self.forkedFromId = forkedFromId
            self.context = context
            self.cache = cache
            self.state = state
        }
    }

    /// One physical source being removed from the claimed scan window. Intermediate row and usage
    /// values live on the heap so debug builds do not reserve all reconciliation temporaries in the
    /// ownership entry point's frame.
    private final class CodexForkOwnershipClaimUpdate {
        let path: String
        let oldUsage: CostUsageFileUsage
        var retainedRows: [CodexUsageRow]?
        var projectedUsage: CostUsageFileUsage?
        var replacementUsage: CostUsageFileUsage?

        init(path: String, oldUsage: CostUsageFileUsage) {
            self.path = path
            self.oldUsage = oldUsage
        }
    }

    /// A copy can be scanned without fork metadata and interpret inherited totals as new usage.
    /// Once trustworthy fork metadata is available, make that source authoritative for this scan
    /// window in both file orders. Clear non-fork contributions while preserving their cursors,
    /// sidecars, and out-of-window rows; then rebuild row identity for already visited sources.
    @inline(never)
    // swiftlint:disable:next function_parameter_count
    static func claimCodexForkSessionOwnership(
        input: CodexFileScanInput,
        sessionId: String?,
        forkedFromId: String?,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) -> Bool
    {
        guard let sessionId,
              !sessionId.isEmpty,
              forkedFromId?.isEmpty == false
        else { return true }
        let transaction = CodexForkOwnershipClaimTransaction(
            input: input,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            context: context,
            cache: cache,
            state: state)
        guard Self.stageCodexForkOwnershipClaim(transaction),
              Self.publishCodexForkOwnershipClaim(transaction)
        else { return false }
        cache = transaction.cache
        state = transaction.state
        return true
    }

    @inline(never)
    private static func stageCodexForkOwnershipClaim(
        _ transaction: CodexForkOwnershipClaimTransaction) -> Bool
    {
        transaction.nonForkPaths = self.codexNonForkPathsForOwnershipClaim(
            cache: transaction.cache,
            sessionId: transaction.sessionId,
            excludingPath: transaction.input.metadata.path,
            range: transaction.context.range)
        for path in transaction.nonForkPaths {
            guard let earlier = transaction.cache.files[path] else { continue }
            let update = CodexForkOwnershipClaimUpdate(path: path, oldUsage: earlier)
            guard Self.loadCodexForkOwnershipRetainedRows(
                update,
                context: transaction.context),
                Self.projectCodexForkOwnershipUsage(update, context: transaction.context),
                Self.persistCodexForkOwnershipUsage(update, transaction: transaction)
            else { return false }
            transaction.updates.append(update)
        }
        return true
    }

    @inline(never)
    private static func codexNonForkPathsForOwnershipClaim(
        cache: CostUsageCache,
        sessionId: String,
        excludingPath: String,
        range: CostUsageDayRange) -> [String]
    {
        var paths: [String] = []
        for (path, usage) in cache.files {
            guard path != excludingPath,
                  usage.sessionId == sessionId,
                  usage.forkedFromId == nil,
                  Self.codexUsageHasDayInScanRange(usage, range: range)
            else { continue }
            paths.append(path)
        }
        return paths
    }

    @inline(never)
    private static func codexUsageHasDayInScanRange(
        _ usage: CostUsageFileUsage,
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in usage.days.keys where CostUsageDayRange.isInRange(
            dayKey: dayKey,
            since: range.scanSinceKey,
            until: range.scanUntilKey)
        {
            return true
        }
        return false
    }

    @inline(never)
    private static func loadCodexForkOwnershipRetainedRows(
        _ update: CodexForkOwnershipClaimUpdate,
        context: CodexFileScanContext) -> Bool
    {
        switch codexUsageRows(
            usage: update.oldUsage,
            fileURL: URL(fileURLWithPath: update.path),
            context: context)
        {
        case let .ready(rows):
            update.retainedRows = Self.codexRowsOutsideScanRange(rows, range: context.range)
            return true
        case .needsRebuild, .temporarilyUnavailable:
            context.scanBudget?.recordPersistenceDeferral()
            return false
        }
    }

    @inline(never)
    private static func codexRowsOutsideScanRange(
        _ rows: [CodexUsageRow],
        range: CostUsageDayRange) -> [CodexUsageRow]
    {
        var retainedRows: [CodexUsageRow] = []
        retainedRows.reserveCapacity(rows.count)
        for row in rows where !CostUsageDayRange.isInRange(
            dayKey: row.day,
            since: range.scanSinceKey,
            until: range.scanUntilKey)
        {
            retainedRows.append(row)
        }
        return retainedRows
    }

    @inline(never)
    private static func projectCodexForkOwnershipUsage(
        _ update: CodexForkOwnershipClaimUpdate,
        context: CodexFileScanContext) -> Bool
    {
        guard let retainedRows = update.retainedRows else { return false }
        update.projectedUsage = Self.codexFileUsageByFilteringRows(
            update.oldUsage,
            rows: retainedRows,
            context: context)
        return true
    }

    @inline(never)
    private static func persistCodexForkOwnershipUsage(
        _ update: CodexForkOwnershipClaimUpdate,
        transaction: CodexForkOwnershipClaimTransaction) -> Bool
    {
        guard let retainedRows = update.retainedRows,
              let projectedUsage = update.projectedUsage
        else { return false }
        update.replacementUsage = Self.persistingCodexUsageRowProjection(
            projectedUsage,
            rows: retainedRows,
            fileURL: URL(fileURLWithPath: update.path),
            ownershipKey: Self.codexUsageRowOwnershipKey(
                sessionId: transaction.sessionId,
                forkedFromId: transaction.forkedFromId,
                input: transaction.input,
                cache: transaction.cache),
            context: transaction.context)
        guard update.replacementUsage != nil else {
            transaction.context.scanBudget?.recordPersistenceDeferral()
            return false
        }
        update.projectedUsage = nil
        update.retainedRows = nil
        return true
    }

    @inline(never)
    private static func publishCodexForkOwnershipClaim(
        _ transaction: CodexForkOwnershipClaimTransaction) -> Bool
    {
        guard self.applyCodexForkOwnershipUpdates(transaction) else { return false }
        guard !transaction.nonForkPaths.isEmpty else {
            transaction.state.authoritativeForkSessionIds.insert(transaction.sessionId)
            return true
        }
        self.clearCodexUsageRowIdentity(
            sessionId: transaction.sessionId,
            state: &transaction.state)
        guard prepareCodexSessionRowIdentity(
            sessionId: transaction.sessionId,
            excludingPath: transaction.input.metadata.path,
            cache: &transaction.cache,
            context: transaction.context,
            state: &transaction.state)
        else { return false }
        transaction.state.authoritativeForkSessionIds.insert(transaction.sessionId)
        return true
    }

    @inline(never)
    private static func applyCodexForkOwnershipUpdates(
        _ transaction: CodexForkOwnershipClaimTransaction) -> Bool
    {
        for update in transaction.updates {
            guard let replacementUsage = update.replacementUsage else { return false }
            Self.applyFileDays(cache: &transaction.cache, fileDays: update.oldUsage.days, sign: -1)
            transaction.cache.files[update.path] = replacementUsage
            Self.applyFileDays(cache: &transaction.cache, fileDays: replacementUsage.days, sign: 1)
        }
        return true
    }

    @inline(never)
    private static func clearCodexUsageRowIdentity(
        sessionId: String,
        state: inout CodexScanState)
    {
        let sessionPrefix = "session:\(sessionId)\u{1F}"
        var retainedKeys = Set<String>()
        retainedKeys.reserveCapacity(state.seenCodexUsageRowKeys.count)
        for key in state.seenCodexUsageRowKeys where !key.hasPrefix(sessionPrefix) {
            retainedKeys.insert(key)
        }
        state.seenCodexUsageRowKeys = retainedKeys
    }

    private final class CodexCachedReuseRequest {
        let input: CodexFileScanInput
        let context: CodexFileScanContext
        let cached: CostUsageFileUsage

        init(
            input: CodexFileScanInput,
            context: CodexFileScanContext,
            cached: CostUsageFileUsage)
        {
            self.input = input
            self.context = context
            self.cached = cached
        }
    }

    private enum CodexCachedReusePreparation {
        case notApplicable
        case handled
        case ready(CodexCachedReuseRequest)
    }

    /// Cache reuse crosses source validation, an ownership transaction, and row projection.
    /// Keep those phases in sequential frames: Swift debug builds reserve stack for every local
    /// in a function even when the branches are mutually exclusive.
    static func keepCachedCodexFileIfFresh(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        let preparation = Self.prepareCachedCodexFileReuse(
            input: input,
            context: context,
            cache: &cache,
            state: &state)
        switch preparation {
        case .notApplicable:
            return false
        case .handled:
            return true
        case let .ready(request):
            guard Self.claimCachedCodexFileReuseOwnership(
                request,
                cache: &cache,
                state: &state)
            else { return true }
            return try Self.finishCachedCodexFileReuse(
                request,
                cache: &cache,
                state: &state)
        }
    }

    /// Branches mirror the mutually exclusive cache migration and fork-validation states.
    @inline(never)
    private static func prepareCachedCodexFileReuse(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) -> CodexCachedReusePreparation
    {
        guard let cached = input.cached else { return .notApplicable }
        guard !context.resources.inheritedResolver.requiresTokenIndexRebuild(fileURL: input.fileURL)
        else { return .notApplicable }
        // A current-producer nil is authoritative: some valid JSONL files simply contain no
        // session metadata. Compatible predecessor caches still rescan once because their parser
        // may have missed metadata required by the exact-session and parent indexes. Saving that
        // result under the current producer makes subsequent unchanged refreshes metadata-only.
        let needsSessionIdMigration = cached.sessionId == nil
            && cache.producerKey != context.resources.currentProducerKey
        guard let currentFileId = input.metadata.fileId,
              cached.codexScanFileId == currentFileId,
              cached.mtimeUnixMs == input.metadata.mtimeUnixMs,
              cached.size == input.metadata.size,
              cached.codexScanComplete != false,
              cached.codexDeferredReplayState == nil,
              !needsSessionIdMigration,
              !context.forceFullScan
        else { return .notApplicable }

        let indexedBytes = cached.parsedBytes ?? cached.size
        if let cachedChangeUnixNs = cached.codexScanChangeUnixNs,
           let currentChangeUnixNs = input.metadata.changeUnixNs
        {
            guard cachedChangeUnixNs == currentChangeUnixNs else { return .notApplicable }
        } else if indexedBytes > 0 {
            // Older cache artifacts do not carry ctime. Validate their content anchor once while
            // publishing the current stamp; subsequent unchanged refreshes stay metadata-only.
            guard let anchor = cached.codexTokenIndexAnchor,
                  anchor.indexedBytes == indexedBytes,
                  Self.codexTokenIndexAnchorMatches(
                      anchor,
                      fileURL: input.fileURL,
                      metadata: input.metadata)
            else { return .notApplicable }
        }

        let needsPriorityRefresh = Self.cachedCodexFileNeedsPriorityRescan(
            cached,
            fileURL: input.fileURL,
            context: context)
        guard Self.codexUsageRowOwnershipIsCurrent(cached: cached, input: input, cache: cache)
        else { return .notApplicable }
        if needsPriorityRefresh, cached.codexUsageRowSidecarState != nil {
            switch Self.codexUsageRows(
                usage: cached,
                fileURL: input.fileURL,
                context: context)
            {
            case let .ready(rows):
                let pricedRows = Self.pricedCodexUsageRows(rows, context: context)
                let projected = Self.codexFileUsageByFilteringRows(
                    cached,
                    rows: pricedRows,
                    context: context)
                guard let refreshed = Self.persistingCodexUsageRowProjection(
                    projected,
                    rows: pricedRows,
                    fileURL: input.fileURL,
                    ownershipKey: cached.codexUsageRowSidecarState?.ownershipKey,
                    context: context)
                else {
                    context.scanBudget?.recordPersistenceDeferral()
                    Self.rememberScannedCodexFile(
                        input: input,
                        session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                        rows: [],
                        context: context,
                        state: &state)
                    return .handled
                }
                Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
                cache.files[input.metadata.path] = refreshed
                Self.applyFileDays(cache: &cache, fileDays: refreshed.days, sign: 1)
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: refreshed.sessionId, days: refreshed.days),
                    rows: pricedRows,
                    context: context,
                    state: &state)
                return .handled
            case .needsRebuild:
                cache.files[input.metadata.path] = Self.codexUsageRequiringUsageRowIndexRebuild(cached)
                context.scanBudget?.recordPersistenceDeferral()
                return .handled
            case .temporarilyUnavailable:
                context.scanBudget?.recordPersistenceDeferral()
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: [],
                    context: context,
                    state: &state)
                return .handled
            }
        }
        guard !needsPriorityRefresh else { return .notApplicable }
        return .ready(CodexCachedReuseRequest(
            input: input,
            context: context,
            cached: cached))
    }

    @inline(never)
    private static func claimCachedCodexFileReuseOwnership(
        _ request: CodexCachedReuseRequest,
        cache: inout CostUsageCache,
        state: inout CodexScanState) -> Bool
    {
        guard self.claimCodexForkSessionOwnership(
            input: request.input,
            sessionId: request.cached.sessionId,
            forkedFromId: request.cached.forkedFromId,
            context: request.context,
            cache: &cache,
            state: &state)
        else {
            self.rememberScannedCodexFile(
                input: request.input,
                session: CodexScannedSession(
                    id: request.cached.sessionId,
                    days: request.cached.days),
                rows: [],
                context: request.context,
                state: &state)
            return false
        }
        return true
    }

    @inline(never)
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func finishCachedCodexFileReuse(
        _ request: CodexCachedReuseRequest,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        let input = request.input
        let context = request.context
        let cached = request.cached
        let sessionAlreadyContributed = cached.sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let suppressedByAuthoritativeFork = Self.codexNonForkSourceIsSuppressed(
            sessionId: cached.sessionId,
            forkedFromId: cached.forkedFromId,
            state: state)
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        if Self.isValidatedSameSizeBufferedCodexForkCache(
            metadata: input.metadata,
            cached: cached),
            let preparation = try Self.prepareBufferedForkDependency(
                usage: cached,
                inheritedResolver: context.resources.inheritedResolver)
        {
            // A ready buffer still represents unpublished usage. Force the zero-byte append path
            // to replay it even if an older cache accidentally persisted a matching parent key.
            if preparation.isReady {
                return false
            }
            var waiting = cached
            waiting.codexForkTimestamp = preparation.cutoffTimestamp
            waiting.forkBaselineDependencyKey = cached.codexUsageRowSidecarState == nil
                ? preparation.stableDependencyKey
                : cached.forkBaselineDependencyKey
            let current = if Self.needsCodexCostCache(waiting, range: context.range) {
                Self.codexFileUsageWithCostCache(waiting, context: context)
            } else {
                waiting
            }
            let migratedCurrent = Self.migratingCodexTokenIndexForCachedReuse(
                current,
                request: request)
            cache.files[input.metadata.path] = migratedCurrent
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: migratedCurrent.sessionId, days: migratedCurrent.days),
                rows: migratedCurrent.codexRows ?? [],
                context: context,
                state: &state)
            return true
        }
        var reboundForkDependencyKey: String?
        if let parentSessionId = cached.forkedFromId {
            guard let cachedDependencyKey = cached.forkBaselineDependencyKey else { return false }
            if cachedDependencyKey != Self.codexForkDependencyNotRequiredKey {
                guard let currentDependencyKey = try context.resources.inheritedResolver
                    .currentDependencyKey(for: parentSessionId)
                else { return false }
                guard Self.codexResolvedForkDependencyKeysMatch(cachedDependencyKey, currentDependencyKey)
                else { return false }
                reboundForkDependencyKey = currentDependencyKey
            }
        }

        if sessionAlreadyContributed || suppressedByAuthoritativeFork,
           cached.codexUsageRowSidecarState?.ownershipKey != nil,
           Self.codexUsageRowOwnershipIsCurrent(cached: cached, input: input, cache: cache)
        {
            // This generation already represents the deterministic projection over the complete
            // unchanged sibling set. Rebuilding it would load every historical row and publish a
            // fresh UUID on every stable refresh even though neither the bytes nor ownership
            // changed. Later stale/new siblings still materialize row identity lazily via the
            // seen file IDs registered here.
            let migratedCurrent = Self.migratingCodexTokenIndexForCachedReuse(
                cached,
                request: request)
            cache.files[input.metadata.path] = migratedCurrent
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: migratedCurrent.sessionId, days: migratedCurrent.days),
                rows: [],
                context: context,
                state: &state)
            return true
        }

        let needsCachedRows = cached.codexUsageRowSidecarState == nil
            || sessionAlreadyContributed
            || suppressedByAuthoritativeFork
        let cachedRows: [CodexUsageRow]
        if needsCachedRows {
            switch Self.codexUsageRows(
                usage: cached,
                fileURL: input.fileURL,
                context: context)
            {
            case let .ready(rows):
                cachedRows = rows
            case .needsRebuild:
                cache.files[input.metadata.path] = Self.codexUsageRequiringUsageRowIndexRebuild(cached)
                context.scanBudget?.recordPersistenceDeferral()
                return true
            case .temporarilyUnavailable:
                context.scanBudget?.recordPersistenceDeferral()
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: [],
                    context: context,
                    state: &state)
                return true
            }
        } else {
            cachedRows = []
        }

        if sessionAlreadyContributed || suppressedByAuthoritativeFork {
            if sessionAlreadyContributed,
               !Self.prepareCodexSessionRowIdentity(
                   sessionId: cached.sessionId,
                   excludingPath: input.metadata.path,
                   cache: &cache,
                   context: context,
                   state: &state)
            {
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: [],
                    context: context,
                    state: &state)
                return true
            }
            let selectedRows = if suppressedByAuthoritativeFork {
                cachedRows.filter {
                    !CostUsageDayRange.isInRange(
                        dayKey: $0.day,
                        since: context.range.scanSinceKey,
                        until: context.range.scanUntilKey)
                }
            } else {
                Self.uniqueCodexRows(
                    rows: cachedRows,
                    sessionId: cached.sessionId,
                    forkedFromId: cached.forkedFromId,
                    fileIdentity: input.metadata.path,
                    state: &state)
            }
            var projected = Self.codexFileUsageByFilteringRows(
                cached,
                rows: selectedRows,
                context: context)
            if let reboundForkDependencyKey {
                projected.forkBaselineDependencyKey = reboundForkDependencyKey
            }
            guard let filtered = Self.persistingCodexUsageRowProjection(
                projected,
                rows: selectedRows,
                fileURL: input.fileURL,
                ownershipKey: Self.codexUsageRowOwnershipKey(
                    sessionId: cached.sessionId,
                    forkedFromId: cached.forkedFromId,
                    input: input,
                    cache: cache),
                context: context)
            else {
                context.scanBudget?.recordPersistenceDeferral()
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: [],
                    context: context,
                    state: &state)
                return true
            }
            let migratedFiltered = Self.migratingCodexTokenIndexForCachedReuse(
                filtered,
                request: request)
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            cache.files[input.metadata.path] = migratedFiltered
            Self.applyFileDays(cache: &cache, fileDays: migratedFiltered.days, sign: 1)
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: migratedFiltered.days),
                rows: selectedRows,
                context: context,
                state: &state)
            return true
        }

        var current = if Self.needsCodexCostCache(cached, range: context.range) {
            Self.codexFileUsageWithCostCache(cached, context: context)
        } else {
            cached
        }
        if let reboundForkDependencyKey, current.codexUsageRowSidecarState == nil {
            current.forkBaselineDependencyKey = reboundForkDependencyKey
        }
        var migratedCurrent = Self.migratingCodexTokenIndexForCachedReuse(
            current,
            request: request)
        if migratedCurrent.codexUsageRowSidecarState == nil,
           let inlineRows = migratedCurrent.codexRows,
           let rowMigrated = Self.persistingCodexUsageRowProjection(
               migratedCurrent,
               rows: inlineRows,
               fileURL: input.fileURL,
               ownershipKey: nil,
               context: context)
        {
            migratedCurrent = rowMigrated
        }
        cache.files[input.metadata.path] = migratedCurrent
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: migratedCurrent.sessionId, days: migratedCurrent.days),
            rows: cachedRows,
            context: context,
            state: &state)
        return true
    }

    @inline(never)
    private static func migratingCodexTokenIndexForCachedReuse(
        _ usage: CostUsageFileUsage,
        request: CodexCachedReuseRequest) -> CostUsageFileUsage
    {
        var usage = usage
        usage.codexScanChangeUnixNs = request.input.metadata.changeUnixNs
        return Self.migratingInlineCodexTokenIndexIfPossible(
            usage: usage,
            fileURL: request.input.fileURL,
            metadata: request.input.metadata,
            store: request.context.resources.tokenIndexStore)
    }

    static func cachedCodexFileNeedsPriorityRescan(
        _ cached: CostUsageFileUsage,
        fileURL: URL,
        context: CodexFileScanContext) -> Bool
    {
        if let rowState = cached.codexUsageRowSidecarState,
           rowState.priorityMetadataKey != context.resources.priorityMetadataKey
        {
            return true
        }
        if cached.codexUsageRowSidecarState == nil, cached.codexTurnIDs == nil {
            return context.requiresTurnIDCache
        }
        guard !context.changedPriorityTurnIDs.isEmpty else { return false }
        if let turnIDs = cached.codexTurnIDs {
            return !Set(turnIDs).isDisjoint(with: context.changedPriorityTurnIDs)
        }
        guard let reference = Self.codexPublishedUsageRowReference(
            usage: cached,
            fileURL: fileURL,
            context: context)
        else { return true }
        switch context.resources.usageRowStore.pathsContaining(
            turnIDs: context.changedPriorityTurnIDs,
            references: [reference])
        {
        case let .ready(paths):
            return paths.contains(reference.source.path)
        case .needsRebuild, .temporarilyUnavailable:
            // A false negative would leave stale standard/priority attribution published. Let the
            // normal rebuild/deferral machinery fail closed instead.
            return true
        }
    }

    /// Validates a completed buffered fork without reading JSONL. Dependency readiness is checked
    /// separately so a rotated missing-parent key never forces an identical buffer replay.
    static func isValidatedSameSizeBufferedCodexForkCache(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        let startOffset = cached.parsedBytes ?? cached.size
        guard cached.forkedFromId != nil,
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

    /// Replays any compact fork buffer without reading JSONL when the indexed file is unchanged.
    /// This remains safe for subagents because no appended lineage can change their classification.
    static func isValidatedSameSizeBufferedCodexForkRetry(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        self.isValidatedSameSizeBufferedCodexForkCache(metadata: metadata, cached: cached)
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

    /// Resumes an ordinary non-fork only when the cached bytes are still the exact prefix of the
    /// same file. Size growth alone is insufficient: a same-path replacement can be larger and
    /// would otherwise combine rows and token-index state from two different inodes.
    static func isAppendSafeCodexNonForkResume(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        let startOffset = cached.parsedBytes ?? cached.size
        guard cached.codexScanComplete != false,
              cached.forkedFromId == nil,
              cached.codexJSONLResumeState == nil,
              let cachedFileId = cached.codexScanFileId,
              cachedFileId == metadata.fileId,
              startOffset > 0,
              startOffset == cached.size,
              metadata.size > cached.size,
              cached.codexTokenIndexAnchor?.indexedBytes == startOffset
        else { return false }
        return cached.codexTokenIndexAnchor.map {
            Self.codexTokenIndexAnchorMatches(
                $0,
                fileURL: URL(fileURLWithPath: metadata.path),
                metadata: metadata)
        } == true
    }

    /// A protocol ordinal is an immutable local ownership boundary. After its compact semantic
    /// cursor has been published, a grown file can resume at the validated prefix even when the
    /// session is a fork/subagent; later lineage cannot reclassify already-owned bytes.
    static func isAppendSafeCodexOrdinalSubagentResume(
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage) -> Bool
    {
        let startOffset = cached.parsedBytes ?? cached.size
        guard cached.codexScanComplete != false,
              cached.codexSubagentResumeState != nil,
              cached.codexBufferedSubagentLines?.isEmpty != false,
              cached.codexJSONLResumeState == nil,
              let cachedFileId = cached.codexScanFileId,
              cachedFileId == metadata.fileId,
              startOffset > 0,
              startOffset == cached.size,
              metadata.size > cached.size,
              cached.codexTokenIndexAnchor?.indexedBytes == startOffset
        else { return false }
        return cached.codexTokenIndexAnchor.map {
            Self.codexTokenIndexAnchorMatches(
                $0,
                fileURL: URL(fileURLWithPath: metadata.path),
                metadata: metadata)
        } == true
    }

    /// A post-parse publication may reuse cached rows and aggregates only when they came from
    /// the same source and their complete indexed prefix is still present. A matching path (or
    /// even matching size/mtime) is not identity: atomic replacement keeps the path while
    /// changing the inode, and an in-place rewrite can keep the inode while changing the prefix.
    /// Forks and grown files are also excluded: a later lineage/subagent boundary can change the
    /// attribution of the old prefix, which makes retaining its out-of-window rows unsound.
    static func codexCachedUsageBelongsToCurrentSource(
        _ cached: CostUsageFileUsage,
        input: CodexFileScanInput) -> Bool
    {
        let indexedBytes = cached.parsedBytes ?? cached.size
        guard let cachedFileId = cached.codexScanFileId,
              cachedFileId == input.metadata.fileId,
              cached.forkedFromId == nil,
              input.metadata.size == cached.size,
              indexedBytes > 0,
              let anchor = cached.codexTokenIndexAnchor,
              anchor.indexedBytes == indexedBytes
        else { return false }
        return Self.codexTokenIndexAnchorMatches(
            anchor,
            fileURL: input.fileURL,
            metadata: input.metadata)
    }

    // swiftlint:disable function_parameter_count
    /// Revalidates the exact parent generation used to normalize a fork immediately before the
    /// child JSON cursor is published. Only a resolved `file|` dependency can affect published
    /// accounting; stable-missing markers contain no normalized rows and may advance normally.
    /// Publication rollback needs the complete before/after scan transaction state.
    static func deferCodexForkPublicationIfDependencyChanged(
        parentSessionId: String?,
        dependsOnParentTotals: Bool,
        dependencyKeyUsed: String?,
        input: CodexFileScanInput,
        cached: CostUsageFileUsage?,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        stateBeforePublication: CodexScanState) throws -> Bool
    {
        guard dependsOnParentTotals,
              let parentSessionId,
              !parentSessionId.isEmpty,
              let dependencyKeyUsed,
              dependencyKeyUsed.hasPrefix("file|")
        else { return false }

        let currentDependencyKey = try context.resources.inheritedResolver
            .currentDependencyKey(for: parentSessionId)
        guard let currentDependencyKey,
              Self.codexResolvedForkDependencyKeysMatch(dependencyKeyUsed, currentDependencyKey)
        else {
            Self.log.info(
                "Codex fork parent changed before child cursor publication; deferring child",
                metadata: [
                    "path": input.metadata.path,
                    "parentSessionId": parentSessionId,
                ])
            // This counter participates in the persisted catch-up decision. A dependency is a
            // source of the child calculation, so use the same transient-mutation lane rather
            // than classifying the condition as a structural sidecar failure.
            context.scanBudget?.recordSourceMutationDeferral()
            state = stateBeforePublication
            if let cached {
                cache.files[input.metadata.path] = cached
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: cached.codexRows ?? [],
                    context: context,
                    state: &state)
            } else if var marker = cache.files[input.metadata.path],
                      marker.codexDeferredForkScan == true
            {
                // A byte-zero ordinary-fork preflight installs an empty marker before parsing.
                // Bind that marker to the now-stale key so the same refresh does not immediately
                // retry and publish after this explicit transient deferral. The next refresh
                // compares it with the new parent key and restarts cleanly.
                marker.forkBaselineDependencyKey = dependencyKeyUsed
                cache.files[input.metadata.path] = marker
            }
            return true
        }
        return false
    }

    // swiftlint:enable function_parameter_count

    private struct CodexAppendFileParseRequest {
        let input: CodexFileScanInput
        let context: CodexFileScanContext
        let cached: CostUsageFileUsage
        let startOffset: Int64
        let sourceGuard: CodexFileSourceGuard
        let scanByteLimit: Int64
        let initialCountedTotals: CostUsageCodexTotals?
        let initialRawTotalsBaseline: CostUsageCodexTotals?
        let initialHasDivergentTotals: Bool
        let ordinaryForkContext: CodexOrdinaryForkResumeContext?
        let ordinalSubagentContext: CodexOrdinalSubagentResumeContext?
        let deferredReplayContext: CodexDeferredReplayContext?
        let isResumablePartial: Bool
        let isBufferedForkResume: Bool
        let isOrdinalSubagentAppendResume: Bool
    }

    private enum CodexAppendFilePreparation {
        case notApplicable
        case handled
        case ready(CodexAppendFileParseRequest)
    }

    /// Keep the parser off the large preflight and publication frames. Swift debug builds reserve
    /// stack for all temporaries in a function, so calling the parser directly from either phase
    /// can overflow the relatively small Swift Testing worker stack even when no data is corrupt.
    static func appendCodexFileIncrementIfPossible(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws -> Bool
    {
        let preparation = try Self.prepareCodexFileIncrement(
            input: input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: maxBytesToRead)
        switch preparation {
        case .notApplicable:
            return false
        case .handled:
            return true
        case let .ready(request):
            let delta = try Self.parsePreparedCodexFileIncrement(request)
            return try Self.publishPreparedCodexFileIncrement(
                request,
                delta: delta,
                cache: &cache,
                state: &state)
        }
    }

    /// The branches preserve explicit resume-safety gates for each cache shape.
    @inline(never)
    // swiftlint:disable:next function_body_length
    private static func prepareCodexFileIncrement(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64?) throws -> CodexAppendFilePreparation
    {
        try context.checkCancellation?()
        let context = Self.codexContextRetainingPublishedRowCoverage(
            cached: input.cached,
            context: context)
        guard let cached = input.cached, !context.forceFullScan else {
            return .notApplicable
        }
        // A bounded current-producer prefix can be authoritative even when the source contains no
        // session metadata. Resume that verified prefix so large metadata-free JSONL files still
        // converge. Compatible predecessor producers must rescan once: their nil may mean that an
        // older parser missed metadata needed by exact-session and parent indexes.
        let canResumeCurrentProducerWithoutSessionId = cached.sessionId == nil
            && cached.codexScanComplete == false
            && cache.producerKey == context.resources.currentProducerKey
        guard cached.sessionId != nil || canResumeCurrentProducerWithoutSessionId else {
            return .notApplicable
        }
        guard cached.codexDeferredForkScan != true else { return .notApplicable }
        if cached.codexDeferredReplayState?.restartIndexingFromByteZero == true {
            return .notApplicable
        }
        if let replay = cached.codexDeferredReplayState,
           replay.phase == .replaying,
           replay.replayStarted != true
        {
            // `parsedBytes` still describes the completed raw-index pass, even if the source has
            // since grown. The first classified pass must start at byte zero; treating the old EOF
            // as a resumable cursor would count only the append and permanently omit history.
            return .notApplicable
        }
        guard !Self.cachedCodexFileNeedsPriorityRescan(
            cached,
            fileURL: input.fileURL,
            context: context)
        else { return .notApplicable }
        guard Self.codexUsageRowOwnershipIsCurrent(cached: cached, input: input, cache: cache)
        else { return .notApplicable }
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return .notApplicable
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
        let isNonForkAppendResume = Self.isAppendSafeCodexNonForkResume(
            metadata: input.metadata,
            cached: cached)
        let isOrdinalSubagentAppendResume = Self.isAppendSafeCodexOrdinalSubagentResume(
            metadata: input.metadata,
            cached: cached)
        if cached.codexScanComplete == false, !isResumablePartial {
            return .notApplicable
        }
        // A non-empty parsed prefix with no snapshots is a legacy or stripped index. Treating it
        // as an empty prefix would persist a suffix-only parent index under a full-prefix anchor.
        // Rebuild once from byte zero instead of silently under-resolving future fork baselines.
        if startOffset > 0,
           cached.codexTokenSnapshots == nil,
           cached.codexTokenSidecarState == nil
        {
            return .notApplicable
        }
        if !isResumablePartial,
           !isBufferedForkResume,
           !isOrdinalSubagentAppendResume,
           try Self.codexFileIsSubagentThread(
               fileURL: input.fileURL,
               checkCancellation: context.checkCancellation)
        {
            return .notApplicable
        }
        let initialCountedTotals = cached.lastCountedTotals ?? cached.lastTotals
        let initialRawTotalsBaseline = cached.lastRawTotalsBaseline ?? cached.lastTotals
        let initialHasDivergentTotals = cached.hasDivergentTotals ?? (cached.lastTotals == nil)
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
                || isOrdinalSubagentAppendResume
                || (isNonForkAppendResume
                    && initialCountedTotals != nil
                    && !hasIncompleteInterleaveState))
        guard canIncremental else { return .notApplicable }

        let ordinalSubagentContext: CodexOrdinalSubagentResumeContext? = if isResumablePartial
            || isOrdinalSubagentAppendResume,
            let resumeState = cached.codexSubagentResumeState
        {
            CodexOrdinalSubagentResumeContext(
                sessionId: cached.sessionId,
                parentSessionId: cached.forkedFromId,
                forkTimestamp: cached.codexForkTimestamp,
                projectPath: cached.projectPath,
                codexSession: cached.codexSession,
                state: resumeState)
        } else {
            nil
        }
        let deferredReplayContext: CodexDeferredReplayContext? = if isResumablePartial,
                                                                    let replayState = cached
                                                                        .codexDeferredReplayState
        {
            CodexDeferredReplayContext(
                sessionId: cached.sessionId,
                parentSessionId: cached.forkedFromId,
                forkTimestamp: cached.codexForkTimestamp,
                projectPath: cached.projectPath,
                codexSession: cached.codexSession,
                state: replayState)
        } else {
            nil
        }
        let ordinaryForkContext: CodexOrdinaryForkResumeContext? = if isResumablePartial,
                                                                      ordinalSubagentContext == nil,
                                                                      deferredReplayContext == nil,
                                                                      let parentSessionId = cached.forkedFromId,
                                                                      let forkTimestamp = cached.codexForkTimestamp,
                                                                      let accountingState = cached
                                                                          .codexForkAccountingState,
                                                                          cached.codexBufferedSubagentLines?
                                                                              .isEmpty != false
        {
            CodexOrdinaryForkResumeContext(
                sessionId: cached.sessionId,
                parentSessionId: parentSessionId,
                forkTimestamp: forkTimestamp,
                projectPath: cached.projectPath,
                codexSession: cached.codexSession,
                accountingState: accountingState)
        } else {
            nil
        }
        // Legacy partial ordinary forks do not carry enough state to distinguish a fully
        // consumed inherited `last` budget from one that was never applied. Rebuild them once.
        if isResumablePartial,
           cached.forkedFromId != nil,
           ordinalSubagentContext == nil,
           deferredReplayContext == nil,
           cached.codexBufferedSubagentLines?.isEmpty != false,
           ordinaryForkContext == nil
        {
            return .notApplicable
        }

        guard let sourceGuard = Self.codexFileSourceGuard(input: input) else {
            context.scanBudget?.recordSourceMutationDeferral()
            cache.files[input.metadata.path] = cached
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                rows: cached.codexRows ?? [],
                context: context,
                state: &state)
            return .handled
        }
        // `input.metadata.size` is this slice's immutable high-water mark. A live writer may
        // append while we parse, but those bytes belong to a later slice and cannot expand this
        // refresh's budget or make completion timing-dependent.
        let remainingAtStart = max(0, input.metadata.size - startOffset)
        let scanByteLimit = min(max(0, maxBytesToRead ?? remainingAtStart), remainingAtStart)
        return .ready(CodexAppendFileParseRequest(
            input: input,
            context: context,
            cached: cached,
            startOffset: startOffset,
            sourceGuard: sourceGuard,
            scanByteLimit: scanByteLimit,
            initialCountedTotals: initialCountedTotals,
            initialRawTotalsBaseline: initialRawTotalsBaseline,
            initialHasDivergentTotals: initialHasDivergentTotals,
            ordinaryForkContext: ordinaryForkContext,
            ordinalSubagentContext: ordinalSubagentContext,
            deferredReplayContext: deferredReplayContext,
            isResumablePartial: isResumablePartial,
            isBufferedForkResume: isBufferedForkResume,
            isOrdinalSubagentAppendResume: isOrdinalSubagentAppendResume))
    }

    /// This thunk intentionally owns no preflight or publication locals while the parser runs.
    @inline(never)
    private static func parsePreparedCodexFileIncrement(
        _ request: CodexAppendFileParseRequest) throws -> CodexParseResult
    {
        let input = request.input
        let context = request.context
        let cached = request.cached
        context.scanBudget?.recordFileParseInvocation()
        let delta = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            startOffset: request.startOffset,
            initialModel: cached.lastModel,
            initialTotals: request.initialCountedTotals,
            initialRawTotalsBaseline: request.initialRawTotalsBaseline,
            initialRawTotalsWatermark: cached.lastRawTotalsWatermark,
            initialSeenRawTotals: cached.seenRawTotals ?? [],
            initialHasDivergentTotals: request.initialHasDivergentTotals,
            initialHasInterleavedTotals: cached.hasInterleavedTotals ?? false,
            initialCodexTurnID: cached.lastCodexTurnID,
            initialCodexUsageRowIndex: cached.codexTokenSidecarState?.nextUsageRowIndex
                ?? cached.codexUsageRowSidecarState?.nextUsageRowIndex
                ?? Self.nextCodexUsageRowIndex(cached.codexRows),
            initialBufferedSubagentLines: cached.codexBufferedSubagentLines,
            initialBufferedUnresolvedForkLines: cached.codexBufferedUnresolvedForkLines,
            initialOrdinaryForkContext: request.ordinaryForkContext,
            initialOrdinalSubagentContext: request.ordinalSubagentContext,
            initialDeferredReplayContext: request.deferredReplayContext,
            initialJSONLResumeState: cached.codexJSONLResumeState,
            maxBytesToRead: request.scanByteLimit,
            shouldStopReading: context.scanBudget.map { budget in
                { bytesRead in budget.shouldYield(additionalBytes: bytesRead) }
            },
            inheritedTotalsResolver: { parentSessionId, cutoffTimestamp in
                try Self.codexInheritedTotalsForParsing(
                    parentSessionId: parentSessionId,
                    cutoffTimestamp: cutoffTimestamp)
                {
                    try context.resources.inheritedResolver.inheritedTotals(
                        for: parentSessionId,
                        atOrBefore: cutoffTimestamp)
                }
            },
            checkCancellation: context.checkCancellation)
        context.scanBudget?.recordUsageRowWork(deltaProcessed: delta.rows.count)
        Self.notifyCodexAfterFileParseForTesting(fileURL: input.fileURL)
        return delta
    }

    private final class CodexAppendPublicationTransaction {
        let request: CodexAppendFileParseRequest
        let delta: CodexParseResult
        var cache: CostUsageCache
        var state: CodexScanState
        var stateBeforeMerge: CodexScanState
        var result = true
        var requestedScanIsComplete = false
        var sourceObservation: CodexFileSourceObservation?
        var tokenIndex: CodexTokenIndexPersistence?
        var scanIsComplete = false
        var migrated: CostUsageFileUsage?
        var codexSession: CostUsageCodexSessionMetadata?
        var sessionId: String?
        var projectPath: String?
        var canonicalProjectPath: String?
        var forkBaselineDependencyKey: String?
        var sourceForkedFromId: String?
        var publishedForkDependencyKey: String?
        var rowSourceSemanticsAreAppendCompatible = false
        var sessionAlreadyContributed = false
        var suppressedByAuthoritativeFork = false
        var needsCachedRows = false
        var appendsUsageRows = false
        var cachedRows: [CodexUsageRow] = []
        var retainedCachedRows: [CodexUsageRow] = []
        var uniqueRows: [CodexUsageRow] = []
        var pricedDeltaRows: [CodexUsageRow] = []
        var replacementPricedRows: [CodexUsageRow] = []
        var migratedCached: CostUsageFileUsage?
        var uniqueDays: [String: [String: [Int]]] = [:]
        var mergedDays: [String: [String: [Int]]] = [:]
        var standardCostNanos: [String: [String: Int64]]?
        var priorityCostNanos: [String: [String: Int64]]?
        var standardTokens: [String: [String: Int]]?
        var priorityTokens: [String: [String: Int]]?
        var codexCostNanos: [String: [String: Int64]]?
        var codexPrioritySurchargeNanos: [String: [String: Int64]]?
        var publishedRowState: CostUsageCodexUsageRowSidecarState?
        var publishedInlineRows: [CodexUsageRow]?
        var publishedTurnIDs: [String]?
        var finalUsage: CostUsageFileUsage?

        init(
            request: CodexAppendFileParseRequest,
            delta: CodexParseResult,
            cache: CostUsageCache,
            state: CodexScanState)
        {
            self.request = request
            self.delta = delta
            self.cache = cache
            self.state = state
            self.stateBeforeMerge = state
        }
    }

    /// Publication deliberately crosses two durable sidecars before the JSON cache can advance.
    /// Keep every large value in a heap transaction, and run validation, reconciliation, and
    /// persistence as sequential frames so Swift Testing's worker stack never contains them all.
    @inline(never)
    private static func publishPreparedCodexFileIncrement(
        _ request: CodexAppendFileParseRequest,
        delta: CodexParseResult,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        let transaction = CodexAppendPublicationTransaction(
            request: request,
            delta: delta,
            cache: cache,
            state: state)
        do {
            let result = try Self.executeCodexAppendPublication(transaction)
            cache = transaction.cache
            state = transaction.state
            return result
        } catch {
            // The former inout implementation exposed any already-completed ownership work when a
            // dependency lookup threw. Preserve that behavior while the sidecars remain ahead of
            // the JSON publication cursor.
            cache = transaction.cache
            state = transaction.state
            throw error
        }
    }

    @inline(never)
    private static func executeCodexAppendPublication(
        _ transaction: CodexAppendPublicationTransaction) throws -> Bool
    {
        guard self.prepareCodexAppendPublicationSource(transaction),
              self.persistCodexAppendPublicationTokenIndex(transaction),
              self.deriveCodexAppendPublicationMetadata(transaction),
              try self.validateCodexAppendPublicationOwnership(transaction),
              self.prepareCodexAppendPublicationRowIdentity(transaction),
              self.loadCodexAppendPublicationCachedRows(transaction),
              self.reconcileCodexAppendPublicationRows(transaction),
              self.priceCodexAppendPublicationRows(transaction),
              self.persistCodexAppendPublicationRows(transaction),
              try self.revalidateCodexAppendPublication(transaction),
              self.computeCodexAppendPublicationAggregates(transaction),
              self.buildCodexAppendPublicationUsage(transaction)
        else { return transaction.result }
        self.commitCodexAppendPublication(transaction)
        return transaction.result
    }

    @inline(never)
    private static func prepareCodexAppendPublicationSource(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        if delta.forkedFromId != nil,
           !request.isResumablePartial,
           !request.isBufferedForkResume,
           !request.isOrdinalSubagentAppendResume,
           request.deferredReplayContext == nil
        {
            transaction.result = false
            return false
        }
        // A transient second parent lookup cannot safely publish a suffix-only cursor.
        if request.ordinaryForkContext != nil, delta.forkAccountingState == nil {
            Self.retainCodexAppendPublicationUsage(
                transaction,
                usage: request.cached,
                remember: true)
            return false
        }
        let parsedSnapshotComplete = delta.parsedBytes >= request.input.metadata.size
            && delta.jsonlResumeState == nil
        guard let sourceObservation = Self.observeCodexFileSource(
            sourceGuard: request.sourceGuard,
            fileURL: request.input.fileURL),
            delta.parsedBytes <= sourceObservation.metadata.size,
            !sourceObservation.appended || !parsedSnapshotComplete
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            Self.retainCodexAppendPublicationUsage(
                transaction,
                usage: request.cached,
                remember: true)
            return false
        }
        transaction.requestedScanIsComplete = parsedSnapshotComplete
        transaction.sourceObservation = sourceObservation
        return true
    }

    @inline(never)
    private static func persistCodexAppendPublicationTokenIndex(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        guard let sourceObservation = transaction.sourceObservation else { return false }
        let reusesUnchangedTokenPrefix = request.isBufferedForkResume
            && request.startOffset == request.input.metadata.size
        let appendedTokenSnapshots = reusesUnchangedTokenPrefix ? [] : delta.tokenSnapshots
        switch Self.appendingCodexTokenIndex(
            cached: request.cached,
            deltaEvents: appendedTokenSnapshots,
            nextUsageRowIndex: delta.nextUsageRowIndex,
            fileURL: request.input.fileURL,
            fileId: sourceObservation.metadata.fileId,
            indexedBytes: delta.parsedBytes,
            isComplete: transaction.requestedScanIsComplete,
            store: request.context.resources.tokenIndexStore)
        {
        case let .persisted(tokenIndex):
            transaction.tokenIndex = tokenIndex
            transaction.scanIsComplete = transaction.requestedScanIsComplete
                && tokenIndex.isComplete
                && delta.deferredReplayState == nil
            return true
        case .retryLater:
            request.context.scanBudget?.recordPersistenceDeferral()
            Self.retainCodexAppendPublicationUsage(
                transaction,
                usage: request.cached,
                remember: true)
            return false
        case .rebuildNextPass:
            request.context.scanBudget?.recordPersistenceDeferral()
            Self.retainCodexAppendPublicationUsage(
                transaction,
                usage: Self.codexUsageRequiringTokenIndexRebuild(request.cached),
                remember: true)
            return false
        }
    }

    @inline(never)
    private static func deriveCodexAppendPublicationMetadata(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        let migrated = Self.codexFileUsageWithCostCache(request.cached, context: request.context)
        let cachedSessionMetadata = migrated.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: migrated.sessionId,
            forkedFromId: migrated.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let codexSession = cachedSessionMetadata.merging(delta.codexSession)
        let sessionId = codexSession.sessionId ?? delta.sessionId ?? request.cached.sessionId
        let projectPath = delta.projectPath ?? request.cached.projectPath
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: delta.forkedFromId,
            dependsOnParentTotals: delta.dependsOnParentTotals,
            inheritedResolver: request.context.resources.inheritedResolver)
        let canonicalProjectPath = delta.projectPath.map {
            request.context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? request.cached.canonicalProjectPath
            ?? request.context.resources.projectPathResolver.canonicalProjectPath(for: projectPath)
        let sourceForkedFromId = codexSession.forkedFromId
            ?? delta.forkedFromId
            ?? request.cached.forkedFromId
        let publishedForkDependencyKey = request.isBufferedForkResume
            ? forkBaselineDependencyKey
            : forkBaselineDependencyKey ?? request.cached.forkBaselineDependencyKey

        transaction.migrated = migrated
        transaction.codexSession = codexSession
        transaction.sessionId = sessionId
        transaction.projectPath = projectPath
        transaction.forkBaselineDependencyKey = forkBaselineDependencyKey
        transaction.canonicalProjectPath = canonicalProjectPath
        transaction.stateBeforeMerge = transaction.state
        transaction.sourceForkedFromId = sourceForkedFromId
        transaction.publishedForkDependencyKey = publishedForkDependencyKey
        transaction.rowSourceSemanticsAreAppendCompatible =
            request.cached.sessionId == sessionId
                && request.cached.forkedFromId == sourceForkedFromId
                && request.cached.forkBaselineDependencyKey == publishedForkDependencyKey
                && (request.cached.codexUsageRowProducerKey
                    ?? request.context.resources.publishedProducerKey)
                == request.context.resources.currentProducerKey
        return true
    }

    @inline(never)
    private static func validateCodexAppendPublicationOwnership(
        _ transaction: CodexAppendPublicationTransaction) throws -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex
        else { return false }
        Self.notifyCodexBeforeFileUsagePublicationForTesting(fileURL: request.input.fileURL)
        let finalSourceGuard = CodexFileSourceGuard(
            metadata: sourceObservation.metadata,
            prefixAnchor: tokenIndex.anchor)
        guard let finalSourceObservation = Self.observeCodexFileSource(
            sourceGuard: finalSourceGuard,
            fileURL: request.input.fileURL),
            finalSourceObservation.metadata.size >= delta.parsedBytes,
            !finalSourceObservation.appended || !tokenIndex.isComplete
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            transaction.state = transaction.stateBeforeMerge
            Self.retainCodexAppendPublicationUsage(
                transaction,
                usage: request.cached,
                remember: true)
            return false
        }
        transaction.sourceObservation = finalSourceObservation
        if finalSourceObservation.appended {
            transaction.scanIsComplete = false
        }
        if try Self.deferCodexForkPublicationIfDependencyChanged(
            parentSessionId: delta.forkedFromId,
            dependsOnParentTotals: delta.dependsOnParentTotals,
            dependencyKeyUsed: transaction.forkBaselineDependencyKey,
            input: request.input,
            cached: request.cached,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state,
            stateBeforePublication: transaction.stateBeforeMerge)
        {
            return false
        }
        guard Self.claimCodexForkSessionOwnership(
            input: request.input,
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state)
        else {
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] = request.cached
            return false
        }
        return true
    }

    @inline(never)
    private static func prepareCodexAppendPublicationRowIdentity(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let sessionAlreadyContributed = transaction.sessionId.map {
            transaction.state.contributingSessionIds.contains($0)
        } ?? false
        let suppressedByAuthoritativeFork = Self.codexNonForkSourceIsSuppressed(
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            state: transaction.state)
        transaction.sessionAlreadyContributed = sessionAlreadyContributed
        transaction.suppressedByAuthoritativeFork = suppressedByAuthoritativeFork
        transaction.needsCachedRows = request.cached.codexUsageRowSidecarState == nil
            || sessionAlreadyContributed
            || suppressedByAuthoritativeFork
            || !transaction.rowSourceSemanticsAreAppendCompatible

        if sessionAlreadyContributed,
           !Self.prepareCodexSessionRowIdentity(
               sessionId: transaction.sessionId,
               excludingPath: request.input.metadata.path,
               cache: &transaction.cache,
               context: request.context,
               state: &transaction.state)
        {
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] = request.cached
            return false
        }
        return true
    }

    @inline(never)
    private static func loadCodexAppendPublicationCachedRows(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        guard transaction.needsCachedRows else {
            transaction.cachedRows = []
            return true
        }
        let request = transaction.request
        switch Self.codexUsageRows(
            usage: request.cached,
            fileURL: request.input.fileURL,
            context: request.context)
        {
        case let .ready(rows):
            transaction.cachedRows = rows
            return true
        case .needsRebuild:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] =
                Self.codexUsageRequiringUsageRowIndexRebuild(request.cached)
            return false
        case .temporarilyUnavailable:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] = request.cached
            return false
        }
    }

    @inline(never)
    private static func reconcileCodexAppendPublicationRows(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let cachedRows = transaction.cachedRows
        if transaction.suppressedByAuthoritativeFork {
            transaction.retainedCachedRows = Self.codexRowsOutsideScanRange(
                cachedRows,
                range: request.context.range)
        } else if transaction.sessionAlreadyContributed {
            transaction.retainedCachedRows = Self.uniqueCodexRows(
                rows: cachedRows,
                sessionId: transaction.sessionId,
                forkedFromId: request.cached.forkedFromId,
                fileIdentity: request.input.metadata.path,
                state: &transaction.state)
        } else {
            Self.rememberCodexRows(
                cachedRows,
                sessionId: transaction.sessionId,
                fileIdentity: request.input.metadata.path,
                state: &transaction.state)
            transaction.retainedCachedRows = cachedRows
        }
        transaction.uniqueRows = Self.uniqueCodexRows(
            rows: transaction.delta.rows,
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            fileIdentity: request.input.metadata.path,
            state: &transaction.state)

        guard let migrated = transaction.migrated else { return false }
        transaction.migratedCached =
            transaction.sessionAlreadyContributed || transaction.suppressedByAuthoritativeFork
                ? Self.codexFileUsageByFilteringRows(
                    migrated,
                    rows: transaction.retainedCachedRows,
                    context: request.context)
                : migrated
        guard let migratedCached = transaction.migratedCached else { return false }
        transaction.uniqueDays = Self.codexFileDays(rows: transaction.uniqueRows)
        transaction.mergedDays = migratedCached.days
        Self.mergeFileDays(
            existing: &transaction.mergedDays,
            delta: transaction.uniqueDays)
        return true
    }

    @inline(never)
    private static func priceCodexAppendPublicationRows(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let splitMaps = Self.codexModeSplitMaps(
            rows: transaction.uniqueRows,
            range: request.context.range,
            priorityTurns: request.context.resources.priorityTurns,
            modelsDevCatalog: request.context.resources.modelsDevCatalog,
            modelsDevCacheRoot: request.context.resources.modelsDevCacheRoot)
        transaction.standardCostNanos = splitMaps.standardCostNanos
        transaction.priorityCostNanos = splitMaps.priorityCostNanos
        transaction.standardTokens = splitMaps.standardTokens
        transaction.priorityTokens = splitMaps.priorityTokens
        transaction.pricedDeltaRows = Self.pricedCodexUsageRows(
            transaction.uniqueRows,
            context: request.context)
        transaction.appendsUsageRows = request.cached.codexUsageRowSidecarState != nil
            && transaction.rowSourceSemanticsAreAppendCompatible
            && !transaction.sessionAlreadyContributed
            && !transaction.suppressedByAuthoritativeFork
        guard !transaction.appendsUsageRows else { return true }
        let mergedRows = Self.mergeCodexRows(
            transaction.retainedCachedRows,
            rows: transaction.uniqueRows,
            sessionId: transaction.sessionId) ?? []
        transaction.replacementPricedRows = Self.pricedCodexUsageRows(
            mergedRows,
            context: request.context)
        return true
    }

    @inline(never)
    private static func persistCodexAppendPublicationRows(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex,
              let codexSession = transaction.codexSession,
              let migratedCached = transaction.migratedCached
        else { return false }
        let forkedFromId = codexSession.forkedFromId
            ?? delta.forkedFromId
            ?? migratedCached.forkedFromId
        let rowPersistence: CodexUsageRowPersistenceOutcome = if transaction.appendsUsageRows {
            Self.appendingCodexUsageRows(
                cached: request.cached,
                deltaRows: transaction.pricedDeltaRows,
                nextUsageRowIndex: delta.nextUsageRowIndex,
                fileURL: request.input.fileURL,
                fileId: sourceObservation.metadata.fileId,
                indexedBytes: delta.parsedBytes,
                anchor: tokenIndex.anchor,
                isComplete: transaction.scanIsComplete,
                changeUnixNs: sourceObservation.metadata.changeUnixNs,
                sessionId: transaction.sessionId,
                forkedFromId: forkedFromId,
                forkDependencyKey: transaction.publishedForkDependencyKey,
                context: request.context)
        } else {
            Self.replacingCodexUsageRows(
                rows: transaction.replacementPricedRows,
                nextUsageRowIndex: delta.nextUsageRowIndex,
                fileURL: request.input.fileURL,
                fileId: sourceObservation.metadata.fileId,
                indexedBytes: delta.parsedBytes,
                anchor: tokenIndex.anchor,
                isComplete: transaction.scanIsComplete,
                changeUnixNs: sourceObservation.metadata.changeUnixNs,
                sessionId: transaction.sessionId,
                forkedFromId: forkedFromId,
                forkDependencyKey: transaction.publishedForkDependencyKey,
                ownershipKey: transaction.sessionAlreadyContributed
                    || transaction.suppressedByAuthoritativeFork
                    ? Self.codexUsageRowOwnershipKey(
                        sessionId: transaction.sessionId,
                        forkedFromId: transaction.sourceForkedFromId,
                        input: request.input,
                        cache: transaction.cache)
                    : nil,
                context: request.context)
        }
        switch rowPersistence {
        case let .persisted(sidecarState):
            transaction.publishedRowState = sidecarState
            transaction.publishedInlineRows = nil
            return true
        case let .inline(rows):
            transaction.publishedRowState = nil
            transaction.publishedInlineRows = rows
            return true
        case .retryLater:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] = request.cached
            return false
        case .rebuildNextPass:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] =
                Self.codexUsageRequiringUsageRowIndexRebuild(request.cached)
            return false
        }
    }

    @inline(never)
    private static func revalidateCodexAppendPublication(
        _ transaction: CodexAppendPublicationTransaction) throws -> Bool
    {
        let request = transaction.request
        let delta = transaction.delta
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex
        else { return false }
        guard Self.observeCodexFileSource(
            sourceGuard: CodexFileSourceGuard(
                metadata: sourceObservation.metadata,
                prefixAnchor: tokenIndex.anchor),
            fileURL: request.input.fileURL) != nil
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            transaction.state = transaction.stateBeforeMerge
            transaction.cache.files[request.input.metadata.path] = request.cached
            return false
        }
        if try Self.deferCodexForkPublicationIfDependencyChanged(
            parentSessionId: delta.forkedFromId,
            dependsOnParentTotals: delta.dependsOnParentTotals,
            dependencyKeyUsed: transaction.forkBaselineDependencyKey,
            input: request.input,
            cached: request.cached,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state,
            stateBeforePublication: transaction.stateBeforeMerge)
        {
            return false
        }
        guard let migratedCached = transaction.migratedCached else { return false }
        if transaction.sessionAlreadyContributed,
           migratedCached.days.isEmpty,
           transaction.uniqueRows.isEmpty,
           !transaction.suppressedByAuthoritativeFork,
           transaction.sourceForkedFromId == nil
        {
            Self.dropCachedCodexFile(
                path: request.input.metadata.path,
                cached: request.cached,
                cache: &transaction.cache)
            return false
        }
        return true
    }

    @inline(never)
    private static func computeCodexAppendPublicationAggregates(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        guard let migratedCached = transaction.migratedCached else { return false }
        let context = transaction.request.context
        transaction.codexCostNanos = Self.codexMergedCostMap(
            migratedCached.codexCostNanos,
            deltaRows: transaction.uniqueRows,
            context: context)
        transaction.codexPrioritySurchargeNanos = Self.codexMergedPrioritySurchargeMap(
            migratedCached.codexPrioritySurchargeNanos,
            deltaRows: transaction.uniqueRows,
            context: context)
        transaction.standardCostNanos = Self.mergeCostMaps(
            migratedCached.codexStandardCostNanos,
            transaction.standardCostNanos)
        transaction.priorityCostNanos = Self.mergeCostMaps(
            migratedCached.codexPriorityCostNanos,
            transaction.priorityCostNanos)
        transaction.standardTokens = Self.mergeIntMaps(
            migratedCached.codexStandardTokens,
            transaction.standardTokens)
        transaction.priorityTokens = Self.mergeIntMaps(
            migratedCached.codexPriorityTokens,
            transaction.priorityTokens)
        transaction.publishedTurnIDs = transaction.publishedRowState == nil
            ? Self.codexTurnIDs(rows: transaction.publishedInlineRows ?? [])
            : nil
        return true
    }

    @inline(never)
    private static func buildCodexAppendPublicationUsage(
        _ transaction: CodexAppendPublicationTransaction) -> Bool
    {
        let delta = transaction.delta
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex,
              let migratedCached = transaction.migratedCached,
              let codexSession = transaction.codexSession
        else { return false }
        transaction.finalUsage = Self.makeFileUsage(
            mtimeUnixMs: sourceObservation.metadata.mtimeUnixMs,
            size: sourceObservation.metadata.size,
            days: transaction.mergedDays,
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
            sessionId: transaction.sessionId,
            forkedFromId: codexSession.forkedFromId
                ?? delta.forkedFromId
                ?? migratedCached.forkedFromId,
            codexForkTimestamp: delta.forkTimestamp ?? migratedCached.codexForkTimestamp,
            forkBaselineDependencyKey: transaction.publishedForkDependencyKey,
            projectPath: transaction.projectPath,
            canonicalProjectPath: transaction.canonicalProjectPath,
            codexSession: codexSession.isEmpty ? nil : codexSession,
            codexCostNanos: transaction.codexCostNanos,
            codexPrioritySurchargeNanos: transaction.codexPrioritySurchargeNanos,
            codexStandardCostNanos: transaction.standardCostNanos,
            codexPriorityCostNanos: transaction.priorityCostNanos,
            codexStandardTokens: transaction.standardTokens,
            codexPriorityTokens: transaction.priorityTokens,
            codexTurnIDs: transaction.publishedTurnIDs,
            codexRows: transaction.publishedInlineRows,
            codexTokenSnapshots: tokenIndex.snapshots,
            codexTokenCheckpoints: tokenIndex.checkpoints,
            codexTokenTimestampsMonotonic: tokenIndex.timestampsMonotonic,
            codexTokenIndexAnchor: tokenIndex.anchor,
            codexTokenSidecarState: tokenIndex.sidecarState,
            codexUsageRowSidecarState: transaction.publishedRowState,
            codexUsageRowProducerKey: transaction.publishedRowState == nil
                ? nil
                : transaction.request.context.resources.currentProducerKey,
            codexForkAccountingState: delta.forkAccountingState,
            codexScanFileId: sourceObservation.metadata.fileId,
            codexScanChangeUnixNs: sourceObservation.metadata.changeUnixNs,
            codexScanTargetSize: sourceObservation.metadata.size,
            codexScanComplete: transaction.scanIsComplete,
            codexJSONLResumeState: delta.jsonlResumeState,
            codexBufferedSubagentLines: delta.bufferedSubagentLines,
            codexSubagentResumeState: delta.subagentResumeState,
            codexDeferredReplayState: delta.deferredReplayState,
            codexBufferedUnresolvedForkLines: delta.bufferedUnresolvedForkLines)
            .refreshingCodexWorkspaceUsageFingerprint()
        return true
    }

    @inline(never)
    private static func commitCodexAppendPublication(
        _ transaction: CodexAppendPublicationTransaction)
    {
        let request = transaction.request
        guard let migratedCached = transaction.migratedCached,
              let finalUsage = transaction.finalUsage
        else { return }
        if transaction.sessionAlreadyContributed || transaction.suppressedByAuthoritativeFork {
            Self.applyFileDays(
                cache: &transaction.cache,
                fileDays: request.cached.days,
                sign: -1)
            Self.applyFileDays(
                cache: &transaction.cache,
                fileDays: migratedCached.days,
                sign: 1)
        }
        if !transaction.uniqueDays.isEmpty {
            Self.applyFileDays(
                cache: &transaction.cache,
                fileDays: transaction.uniqueDays,
                sign: 1)
        }
        transaction.cache.files[request.input.metadata.path] = finalUsage
        Self.rememberScannedCodexFile(
            input: request.input,
            session: CodexScannedSession(
                id: transaction.sessionId,
                days: transaction.mergedDays),
            rows: transaction.uniqueRows,
            context: request.context,
            state: &transaction.state)
    }

    @inline(never)
    private static func retainCodexAppendPublicationUsage(
        _ transaction: CodexAppendPublicationTransaction,
        usage: CostUsageFileUsage,
        remember: Bool)
    {
        let request = transaction.request
        transaction.cache.files[request.input.metadata.path] = usage
        guard remember else { return }
        Self.rememberScannedCodexFile(
            input: request.input,
            session: CodexScannedSession(id: usage.sessionId, days: usage.days),
            rows: usage.codexRows ?? [],
            context: request.context,
            state: &transaction.state)
    }

    private struct CodexRescanFileParseRequest {
        let input: CodexFileScanInput
        let context: CodexFileScanContext
        let retainedCached: CostUsageFileUsage?
        let discardedCachedSourceDetail: Bool
        let preservesLegacyOutsideProjection: Bool
        let usageDays: [String: [String: [Int]]]
        let sourceGuard: CodexFileSourceGuard
        let scanByteLimit: Int64
        let deferredReplayContext: CodexDeferredReplayContext?
    }

    private enum CodexRescanFilePreparation {
        case handled
        case ready(CodexRescanFileParseRequest)
    }

    /// Keep parse, final source validation, and cache publication in one transaction while
    /// ensuring their debug stack frames are sequential rather than nested.
    static func rescanCodexFile(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws
    {
        let preparation = try Self.prepareCodexFileRescan(
            input: input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: maxBytesToRead)
        switch preparation {
        case .handled:
            return
        case let .ready(request):
            let parsed = try Self.parsePreparedCodexFileRescan(request)
            try Self.publishPreparedCodexFileRescan(
                request,
                parsed: parsed,
                cache: &cache,
                state: &state)
        }
    }

    @inline(never)
    private static func prepareCodexFileRescan(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64?) throws -> CodexRescanFilePreparation
    {
        try context.checkCancellation?()
        let context = Self.codexContextRetainingPublishedRowCoverage(
            cached: input.cached,
            context: context)
        let retainedCached = input.cached.flatMap { cached -> CostUsageFileUsage? in
            guard Self.codexCachedUsageBelongsToCurrentSource(cached, input: input) else {
                return nil
            }
            return Self.codexFileUsageWithCostCache(cached, context: context)
        }
        let discardedCachedSourceDetail = input.cached != nil && retainedCached == nil
        // A sidecar generation is tied to one verified byte prefix. Never splice rows from a
        // later old prefix into a bounded byte-zero rebuild: doing so publishes event indexes
        // beyond the new cursor and makes the next pass reset to zero. The previous-report cache
        // keeps the UI stable while this replacement prefix catches up.
        let preservesLegacyOutsideProjection = !context.dropDeferredCodexRows
            && retainedCached?.codexUsageRowSidecarState == nil
        let usageDays = preservesLegacyOutsideProjection
            ? Self.fileDaysOutsideScanWindow(retainedCached?.days ?? [:], range: context.range)
            : [:]

        guard let sourceGuard = Self.codexFileSourceGuard(input: input) else {
            context.scanBudget?.recordSourceMutationDeferral()
            if let cached = input.cached {
                cache.files[input.metadata.path] = cached
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: cached.codexRows ?? [],
                    context: context,
                    state: &state)
            }
            return .handled
        }
        let scanByteLimit = min(
            max(0, maxBytesToRead ?? input.metadata.size),
            max(0, input.metadata.size))

        let deferredReplayContext = input.cached.flatMap { cached in
            cached.codexDeferredReplayState.map { replayState in
                CodexDeferredReplayContext(
                    sessionId: cached.sessionId,
                    parentSessionId: cached.forkedFromId,
                    forkTimestamp: cached.codexForkTimestamp,
                    projectPath: cached.projectPath,
                    codexSession: cached.codexSession,
                    state: replayState)
            }
        }
        return .ready(CodexRescanFileParseRequest(
            input: input,
            context: context,
            retainedCached: retainedCached,
            discardedCachedSourceDetail: discardedCachedSourceDetail,
            preservesLegacyOutsideProjection: preservesLegacyOutsideProjection,
            usageDays: usageDays,
            sourceGuard: sourceGuard,
            scanByteLimit: scanByteLimit,
            deferredReplayContext: deferredReplayContext))
    }

    /// This thunk intentionally owns no preflight or publication locals while the parser runs.
    @inline(never)
    private static func parsePreparedCodexFileRescan(
        _ request: CodexRescanFileParseRequest) throws -> CodexParseResult
    {
        let input = request.input
        let context = request.context
        context.scanBudget?.recordFileParseInvocation()
        let parsed = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            initialDeferredReplayContext: request.deferredReplayContext,
            maxBytesToRead: request.scanByteLimit,
            shouldStopReading: context.scanBudget.map { budget in
                { bytesRead in budget.shouldYield(additionalBytes: bytesRead) }
            },
            inheritedTotalsResolver: { parentSessionId, cutoffTimestamp in
                try Self.codexInheritedTotalsForParsing(
                    parentSessionId: parentSessionId,
                    cutoffTimestamp: cutoffTimestamp)
                {
                    try context.resources.inheritedResolver.inheritedTotals(
                        for: parentSessionId,
                        atOrBefore: cutoffTimestamp)
                }
            },
            checkCancellation: context.checkCancellation)
        context.scanBudget?.recordUsageRowWork(deltaProcessed: parsed.rows.count)
        Self.notifyCodexAfterFileParseForTesting(fileURL: input.fileURL)
        return parsed
    }

    private final class CodexRescanPublicationTransaction {
        let request: CodexRescanFileParseRequest
        let parsed: CodexParseResult
        var cache: CostUsageCache
        var state: CodexScanState
        var stateBeforeMerge: CodexScanState
        var requestedScanIsComplete = false
        var sourceObservation: CodexFileSourceObservation?
        var tokenIndex: CodexTokenIndexPersistence?
        var scanIsComplete = false
        var forkBaselineDependencyKey: String?
        var codexSession: CostUsageCodexSessionMetadata?
        var sessionId: String?
        var sourceForkedFromId: String?
        var projectPath: String?
        var canonicalProjectPath: String?
        var suppressedByAuthoritativeFork = false
        var sessionAlreadyContributed = false
        var usageDays: [String: [String: [Int]]]
        var uniqueRows: [CodexUsageRow] = []
        var uniqueDays: [String: [String: [Int]]] = [:]
        var retainedRows: [CodexUsageRow] = []
        var pricedRows: [CodexUsageRow] = []
        var standardCostNanos: [String: [String: Int64]]?
        var priorityCostNanos: [String: [String: Int64]]?
        var standardTokens: [String: [String: Int]]?
        var priorityTokens: [String: [String: Int]]?
        var codexCostNanos: [String: [String: Int64]]?
        var codexPrioritySurchargeNanos: [String: [String: Int64]]?
        var publishedRowState: CostUsageCodexUsageRowSidecarState?
        var publishedInlineRows: [CodexUsageRow]?
        var publishedTurnIDs: [String]?
        var finalUsage: CostUsageFileUsage?

        init(
            request: CodexRescanFileParseRequest,
            parsed: CodexParseResult,
            cache: CostUsageCache,
            state: CodexScanState)
        {
            self.request = request
            self.parsed = parsed
            self.cache = cache
            self.state = state
            self.stateBeforeMerge = state
            self.usageDays = request.usageDays
        }
    }

    @inline(never)
    private static func publishPreparedCodexFileRescan(
        _ request: CodexRescanFileParseRequest,
        parsed: CodexParseResult,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws
    {
        let transaction = CodexRescanPublicationTransaction(
            request: request,
            parsed: parsed,
            cache: cache,
            state: state)
        do {
            try Self.executeCodexRescanPublication(transaction)
            cache = transaction.cache
            state = transaction.state
        } catch {
            cache = transaction.cache
            state = transaction.state
            throw error
        }
    }

    @inline(never)
    private static func executeCodexRescanPublication(
        _ transaction: CodexRescanPublicationTransaction) throws
    {
        guard self.prepareCodexRescanPublicationSource(transaction),
              self.persistCodexRescanPublicationTokenIndex(transaction),
              self.deriveCodexRescanPublicationMetadata(transaction),
              try self.validateCodexRescanPublicationOwnership(transaction),
              self.prepareCodexRescanPublicationRowIdentity(transaction),
              self.computeCodexRescanPublicationUsageRows(transaction),
              self.loadCodexRescanPublicationRetainedRows(transaction),
              self.priceCodexRescanPublicationRows(transaction),
              self.persistCodexRescanPublicationRows(transaction),
              try self.revalidateCodexRescanPublication(transaction),
              self.computeCodexRescanPublicationAggregates(transaction),
              self.buildCodexRescanPublicationUsage(transaction)
        else { return }
        self.commitCodexRescanPublication(transaction)
    }

    @inline(never)
    private static func prepareCodexRescanPublicationSource(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        let parsedSnapshotComplete = parsed.parsedBytes >= request.input.metadata.size
            && parsed.jsonlResumeState == nil
        guard let sourceObservation = Self.observeCodexFileSource(
            sourceGuard: request.sourceGuard,
            fileURL: request.input.fileURL),
            parsed.parsedBytes <= sourceObservation.metadata.size,
            !sourceObservation.appended || !parsedSnapshotComplete
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            if let cached = request.input.cached {
                Self.retainCodexRescanPublicationUsage(
                    transaction,
                    usage: cached,
                    remember: true)
            }
            return false
        }
        transaction.requestedScanIsComplete = parsedSnapshotComplete
        transaction.sourceObservation = sourceObservation
        return true
    }

    @inline(never)
    private static func persistCodexRescanPublicationTokenIndex(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        guard let sourceObservation = transaction.sourceObservation else { return false }
        let tokenIndex = Self.replacingCodexTokenIndex(
            events: parsed.tokenSnapshots,
            nextUsageRowIndex: parsed.nextUsageRowIndex,
            fileURL: request.input.fileURL,
            fileId: sourceObservation.metadata.fileId,
            indexedBytes: parsed.parsedBytes,
            isComplete: transaction.requestedScanIsComplete,
            store: request.context.resources.tokenIndexStore)
        transaction.tokenIndex = tokenIndex
        transaction.scanIsComplete = transaction.requestedScanIsComplete
            && tokenIndex.isComplete
            && parsed.deferredReplayState == nil
        return true
    }

    @inline(never)
    private static func deriveCodexRescanPublicationMetadata(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: parsed.forkedFromId,
            dependsOnParentTotals: parsed.dependsOnParentTotals,
            inheritedResolver: request.context.resources.inheritedResolver)
        let cachedSessionMetadata = request.retainedCached?.codexSession
            ?? CostUsageCodexSessionMetadata(
                sessionId: request.retainedCached?.sessionId,
                forkedFromId: request.retainedCached?.forkedFromId,
                cwd: nil,
                title: nil,
                startedAtUnixMs: nil,
                latestActivityUnixMs: nil)
        let codexSession = cachedSessionMetadata.merging(parsed.codexSession)
        let sessionId = codexSession.sessionId
            ?? parsed.sessionId
            ?? request.retainedCached?.sessionId
        let projectPath = parsed.projectPath ?? request.retainedCached?.projectPath
        let canonicalProjectPath = parsed.projectPath.map {
            request.context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? request.retainedCached?.canonicalProjectPath
            ?? request.context.resources.projectPathResolver.canonicalProjectPath(for: projectPath)

        transaction.forkBaselineDependencyKey = forkBaselineDependencyKey
        transaction.codexSession = codexSession
        transaction.sessionId = sessionId
        transaction.sourceForkedFromId = codexSession.forkedFromId ?? parsed.forkedFromId
        transaction.projectPath = projectPath
        transaction.canonicalProjectPath = canonicalProjectPath
        transaction.stateBeforeMerge = transaction.state
        return true
    }

    @inline(never)
    private static func validateCodexRescanPublicationOwnership(
        _ transaction: CodexRescanPublicationTransaction) throws -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex
        else { return false }
        Self.notifyCodexBeforeFileUsagePublicationForTesting(fileURL: request.input.fileURL)
        let finalSourceGuard = CodexFileSourceGuard(
            metadata: sourceObservation.metadata,
            prefixAnchor: tokenIndex.anchor)
        guard let finalSourceObservation = Self.observeCodexFileSource(
            sourceGuard: finalSourceGuard,
            fileURL: request.input.fileURL),
            finalSourceObservation.metadata.size >= parsed.parsedBytes,
            !finalSourceObservation.appended || !tokenIndex.isComplete
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                Self.retainCodexRescanPublicationUsage(
                    transaction,
                    usage: cached,
                    remember: true)
            }
            return false
        }
        transaction.sourceObservation = finalSourceObservation
        if finalSourceObservation.appended {
            transaction.scanIsComplete = false
        }
        if try Self.deferCodexForkPublicationIfDependencyChanged(
            parentSessionId: parsed.forkedFromId,
            dependsOnParentTotals: parsed.dependsOnParentTotals,
            dependencyKeyUsed: transaction.forkBaselineDependencyKey,
            input: request.input,
            cached: request.input.cached,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state,
            stateBeforePublication: transaction.stateBeforeMerge)
        {
            return false
        }
        guard Self.claimCodexForkSessionOwnership(
            input: request.input,
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state)
        else {
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] = cached
            }
            return false
        }
        return true
    }

    @inline(never)
    private static func prepareCodexRescanPublicationRowIdentity(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        transaction.suppressedByAuthoritativeFork = Self.codexNonForkSourceIsSuppressed(
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            state: transaction.state)
        transaction.sessionAlreadyContributed = transaction.sessionId.map {
            transaction.state.contributingSessionIds.contains($0)
        } ?? false
        if transaction.sessionAlreadyContributed,
           !Self.prepareCodexSessionRowIdentity(
               sessionId: transaction.sessionId,
               excludingPath: request.input.metadata.path,
               cache: &transaction.cache,
               context: request.context,
               state: &transaction.state)
        {
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] = cached
            }
            return false
        }
        return true
    }

    @inline(never)
    private static func computeCodexRescanPublicationUsageRows(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        transaction.uniqueRows = Self.uniqueCodexRows(
            rows: transaction.parsed.rows,
            sessionId: transaction.sessionId,
            forkedFromId: transaction.sourceForkedFromId,
            fileIdentity: request.input.metadata.path,
            state: &transaction.state)
        transaction.uniqueDays = Self.codexFileDays(rows: transaction.uniqueRows)
        Self.mergeFileDays(
            existing: &transaction.usageDays,
            delta: transaction.uniqueDays)
        let splitMaps = Self.codexModeSplitMaps(
            rows: transaction.uniqueRows,
            range: request.context.range,
            priorityTurns: request.context.resources.priorityTurns,
            modelsDevCatalog: request.context.resources.modelsDevCatalog,
            modelsDevCacheRoot: request.context.resources.modelsDevCacheRoot)
        transaction.standardCostNanos = splitMaps.standardCostNanos
        transaction.priorityCostNanos = splitMaps.priorityCostNanos
        transaction.standardTokens = splitMaps.standardTokens
        transaction.priorityTokens = splitMaps.priorityTokens
        return true
    }

    @inline(never)
    private static func loadCodexRescanPublicationRetainedRows(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        guard request.preservesLegacyOutsideProjection,
              let retainedCached = request.retainedCached
        else {
            transaction.retainedRows = []
            return true
        }
        switch Self.codexUsageRows(
            usage: retainedCached,
            fileURL: request.input.fileURL,
            context: request.context)
        {
        case let .ready(rows):
            transaction.retainedRows = transaction.suppressedByAuthoritativeFork
                ? Self.codexRowsOutsideScanRange(rows, range: request.context.range)
                : rows
            return true
        case .needsRebuild:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] =
                    Self.codexUsageRequiringUsageRowIndexRebuild(cached)
            }
            return false
        case .temporarilyUnavailable:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] = cached
            }
            return false
        }
    }

    @inline(never)
    private static func priceCodexRescanPublicationRows(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let mergedRows = Self.mergeCodexRows(
            transaction.retainedRows,
            rows: transaction.uniqueRows,
            sessionId: transaction.sessionId) ?? []
        transaction.pricedRows = Self.pricedCodexUsageRows(
            mergedRows,
            context: transaction.request.context)
        return true
    }

    @inline(never)
    private static func persistCodexRescanPublicationRows(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex,
              let codexSession = transaction.codexSession
        else { return false }
        let rowPersistence = Self.replacingCodexUsageRows(
            rows: transaction.pricedRows,
            nextUsageRowIndex: parsed.nextUsageRowIndex,
            fileURL: request.input.fileURL,
            fileId: sourceObservation.metadata.fileId,
            indexedBytes: parsed.parsedBytes,
            anchor: tokenIndex.anchor,
            isComplete: transaction.scanIsComplete,
            changeUnixNs: sourceObservation.metadata.changeUnixNs,
            sessionId: transaction.sessionId,
            forkedFromId: codexSession.forkedFromId ?? parsed.forkedFromId,
            forkDependencyKey: transaction.forkBaselineDependencyKey,
            ownershipKey: transaction.sessionAlreadyContributed
                || transaction.suppressedByAuthoritativeFork
                ? Self.codexUsageRowOwnershipKey(
                    sessionId: transaction.sessionId,
                    forkedFromId: transaction.sourceForkedFromId,
                    input: request.input,
                    cache: transaction.cache)
                : nil,
            context: request.context)
        switch rowPersistence {
        case let .persisted(sidecarState):
            transaction.publishedRowState = sidecarState
            transaction.publishedInlineRows = nil
            return true
        case let .inline(rows):
            transaction.publishedRowState = nil
            transaction.publishedInlineRows = rows
            return true
        case .retryLater:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] = cached
            }
            return false
        case .rebuildNextPass:
            request.context.scanBudget?.recordPersistenceDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] =
                    Self.codexUsageRequiringUsageRowIndexRebuild(cached)
            }
            return false
        }
    }

    @inline(never)
    private static func revalidateCodexRescanPublication(
        _ transaction: CodexRescanPublicationTransaction) throws -> Bool
    {
        let request = transaction.request
        let parsed = transaction.parsed
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex
        else { return false }
        guard Self.observeCodexFileSource(
            sourceGuard: CodexFileSourceGuard(
                metadata: sourceObservation.metadata,
                prefixAnchor: tokenIndex.anchor),
            fileURL: request.input.fileURL) != nil
        else {
            request.context.scanBudget?.recordSourceMutationDeferral()
            transaction.state = transaction.stateBeforeMerge
            if let cached = request.input.cached {
                transaction.cache.files[request.input.metadata.path] = cached
            }
            return false
        }
        if try Self.deferCodexForkPublicationIfDependencyChanged(
            parentSessionId: parsed.forkedFromId,
            dependsOnParentTotals: parsed.dependsOnParentTotals,
            dependencyKeyUsed: transaction.forkBaselineDependencyKey,
            input: request.input,
            cached: request.input.cached,
            context: request.context,
            cache: &transaction.cache,
            state: &transaction.state,
            stateBeforePublication: transaction.stateBeforeMerge)
        {
            return false
        }
        return true
    }

    @inline(never)
    private static func computeCodexRescanPublicationAggregates(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let request = transaction.request
        let retainedCached = request.retainedCached
        let context = request.context
        let outsideCostNanos = request.preservesLegacyOutsideProjection
            ? Self.costMapOutsideScanWindow(retainedCached?.codexCostNanos, range: context.range)
            : nil
        transaction.codexCostNanos = Self.mergeCostMaps(
            outsideCostNanos,
            Self.codexCostNanos(
                rows: transaction.uniqueRows,
                range: context.range,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
        let outsideSurcharge = request.preservesLegacyOutsideProjection
            ? Self.costMapOutsideScanWindow(
                retainedCached?.codexPrioritySurchargeNanos,
                range: context.range)
            : nil
        transaction.codexPrioritySurchargeNanos = Self.mergeCostMaps(
            outsideSurcharge,
            Self.codexPrioritySurchargeNanos(
                rows: transaction.uniqueRows,
                range: context.range,
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
        transaction.standardCostNanos = Self.mergeCostMaps(
            request.preservesLegacyOutsideProjection
                ? Self.costMapOutsideScanWindow(
                    retainedCached?.codexStandardCostNanos,
                    range: context.range)
                : nil,
            transaction.standardCostNanos)
        transaction.priorityCostNanos = Self.mergeCostMaps(
            request.preservesLegacyOutsideProjection
                ? Self.costMapOutsideScanWindow(
                    retainedCached?.codexPriorityCostNanos,
                    range: context.range)
                : nil,
            transaction.priorityCostNanos)
        transaction.standardTokens = Self.mergeIntMaps(
            request.preservesLegacyOutsideProjection
                ? Self.intMapOutsideScanWindow(
                    retainedCached?.codexStandardTokens,
                    range: context.range)
                : nil,
            transaction.standardTokens)
        transaction.priorityTokens = Self.mergeIntMaps(
            request.preservesLegacyOutsideProjection
                ? Self.intMapOutsideScanWindow(
                    retainedCached?.codexPriorityTokens,
                    range: context.range)
                : nil,
            transaction.priorityTokens)
        transaction.publishedTurnIDs = transaction.publishedRowState == nil
            ? Self.codexTurnIDs(rows: transaction.publishedInlineRows ?? [])
            : nil
        return true
    }

    @inline(never)
    private static func buildCodexRescanPublicationUsage(
        _ transaction: CodexRescanPublicationTransaction) -> Bool
    {
        let parsed = transaction.parsed
        guard let sourceObservation = transaction.sourceObservation,
              let tokenIndex = transaction.tokenIndex,
              let codexSession = transaction.codexSession
        else { return false }
        transaction.finalUsage = Self.makeFileUsage(
            mtimeUnixMs: sourceObservation.metadata.mtimeUnixMs,
            size: sourceObservation.metadata.size,
            days: transaction.usageDays,
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
            sessionId: transaction.sessionId,
            forkedFromId: codexSession.forkedFromId ?? parsed.forkedFromId,
            codexForkTimestamp: parsed.forkTimestamp,
            forkBaselineDependencyKey: transaction.forkBaselineDependencyKey,
            projectPath: transaction.projectPath,
            canonicalProjectPath: transaction.canonicalProjectPath,
            codexSession: codexSession.isEmpty ? nil : codexSession,
            codexCostNanos: transaction.codexCostNanos,
            codexPrioritySurchargeNanos: transaction.codexPrioritySurchargeNanos,
            codexStandardCostNanos: transaction.standardCostNanos,
            codexPriorityCostNanos: transaction.priorityCostNanos,
            codexStandardTokens: transaction.standardTokens,
            codexPriorityTokens: transaction.priorityTokens,
            codexTurnIDs: transaction.publishedTurnIDs,
            codexRows: transaction.publishedInlineRows,
            codexTokenSnapshots: tokenIndex.snapshots,
            codexTokenCheckpoints: tokenIndex.checkpoints,
            codexTokenTimestampsMonotonic: tokenIndex.timestampsMonotonic,
            codexTokenIndexAnchor: tokenIndex.anchor,
            codexTokenSidecarState: tokenIndex.sidecarState,
            codexUsageRowSidecarState: transaction.publishedRowState,
            codexUsageRowProducerKey: transaction.publishedRowState == nil
                ? nil
                : transaction.request.context.resources.currentProducerKey,
            codexForkAccountingState: parsed.forkAccountingState,
            codexScanFileId: sourceObservation.metadata.fileId,
            codexScanChangeUnixNs: sourceObservation.metadata.changeUnixNs,
            codexScanTargetSize: sourceObservation.metadata.size,
            codexScanComplete: transaction.scanIsComplete,
            codexJSONLResumeState: parsed.jsonlResumeState,
            codexBufferedSubagentLines: parsed.bufferedSubagentLines,
            codexSubagentResumeState: parsed.subagentResumeState,
            codexDeferredReplayState: parsed.deferredReplayState,
            codexBufferedUnresolvedForkLines: parsed.bufferedUnresolvedForkLines)
            .refreshingCodexWorkspaceUsageFingerprint()
        return true
    }

    @inline(never)
    private static func commitCodexRescanPublication(
        _ transaction: CodexRescanPublicationTransaction)
    {
        let request = transaction.request
        guard let finalUsage = transaction.finalUsage else { return }
        if request.discardedCachedSourceDetail {
            transaction.cache.scanSinceKey = nil
            transaction.cache.scanUntilKey = nil
        }
        if let cached = request.input.cached {
            Self.applyFileDays(cache: &transaction.cache, fileDays: cached.days, sign: -1)
        }
        transaction.cache.files[request.input.metadata.path] = finalUsage
        Self.applyFileDays(
            cache: &transaction.cache,
            fileDays: finalUsage.days,
            sign: 1)
        Self.rememberScannedCodexFile(
            input: request.input,
            session: CodexScannedSession(
                id: transaction.sessionId,
                days: transaction.usageDays),
            rows: transaction.uniqueRows,
            context: request.context,
            state: &transaction.state)
    }

    @inline(never)
    private static func retainCodexRescanPublicationUsage(
        _ transaction: CodexRescanPublicationTransaction,
        usage: CostUsageFileUsage,
        remember: Bool)
    {
        let request = transaction.request
        transaction.cache.files[request.input.metadata.path] = usage
        guard remember else { return }
        Self.rememberScannedCodexFile(
            input: request.input,
            session: CodexScannedSession(id: usage.sessionId, days: usage.days),
            rows: usage.codexRows ?? [],
            context: request.context,
            state: &transaction.state)
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

extension CostUsageFileUsage {
    func touchesCodexScanWindow(sinceKey: String, untilKey: String) -> Bool {
        self.days.keys.contains {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }
    }
}

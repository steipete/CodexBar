import Foundation

extension CostUsageScanner {
    /// Missing-parent forks stay out of priced totals. Count them as unmetered so Spend
    /// coverage can show the gap instead of silently dropping the session.
    static func unresolvedForkUnmeteredCounts(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: Int]
    {
        var counts: [String: Int] = [:]
        for usage in cache.files.values {
            guard self.isUnresolvedMissingParentFork(usage),
                  !self.codexFileHasBilledTokens(usage)
            else { continue }
            let unixMs = usage.codexSession?.startedAtUnixMs
                ?? usage.codexSession?.latestActivityUnixMs
                ?? usage.mtimeUnixMs
            guard unixMs > 0 else { continue }
            let dayKey = CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000),
                calendar: range.calendar)
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.sinceKey, until: range.untilKey)
            else { continue }
            counts[dayKey, default: 0] += 1
        }
        return counts
    }

    static func isUnresolvedMissingParentFork(_ usage: CostUsageFileUsage) -> Bool {
        guard usage.forkedFromId != nil else { return false }
        if let key = usage.forkBaselineDependencyKey {
            return key.hasPrefix("missing|")
        }
        return true
    }

    static func codexFileHasBilledTokens(_ usage: CostUsageFileUsage) -> Bool {
        if (usage.codexRows ?? []).contains(where: { $0.input > 0 || $0.cached > 0 || $0.output > 0 }) {
            return true
        }
        return usage.days.values.contains { models in
            models.values.contains { packed in packed.contains { $0 > 0 } }
        }
    }

    struct CodexReportDayPricingContext {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]]
        var unresolvedRowGroups: Set<CodexDayModelKey>
        var modeOwnershipMismatchGroups: Set<CodexDayModelKey>
        var priorityEvidenceGroups: Set<CodexDayModelKey>
        var incompletePricingEvidenceGroups: Set<CodexDayModelKey>
        var authoritativeCostEvidenceGroups: Set<CodexDayModelKey>
        var priorityTurns: [String: CodexPriorityTurnMetadata]
        var modelsDevCatalog: ModelsDevCatalog
        var modelsDevCacheRoot: URL?
        var customPricing: CostUsageCustomPricing
    }

    static func unmeteredForkReportEntry(day: String, unmetered: Int) -> CostUsageDailyReport.Entry? {
        guard unmetered > 0 else { return nil }
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unmeteredRequestCount: unmetered)
    }

    static func makeCodexBilledDayEntry(
        day: String,
        models: [String: [Int]],
        unmetered: Int,
        pricing: CodexReportDayPricingContext) -> CostUsageDailyReport.Entry
    {
        let modelNames = models.keys.sorted()
        var dayInput = 0
        var dayCacheRead = 0
        var dayOutput = 0
        var dayReasoning = 0
        var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
        var dayCost: Double = 0
        var dayCostSeen = false

        for model in modelNames {
            let packed = models[model] ?? [0, 0, 0]
            let input = packed[safe: 0] ?? 0
            let cached = packed[safe: 1] ?? 0
            let output = packed[safe: 2] ?? 0
            let totalTokens = input + output
            let rows = pricing.rowsByDayModel[day]?[model] ?? []
            let reasoning = rows.compactMap(\.reasoning).reduce(0, +)

            dayInput += input
            dayCacheRead += cached
            dayOutput += output
            if reasoning > 0 {
                dayReasoning += reasoning
            }

            let rowCost = rows.isEmpty ? nil : Self.codexRowCostBreakdown(
                rows: rows,
                priorityTurns: pricing.priorityTurns,
                modelsDevCatalog: pricing.modelsDevCatalog,
                modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                customPricing: pricing.customPricing)
            let group = CodexDayModelKey(day: day, model: model)
            let rowCostIsTrusted = !pricing.unresolvedRowGroups.contains(group)
                && !pricing.modeOwnershipMismatchGroups.contains(group)
                && rowCost?.isTrusted(canonicalTotalTokens: totalTokens) == true
            let aggregateCost = pricing.priorityEvidenceGroups.contains(group)
                || pricing.incompletePricingEvidenceGroups.contains(group)
                || (pricing.unresolvedRowGroups.contains(group)
                    && pricing.authoritativeCostEvidenceGroups.contains(group))
                || rowCost?.hasIncompletePricing == true
                ? nil
                : CostUsagePricing.codexAggregateCostUSD(
                    model: model,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    modelsDevCatalog: pricing.modelsDevCatalog,
                    modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                    customPricing: pricing.customPricing)
            let cost = rowCostIsTrusted
                ? rowCost?.totalCostUSD ?? aggregateCost
                : aggregateCost
            let hasModeSplit = rowCostIsTrusted && rowCost?.hasModeSplit == true
            breakdown.append(
                CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: totalTokens,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cached > 0 ? cached : nil,
                    reasoningTokens: reasoning > 0 ? reasoning : nil,
                    standardCostUSD: hasModeSplit ? rowCost?.optionalStandardCostUSD : nil,
                    priorityCostUSD: hasModeSplit ? rowCost?.optionalPriorityCostUSD : nil,
                    standardTokens: hasModeSplit ? rowCost?.optionalStandardTokens : nil,
                    priorityTokens: hasModeSplit ? rowCost?.optionalPriorityTokens : nil))
            if let cost {
                dayCost += cost
                dayCostSeen = true
            }
        }

        let dayTotal = dayInput + dayOutput
        let entryCost = dayCostSeen ? dayCost : nil
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: dayInput,
            outputTokens: dayOutput,
            cacheReadTokens: dayCacheRead > 0 ? dayCacheRead : nil,
            reasoningTokens: dayReasoning > 0 ? dayReasoning : nil,
            totalTokens: dayTotal,
            costUSD: entryCost,
            modelsUsed: modelNames,
            modelBreakdowns: Self.sortedModelBreakdowns(breakdown),
            unpricedRequestCount: entryCost == nil && dayTotal > 0 ? 1 : nil,
            unmeteredRequestCount: unmetered > 0 ? unmetered : nil)
    }
}

extension CostUsageFileUsage {
    func touchesCodexScanWindow(
        sinceKey: String,
        untilKey: String,
        calendar: Calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()) -> Bool
    {
        if self.days.keys.contains(where: {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }) {
            return true
        }

        // Missing-parent forks keep empty billed days on purpose. Session timestamps still
        // place them in the scan window so force-rescan prune cannot drop the unmetered gap.
        let isIncompleteFork = self.codexBufferedUnresolvedForkLines != nil
            || CostUsageScanner.isUnresolvedMissingParentFork(self)
        guard isIncompleteFork else { return false }

        if let unixMs = self.codexSession?.startedAtUnixMs ?? self.codexSession?.latestActivityUnixMs {
            let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000),
                calendar: calendar)
            return CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: sinceKey,
                until: untilKey)
        }
        return true
    }
}

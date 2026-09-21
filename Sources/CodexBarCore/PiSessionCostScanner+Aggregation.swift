import Foundation

extension PiSessionCostScanner {
    static func checkedReports(
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange)
        -> (codex: CostUsageDailyReport, claude: CostUsageDailyReport)?
    {
        // Provider-specific by design: Pi's shared cache has Codex and Anthropic pricing partitions.
        guard let codex = self.buildReport(provider: .codex, cache: cache, range: range),
              let claude = self.buildReport(provider: .claude, cache: cache, range: range)
        else { return nil }
        return (codex, claude)
    }

    static func buildReport(
        provider: UsageProvider,
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange) -> CostUsageDailyReport?
    {
        let providerDays = cache.daysByProvider[provider.rawValue] ?? [:]
        let dayKeys = providerDays.keys.sorted().filter {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
        var entries: [CostUsageDailyReport.Entry] = []
        var total = PiPackedUsage()
        for dayKey in dayKeys {
            guard let models = providerDays[dayKey] else { continue }
            var day = PiPackedUsage()
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            for modelName in models.keys.sorted() {
                guard var packed = models[modelName],
                      let derivedTokens = CheckedSum.integers([
                          packed.inputTokens, packed.cacheReadTokens, packed.cacheWriteTokens, packed.outputTokens,
                      ])
                else { return nil }
                packed.totalTokens = max(packed.totalTokens, derivedTokens)
                guard let next = self.addPacked(a: day, b: packed) else { return nil }
                day = next
                // Keep per-message prices and unknown-price evidence; never reprice an aggregate request.
                breakdown.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: packed.costSampleCount > 0 ? Double(packed.costNanos) / self.costScale : nil,
                    totalTokens: packed.totalTokens,
                    requestCount: packed.usageSampleCount))
            }
            guard let next = self.addPacked(a: total, b: day) else { return nil }
            total = next
            let requestCount = day.usageSampleCount ?? 0
            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: day.inputTokens > 0 ? day.inputTokens : nil,
                outputTokens: day.outputTokens > 0 ? day.outputTokens : nil,
                cacheReadTokens: day.cacheReadTokens > 0 ? day.cacheReadTokens : nil,
                cacheCreationTokens: day.cacheWriteTokens > 0 ? day.cacheWriteTokens : nil,
                totalTokens: day.totalTokens,
                requestCount: requestCount,
                costUSD: day.costSampleCount > 0 ? Double(day.costNanos) / self.costScale : nil,
                modelsUsed: models.keys.sorted(),
                modelBreakdowns: self.sortedModelBreakdowns(breakdown),
                unpricedRequestCount: requestCount - day.costSampleCount,
                estimatedRequestCount: day.costSampleCount,
                pricedRequestCount: 0))
        }
        guard !entries.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        return CostUsageDailyReport(
            data: entries,
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: total.inputTokens > 0 ? total.inputTokens : nil,
                totalOutputTokens: total.outputTokens > 0 ? total.outputTokens : nil,
                cacheReadTokens: total.cacheReadTokens > 0 ? total.cacheReadTokens : nil,
                cacheCreationTokens: total.cacheWriteTokens > 0 ? total.cacheWriteTokens : nil,
                totalTokens: total.totalTokens,
                totalCostUSD: total.costSampleCount > 0 ? Double(total.costNanos) / self.costScale : nil))
    }

    static func mergedContributions(
        existing: [String: [String: [String: PiPackedUsage]]],
        delta: [String: [String: [String: PiPackedUsage]]]) -> [String: [String: [String: PiPackedUsage]]]?
    {
        var merged = existing
        guard self.applyContributions(daysByProvider: &merged, contributions: delta) else { return nil }
        return merged
    }

    static func applyContributions(
        daysByProvider: inout [String: [String: [String: PiPackedUsage]]],
        contributions: [String: [String: [String: PiPackedUsage]]]) -> Bool
    {
        for (provider, days) in contributions {
            for (day, models) in days {
                for (model, packed) in models {
                    guard let sum = self.addPacked(
                        a: daysByProvider[provider]?[day]?[model] ?? PiPackedUsage(), b: packed)
                    else { return false }
                    daysByProvider[provider, default: [:]][day, default: [:]][model] = sum
                }
            }
        }
        return true
    }

    static func addPacked(a: PiPackedUsage, b: PiPackedUsage) -> PiPackedUsage? {
        guard let aSamples = self.validSampleCount(a), let bSamples = self.validSampleCount(b),
              let input = CheckedSum.integers([a.inputTokens, b.inputTokens]),
              let read = CheckedSum.integers([a.cacheReadTokens, b.cacheReadTokens]),
              let write = CheckedSum.integers([a.cacheWriteTokens, b.cacheWriteTokens]),
              let output = CheckedSum.integers([a.outputTokens, b.outputTokens]),
              let tokens = CheckedSum.integers([a.totalTokens, b.totalTokens]),
              let costs = CheckedSum.integers([a.costSampleCount, b.costSampleCount]),
              let samples = CheckedSum.integers([aSamples, bSamples])
        else { return nil }
        let nanos = a.costNanos.addingReportingOverflow(b.costNanos)
        guard !nanos.overflow else { return nil }
        return PiPackedUsage(
            inputTokens: input,
            cacheReadTokens: read,
            cacheWriteTokens: write,
            outputTokens: output,
            totalTokens: tokens,
            costNanos: nanos.partialValue,
            costSampleCount: costs,
            usageSampleCount: samples)
    }

    private static func validSampleCount(_ usage: PiPackedUsage) -> Int? {
        guard [
            usage.inputTokens,
            usage.cacheReadTokens,
            usage.cacheWriteTokens,
            usage.outputTokens,
            usage.totalTokens,
            usage.costSampleCount,
        ].allSatisfy({ $0 >= 0 }),
            usage.costNanos >= 0,
            let count = usage.usageSampleCount ?? (usage.isZero ? 0 : nil),
            count >= usage.costSampleCount,
            count > 0 || usage.isZero,
            usage.costSampleCount > 0 || usage.costNanos == 0
        else { return nil }
        return count
    }

    private static func sortedModelBreakdowns(_ values: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        values.sorted {
            if $0.costUSD != $1.costUSD { return ($0.costUSD ?? -1) > ($1.costUSD ?? -1) }
            if $0.totalTokens != $1.totalTokens { return ($0.totalTokens ?? -1) > ($1.totalTokens ?? -1) }
            return $0.modelName > $1.modelName
        }
    }
}

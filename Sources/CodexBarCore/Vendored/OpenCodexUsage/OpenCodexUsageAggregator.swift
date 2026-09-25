import Foundation

enum OpenCodexUsageAggregator {
    struct DayAccumulator {
        var mix = CostUsageTokenMix()
        var tokens = CostUsageDailyReport.OptionalCountAccumulator()
        var cost: Double = 0
        var sawCost = false
        var priced = 0
        var unpriced = 0
        var unmetered = 0
        var estimated = 0
        var models: [String: ModelAccumulator] = [:]
    }

    struct ModelAccumulator {
        var mix = CostUsageTokenMix()
        var tokens = CostUsageDailyReport.OptionalCountAccumulator()
        var cost: Double = 0
        var sawCost = false
    }

    struct SessionAccumulator {
        var lastActivity = Date.distantPast
        var mix = CostUsageTokenMix()
        var tokens = CostUsageDailyReport.OptionalCountAccumulator()
        var requests = 0
        var cost: Double?
        var models: [String: ModelAccumulator] = [:]
    }

    typealias HourAccumulator = CostUsageTemporalTotals

    /// Aggregates OpenCodex usage entries into a per-window token/cost snapshot.
    ///
    /// Pricing context is resolved once per call and shared by every entry: `modelsDevCatalog` is the models.dev
    /// catalog and `customPricingOverlay` the app-level custom-pricing overlay file. Callers that aggregate several
    /// providers (see `OpenCodexUsageFanOut`) resolve both once and pass them in; when either is nil it is resolved
    /// here once. Each windowed entry is priced exactly once and that price feeds the day, session, hour and model
    /// accumulators, so output is identical to pricing inside each merge — without a catalog/overlay lookup per call.
    static func snapshot(
        entries: [OpenCodexUsageEntry],
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        customPricing: CostUsageCustomPricing = .empty,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        customPricingOverlay: CostUsageCustomPricing? = nil) -> CostUsageTokenSnapshot
    {
        let days = max(1, historyDays)
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var unique: [String: OpenCodexUsageEntry] = [:]
        for entry in entries {
            unique[entry.requestID] = entry
        }
        let windowed = unique.values.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.requestID < rhs.requestID
            }

        // Resolve the pricing context once for the whole snapshot. A missing models.dev catalog becomes an EMPTY
        // catalog on purpose: `codexCostUSD` treats a nil catalog as "resolve it yourself" and would fall back to
        // `ModelsDevCache.load` (a stat per pricing target) for every entry, whereas an empty catalog yields the same
        // nil lookups without any file access. Nothing is resolved when the window is empty.
        let catalog: ModelsDevCatalog
        let overlay: CostUsageCustomPricing
        if windowed.isEmpty {
            catalog = ModelsDevCatalog(providers: [:])
            overlay = .empty
        } else {
            catalog = modelsDevCatalog
                ?? CostUsagePricing.modelsDevCatalog()
                ?? ModelsDevCatalog(providers: [:])
            overlay = customPricingOverlay ?? CostUsagePricing.customPricingOverlay()
        }

        var daysByKey: [String: DayAccumulator] = [:]
        var sessions: [String: SessionAccumulator] = [:]
        var hoursByStart: [Date: HourAccumulator] = [:]
        // `windowed` is sorted by timestamp, so the day/hour memos hit on almost every entry; a miss only costs one
        // Calendar interval lookup. Price once per entry and reuse it for the day, session and hour merges.
        var windowTokens = CostUsageDailyReport.OptionalCountAccumulator()
        var dayMemo = CostUsageLocalDayKeyMemo()
        var hourMemo = CostUsageHourStartMemo()
        for entry in windowed {
            windowTokens.merge(entry.resolvedTotalCount)
            let cost = Self.listPriceUSD(
                entry: entry,
                customPricing: customPricing,
                modelsDevCatalog: catalog,
                customPricingOverlay: overlay)
            let dayKey = dayMemo.key(for: entry.timestamp, calendar: calendar)
            var day = daysByKey[dayKey] ?? DayAccumulator()
            Self.merge(entry, cost: cost, into: &day)
            daysByKey[dayKey] = day

            let sessionID = entry.conversationID ?? entry.requestID
            var session = sessions[sessionID] ?? SessionAccumulator()
            session.lastActivity = max(session.lastActivity, entry.timestamp)
            session.requests += 1
            Self.merge(entry, cost: cost, into: &session)
            sessions[sessionID] = session

            let hour = hourMemo.start(for: entry.timestamp, calendar: calendar)
            var hourBucket = hoursByStart[hour] ?? HourAccumulator()
            Self.merge(entry, cost: cost, into: &hourBucket)
            hoursByStart[hour] = hourBucket
        }

        let daily = daysByKey.keys.sorted().compactMap { key -> CostUsageDailyReport.Entry? in
            guard let day = daysByKey[key] else { return nil }
            return Self.entry(dayKey: key, day: day)
        }
        let sessionRows = sessions.keys.sorted().compactMap { key -> CostUsageSessionBreakdown? in
            guard let session = sessions[key] else { return nil }
            return CostUsageSessionBreakdown(
                sessionID: key,
                lastActivity: session.lastActivity,
                inputTokens: session.mix.inputTokens,
                cachedInputTokens: session.mix.cacheReadTokens,
                outputTokens: session.mix.outputTokens,
                reasoningTokens: session.mix.reasoningTokens,
                totalTokens: session.tokens.value,
                requestCount: session.requests,
                costUSD: session.cost,
                modelBreakdowns: Self.modelBreakdowns(session.models))
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID < rhs.sessionID
        }

        let hourly = hoursByStart.keys.sorted().map { hour in
            let bucket = hoursByStart[hour] ?? HourAccumulator()
            return bucket.hourlyEntry(hour: hour)
        }

        let todayEntry = CostUsageTokenSnapshot.entry(
            in: daily,
            forLocalDayContaining: now,
            calendar: calendar)
        let windowSummary = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: days,
            daily: daily,
            sessions: Array(sessionRows.prefix(64)),
            updatedAt: now)
            .summary(forLastDays: days, calendar: calendar)

        return CostUsageTokenSnapshot(
            sessionTokens: todayEntry == nil && !daily.isEmpty ? 0 : todayEntry?.totalTokens,
            sessionCostUSD: todayEntry == nil && !daily.isEmpty ? 0 : todayEntry?.costUSD,
            sessionRequests: todayEntry?.requestCount ?? (daily.isEmpty ? nil : 0),
            last30DaysTokens: windowTokens.value,
            last30DaysCostUSD: windowSummary.totalCostUSD,
            last30DaysRequests: windowSummary.totalRequests,
            historyDays: days,
            historyLabel: "OpenCodex usage.jsonl",
            costProvenance: .listPriceEstimate,
            daily: daily,
            sessions: Array(sessionRows.prefix(64)),
            hourly: hourly,
            updatedAt: now)
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into day: inout DayAccumulator)
    {
        day.mix.merge(entry.usage?.tokenMix ?? .init())
        day.tokens.merge(entry.resolvedTotalCount)
        day.priced += entry.usageStatus == .reported ? 1 : 0
        day.estimated += entry.usageStatus == .estimated ? 1 : 0
        day.unmetered += entry.usageStatus == .unsupported ? 1 : 0
        day.unpriced += entry.usageStatus == .unreported ? 1 : 0

        if let cost {
            day.cost += cost
            day.sawCost = true
        } else if entry.usageStatus == .reported {
            day.unpriced += 1
            if day.priced > 0 {
                day.priced -= 1
            }
        } else if entry.usageStatus == .estimated {
            day.unpriced += 1
            if day.estimated > 0 {
                day.estimated -= 1
            }
        }

        var model = day.models[entry.model] ?? ModelAccumulator()
        Self.merge(entry, cost: cost, into: &model)
        day.models[entry.model] = model
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into session: inout SessionAccumulator)
    {
        session.mix.merge(entry.usage?.tokenMix ?? .init())
        session.tokens.merge(entry.resolvedTotalCount)
        session.cost = self.add(session.cost, cost)
        var model = session.models[entry.model] ?? ModelAccumulator()
        self.merge(entry, cost: cost, into: &model)
        session.models[entry.model] = model
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into hour: inout HourAccumulator)
    {
        hour.add(totalTokens: entry.resolvedTotalCount.value, costUSD: cost)
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into model: inout ModelAccumulator)
    {
        model.mix.merge(entry.usage?.tokenMix ?? .init())
        model.tokens.merge(entry.resolvedTotalCount)
        if let cost {
            model.cost += cost
            model.sawCost = true
        }
    }

    private static func entry(dayKey: String, day: DayAccumulator) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: day.mix.inputTokens,
            outputTokens: day.mix.outputTokens,
            cacheReadTokens: day.mix.cacheReadTokens,
            cacheCreationTokens: day.mix.cacheCreationTokens,
            reasoningTokens: day.mix.reasoningTokens,
            totalTokens: day.tokens.value,
            requestCount: day.priced + day.unpriced + day.unmetered + day.estimated,
            costUSD: day.sawCost ? day.cost : nil,
            modelsUsed: day.models.keys.sorted(),
            modelBreakdowns: self.modelBreakdowns(day.models),
            unpricedRequestCount: day.unpriced,
            unmeteredRequestCount: day.unmetered,
            estimatedRequestCount: day.estimated)
    }

    private static func modelBreakdowns(_ models: [String: ModelAccumulator]) -> [CostUsageDailyReport.ModelBreakdown] {
        models.keys.sorted().map { name in
            let model = models[name] ?? ModelAccumulator()
            return CostUsageDailyReport.ModelBreakdown(
                modelName: name,
                costUSD: model.sawCost ? model.cost : nil,
                totalTokens: model.tokens.value,
                inputTokens: model.mix.inputTokens,
                outputTokens: model.mix.outputTokens,
                cacheReadTokens: model.mix.cacheReadTokens,
                cacheCreationTokens: model.mix.cacheCreationTokens,
                reasoningTokens: model.mix.reasoningTokens)
        }
    }

    /// List-price estimate for one entry. Precedence is unchanged from the per-merge pricing it replaces:
    /// 1. `customPricing` — the snapshot's own overlay (provider-scoped rates passed by the caller);
    /// 2. App-level exact overrides, then the observed provider's models.dev rates. Only the OpenAI route
    ///    uses OpenAI bundled/historical tables. Catalog and overlay are resolved once per snapshot.
    private static func listPriceUSD(
        entry: OpenCodexUsageEntry,
        customPricing: CostUsageCustomPricing,
        modelsDevCatalog: ModelsDevCatalog,
        customPricingOverlay: CostUsageCustomPricing) -> Double?
    {
        guard entry.usageStatus == .reported || entry.usageStatus == .estimated else { return nil }
        let usage = entry.usage
        let hasTokenData = entry.resolvedTotalTokens != nil
            || usage?.inputTokens != nil
            || usage?.outputTokens != nil
            || usage?.cacheReadTokens != nil
            || usage?.cacheCreationInputTokens != nil
        guard hasTokenData else { return nil }
        guard let input = usage?.inputTokens, let output = usage?.outputTokens else { return nil }
        let cacheRead = usage?.cacheReadTokens ?? 0
        let cacheWrite = usage?.cacheCreationInputTokens ?? 0
        if customPricing.rates(providerID: entry.provider, model: entry.model) != nil {
            return customPricing.costUSD(
                providerID: entry.provider,
                model: entry.model,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite)
        }
        let pricingProvider = OpenCodexUsagePricing.providerID(for: entry)
        // Legacy OpenAI transport rows can carry a billing route in the model name. Preserve
        // application overrides keyed by the recorded identity before resolving that route.
        if let recordedRates = customPricingOverlay.rates(providerID: entry.provider, model: entry.model) {
            return CostUsageCustomPricing.costUSD(
                rates: recordedRates,
                inputTokens: max(0, max(0, input - cacheRead) - cacheWrite),
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite)
        }
        return CostUsagePricing.providerCostUSD(
            providerID: pricingProvider,
            model: entry.model,
            inputTokens: input,
            cachedInputTokens: cacheRead,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            pricingDate: entry.timestamp,
            catalog: modelsDevCatalog,
            customPricing: customPricingOverlay)
    }

    private static func add(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}

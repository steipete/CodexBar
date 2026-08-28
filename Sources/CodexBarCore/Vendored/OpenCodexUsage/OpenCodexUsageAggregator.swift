import Foundation

enum OpenCodexUsageAggregator {
    struct DayAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var reasoning = 0
        var tokens = 0
        var cost: Double = 0
        var sawInput = false
        var sawOutput = false
        var sawCacheRead = false
        var sawCacheCreation = false
        var sawReasoning = false
        var sawTokens = false
        var sawCost = false
        var priced = 0
        var unpriced = 0
        var unmetered = 0
        var estimated = 0
        var models: [String: ModelAccumulator] = [:]
    }

    struct ModelAccumulator {
        var tokens = 0
        var cost: Double = 0
        var sawTokens = false
        var sawCost = false
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheCreation: Int?
        var reasoning: Int?
    }

    struct SessionAccumulator {
        var lastActivity = Date.distantPast
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var reasoning: Int?
        var tokens: Int?
        var requests = 0
        var cost: Double?
        var models: [String: ModelAccumulator] = [:]
    }

    struct HourAccumulator {
        var tokens = 0
        var cost: Double = 0
        var sawTokens = false
        var sawCost = false
    }

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
        let days = max(1, min(365, historyDays))
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
        var dayMemo = LocalDayKeyMemo()
        var hourMemo = HourStartMemo()
        for entry in windowed {
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
                inputTokens: session.input,
                cachedInputTokens: session.cacheRead,
                outputTokens: session.output,
                reasoningTokens: session.reasoning,
                totalTokens: session.tokens,
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
            return CostUsageHourlyEntry(
                hour: hour,
                totalTokens: bucket.sawTokens ? bucket.tokens : nil,
                costUSD: bucket.sawCost ? bucket.cost : nil)
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
            .summary(forLastDays: min(30, days), calendar: calendar)

        return CostUsageTokenSnapshot(
            sessionTokens: todayEntry?.totalTokens ?? (daily.isEmpty ? nil : 0),
            sessionCostUSD: todayEntry?.costUSD ?? (daily.isEmpty ? nil : 0),
            sessionRequests: todayEntry?.requestCount ?? (daily.isEmpty ? nil : 0),
            last30DaysTokens: windowSummary.totalTokens,
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
        let usage = entry.usage
        if let input = usage?.inputTokens {
            day.input += input
            day.sawInput = true
        }
        if let output = usage?.outputTokens {
            day.output += output
            day.sawOutput = true
        }
        if let cacheRead = usage?.cacheReadTokens {
            day.cacheRead += cacheRead
            day.sawCacheRead = true
        }
        if let cacheCreation = usage?.cacheCreationInputTokens {
            day.cacheCreation += cacheCreation
            day.sawCacheCreation = true
        }
        if let reasoning = usage?.reasoningOutputTokens {
            day.reasoning += reasoning
            day.sawReasoning = true
        }
        if let tokens = entry.resolvedTotalTokens {
            day.tokens += tokens
            day.sawTokens = true
        }
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
        session.input = self.add(session.input, entry.usage?.inputTokens)
        session.output = self.add(session.output, entry.usage?.outputTokens)
        session.cacheRead = self.add(session.cacheRead, entry.usage?.cacheReadTokens)
        session.reasoning = self.add(session.reasoning, entry.usage?.reasoningOutputTokens)
        session.tokens = self.add(session.tokens, entry.resolvedTotalTokens)
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
        if let tokens = entry.resolvedTotalTokens {
            hour.tokens += tokens
            hour.sawTokens = true
        }
        if let cost {
            hour.cost += cost
            hour.sawCost = true
        }
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into model: inout ModelAccumulator)
    {
        model.input = self.add(model.input, entry.usage?.inputTokens)
        model.output = self.add(model.output, entry.usage?.outputTokens)
        model.cacheRead = self.add(model.cacheRead, entry.usage?.cacheReadTokens)
        model.cacheCreation = self.add(model.cacheCreation, entry.usage?.cacheCreationInputTokens)
        model.reasoning = self.add(model.reasoning, entry.usage?.reasoningOutputTokens)
        if let tokens = entry.resolvedTotalTokens {
            model.tokens += tokens
            model.sawTokens = true
        }
        if let cost {
            model.cost += cost
            model.sawCost = true
        }
    }

    private static func entry(dayKey: String, day: DayAccumulator) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: day.sawInput ? day.input : nil,
            outputTokens: day.sawOutput ? day.output : nil,
            cacheReadTokens: day.sawCacheRead ? day.cacheRead : nil,
            cacheCreationTokens: day.sawCacheCreation ? day.cacheCreation : nil,
            reasoningTokens: day.sawReasoning ? day.reasoning : nil,
            totalTokens: day.sawTokens ? day.tokens : nil,
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
                totalTokens: model.sawTokens ? model.tokens : nil,
                inputTokens: model.input,
                outputTokens: model.output,
                cacheReadTokens: model.cacheRead,
                cacheCreationTokens: model.cacheCreation,
                reasoningTokens: model.reasoning)
        }
    }

    /// List-price estimate for one entry. Precedence is unchanged from the per-merge pricing it replaces:
    /// 1. `customPricing` — the snapshot's own overlay (provider-scoped rates passed by the caller);
    /// 2. `CostUsagePricing.codexCostUSD` with the pre-resolved `customPricingOverlay` (the app-level overlay file,
    ///    which `codexCostUSD` would otherwise re-load per call) and the pre-resolved models.dev `modelsDevCatalog`
    ///    (otherwise `ModelsDevCache.load` per call), then the bundled/historical tables.
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
        let input = usage?.inputTokens ?? 0
        let output = usage?.outputTokens ?? 0
        let cacheRead = usage?.cacheReadTokens ?? 0
        let cacheWrite = usage?.cacheCreationInputTokens ?? 0
        if let overlay = customPricing.costUSD(
            providerID: entry.provider,
            model: entry.model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite)
        {
            return overlay
        }
        return CostUsagePricing.codexCostUSD(
            model: entry.model,
            inputTokens: input,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            cacheWriteInputTokens: cacheWrite,
            pricingDate: entry.timestamp,
            modelsDevCatalog: modelsDevCatalog,
            customPricing: customPricingOverlay)
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
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

extension OpenCodexUsageAggregator {
    /// Reuses the calendar's `[start, next)` day interval while timestamps stay inside it.
    /// Day keys still come from `CostUsageLocalDay` so DST and non-Gregorian calendars stay aligned: the key derives
    /// y-m-d from the same Gregorian-in-timezone calendar whose `.day` interval is cached here, so the memo can never
    /// disagree with computing the key per entry (DST days are simply 23 h / 25 h intervals).
    private struct LocalDayKeyMemo {
        var start = Date.distantPast
        var end = Date.distantPast
        var key = ""

        mutating func key(for timestamp: Date, calendar: Calendar) -> String {
            if timestamp >= self.start, timestamp < self.end {
                return self.key
            }
            let dayCalendar = CostUsageLocalDay.gregorianCalendar(matching: calendar)
            guard let interval = dayCalendar.dateInterval(of: .day, for: timestamp) else {
                self.start = Date.distantPast
                self.end = Date.distantPast
                return CostUsageLocalDay.key(from: timestamp, calendar: calendar)
            }
            self.start = interval.start
            self.end = interval.end
            self.key = CostUsageLocalDay.key(from: timestamp, calendar: calendar)
            return self.key
        }
    }

    /// Reuses the calendar's hour interval while timestamps stay inside `[start, end)`.
    private struct HourStartMemo {
        var start = Date.distantPast
        var end = Date.distantPast

        mutating func start(for timestamp: Date, calendar: Calendar) -> Date {
            if timestamp >= self.start, timestamp < self.end {
                return self.start
            }
            guard let interval = calendar.dateInterval(of: .hour, for: timestamp) else {
                self.start = Date.distantPast
                self.end = Date.distantPast
                return timestamp
            }
            self.start = interval.start
            self.end = interval.end
            return self.start
        }
    }
}

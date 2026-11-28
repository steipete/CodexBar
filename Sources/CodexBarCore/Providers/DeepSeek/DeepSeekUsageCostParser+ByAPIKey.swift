import Foundation

extension DeepSeekUsageCostParser {
    // MARK: - By-API-key dashboard series

    /// The Platform usage page lists spend per key and model as timestamped
    /// buckets. Fold that into the same summary the menu already shows.
    static func parseByAPIKey(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current,
        rangeStart: Date? = nil,
        rangeEnd: Date? = nil) throws -> DeepSeekUsageSummary
    {
        let start = rangeStart ?? calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let end = rangeEnd ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let offsetSeconds = calendar.timeZone.secondsFromGMT(for: now)
        let startDayKey = self.dayString(start, calendar: calendar)
        let endInclusiveDate = end > start ? end.addingTimeInterval(-1) : start
        let endDayKey = self.dayString(endInclusiveDate, calendar: calendar)
        let dayCount = max(1, Int(round(end.timeIntervalSince(start) / 86400)))
        let window = DeepSeekUsageWindow(
            start: start,
            end: end,
            dayCount: dayCount,
            timeZoneSeconds: offsetSeconds,
            startDayKey: startDayKey,
            endDayKey: endDayKey)
        let plan = DeepSeekHistoryPlan(
            period: .rolling(days: dayCount),
            anchorDate: now,
            anchorDayKey: self.dayString(now, calendar: calendar),
            timeZoneSeconds: offsetSeconds,
            requestedStart: start,
            requestedEnd: end,
            requestedStartDayKey: startDayKey,
            requestedEndDayKey: endDayKey,
            requestedDays: dayCount,
            chunks: [window])
        let fold = try self.foldByAPIKeyChunk(
            amountData: amountData,
            costData: costData,
            window: window,
            calendar: calendar)
        return self.mergeByAPIKeyChunks([fold], plan: plan)
    }

    /// Decodes and folds one validated `[start, end)` amount/cost pair into compact aggregates so raw
    /// payloads are released before the next page begins.
    static func foldByAPIKeyChunk(
        amountData: Data,
        costData: Data,
        window: DeepSeekUsageWindow,
        calendar: Calendar) throws -> DeepSeekChunkFoldResult
    {
        try Task.checkCancellation()
        let (amount, cost) = try self.decodeByAPIKeyPayloads(amountData: amountData, costData: costData)

        var dayKeyByTimestamp: [Int: String] = [:]
        func dayKey(for time: Int) -> String {
            if let cached = dayKeyByTimestamp[time] {
                return cached
            }
            let formatted = self.dayString(fromUnix: time, calendar: calendar)
            dayKeyByTimestamp[time] = formatted
            return formatted
        }

        let amountTotals = try self.foldByAPIKeyAmount(
            amount,
            startSeconds: window.startSeconds,
            endSeconds: window.endSeconds,
            dayKey: dayKey)
        let currencyTotals = self.foldByAPIKeyCost(
            cost,
            startSeconds: window.startSeconds,
            endSeconds: window.endSeconds,
            dayKey: dayKey)

        return DeepSeekChunkFoldResult(
            window: window,
            dayTokens: amountTotals.dayTokens,
            dayModelRequests: amountTotals.dayModelRequests,
            dayFunctionRequests: amountTotals.dayFunctionRequests,
            categoryTotals: amountTotals.categoryTotals,
            modelTokens: amountTotals.modelTokens,
            apiKeyIDs: amountTotals.apiKeyIDs,
            currencyTotals: currencyTotals)
    }

    private struct FoldedByAPIKeyAmount {
        let dayTokens: [String: Int]
        let dayModelRequests: [String: Int]
        let dayFunctionRequests: [String: Int]
        let categoryTotals: [DeepSeekUsageCategory: Int]
        let modelTokens: [String: Int]
        let apiKeyIDs: Set<String>
    }

    private static func foldByAPIKeyAmount(
        _ amount: ByAPIKeyAmountBiz,
        startSeconds: Int,
        endSeconds: Int,
        dayKey: (Int) -> String) throws -> FoldedByAPIKeyAmount
    {
        var dayTokens: [String: Int] = [:]
        var dayModelRequests: [String: Int] = [:]
        var categoryTotals: [DeepSeekUsageCategory: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var apiKeyIDs = Set<String>()

        for series in amount.series {
            let model = series.model ?? "unknown"
            var sawInRangeBucket = false
            for bucket in series.buckets where bucket.time >= startSeconds && bucket.time < endSeconds {
                sawInRangeBucket = true
                let date = dayKey(bucket.time)
                for (type, scalar) in bucket.usage {
                    guard let category = DeepSeekUsageCategory(rawValue: type) else { continue }
                    guard let value = self.parseNonNegativeInt(scalar.value) else {
                        throw DeepSeekUsageError.parseFailed("Invalid \(type) amount in by_api_key chunk")
                    }
                    if category == .request {
                        dayModelRequests[date] = try self.checkedAddOrThrow(
                            dayModelRequests[date, default: 0],
                            value,
                            field: "by_api_key daily requests")
                    } else {
                        dayTokens[date] = try self.checkedAddOrThrow(
                            dayTokens[date, default: 0],
                            value,
                            field: "by_api_key daily tokens")
                        categoryTotals[category] = try self.checkedAddOrThrow(
                            categoryTotals[category, default: 0],
                            value,
                            field: "by_api_key category tokens")
                        modelTokens[model] = try self.checkedAddOrThrow(
                            modelTokens[model, default: 0],
                            value,
                            field: "by_api_key model tokens")
                    }
                }
            }
            if sawInRangeBucket, let id = series.apiKey?.id {
                apiKeyIDs.insert(id)
            }
        }

        // The Platform includes separately reported tool calls in its API-request total.
        var dayFunctionRequests: [String: Int] = [:]
        for series in amount.functionSeries ?? [] {
            for bucket in series.buckets where bucket.time >= startSeconds && bucket.time < endSeconds {
                guard let scalar = bucket.usage["FUNCTION_CALL"] else { continue }
                guard let calls = self.parseNonNegativeInt(scalar.value) else {
                    throw DeepSeekUsageError.parseFailed("Invalid FUNCTION_CALL amount in by_api_key chunk")
                }
                guard calls > 0 else { continue }
                let date = dayKey(bucket.time)
                dayFunctionRequests[date] = try self.checkedAddOrThrow(
                    dayFunctionRequests[date, default: 0],
                    calls,
                    field: "by_api_key function calls")
            }
        }

        // Reject within-window aggregate overflow before returning a fold so each chunk is self-consistent.
        try self.validateWithinChunkTotals(
            dayTokens: dayTokens,
            dayModelRequests: dayModelRequests,
            dayFunctionRequests: dayFunctionRequests,
            categoryTotals: categoryTotals,
            modelTokens: modelTokens)

        return FoldedByAPIKeyAmount(
            dayTokens: dayTokens,
            dayModelRequests: dayModelRequests,
            dayFunctionRequests: dayFunctionRequests,
            categoryTotals: categoryTotals,
            modelTokens: modelTokens,
            apiKeyIDs: apiKeyIDs)
    }

    private static func validateWithinChunkTotals(
        dayTokens: [String: Int],
        dayModelRequests: [String: Int],
        dayFunctionRequests: [String: Int],
        categoryTotals: [DeepSeekUsageCategory: Int],
        modelTokens: [String: Int]) throws
    {
        guard CheckedSum.integers(dayTokens.values) != nil else {
            throw DeepSeekUsageError.parseFailed("Overflow summing by_api_key chunk tokens")
        }
        guard CheckedSum.integers(tokenCategories.compactMap { categoryTotals[$0] }) != nil else {
            throw DeepSeekUsageError.parseFailed("Overflow summing by_api_key sibling token categories")
        }
        guard CheckedSum.integers(modelTokens.values) != nil else {
            throw DeepSeekUsageError.parseFailed("Overflow summing by_api_key model tokens")
        }
        var totalRequests = 0
        for date in Set(dayModelRequests.keys).union(dayFunctionRequests.keys) {
            let dayTotal = try self.checkedAddOrThrow(
                dayModelRequests[date, default: 0],
                dayFunctionRequests[date, default: 0],
                field: "by_api_key daily total requests")
            totalRequests = try self.checkedAddOrThrow(
                totalRequests,
                dayTotal,
                field: "by_api_key chunk requests")
        }
    }

    private static func foldByAPIKeyCost(
        _ cost: ByAPIKeyCostBiz,
        startSeconds: Int,
        endSeconds: Int,
        dayKey: (Int) -> String) -> [DeepSeekCurrencyContribution]
    {
        struct CurrencyAccumulator {
            var dayCosts: [String: Double] = [:]
            var unavailableCostDays = Set<String>()
            var modelCosts = ModelCostTotals()
            var apiKeyIDs = Set<String>()
            var hasIncompleteCost = false
        }

        var currencyOrder: [String] = []
        var currencyStates: [String: CurrencyAccumulator] = [:]
        for block in cost.data {
            let currency = block.currency
            if currencyStates[currency] == nil {
                currencyOrder.append(currency)
                currencyStates[currency] = CurrencyAccumulator()
            }
            var state = currencyStates[currency] ?? CurrencyAccumulator()
            for series in block.series {
                guard let buckets = series.buckets else {
                    state.modelCosts.add(nil, model: series.model)
                    state.hasIncompleteCost = true
                    continue
                }
                var sawInRangeBucket = false
                for bucket in buckets where bucket.time >= startSeconds && bucket.time < endSeconds {
                    sawInRangeBucket = true
                    let date = dayKey(bucket.time)
                    let parsedAmount = bucket.cost.flatMap { self.parseNonNegativeCost($0.value) }
                    state.modelCosts.add(parsedAmount, model: series.model)
                    if let parsedAmount {
                        if !state.unavailableCostDays.contains(date) {
                            if let next = self.checkedNonNegativeCostAdd(
                                state.dayCosts[date] ?? 0,
                                parsedAmount)
                            {
                                state.dayCosts[date] = next
                            } else {
                                state.unavailableCostDays.insert(date)
                                state.dayCosts.removeValue(forKey: date)
                            }
                        }
                    } else {
                        // Never infer a missing or malformed cost scalar as zero.
                        state.unavailableCostDays.insert(date)
                        state.dayCosts.removeValue(forKey: date)
                    }
                }
                if sawInRangeBucket, let id = series.apiKey?.id {
                    state.apiKeyIDs.insert(id)
                }
            }
            currencyStates[currency] = state
        }

        return currencyOrder.compactMap { currency -> DeepSeekCurrencyContribution? in
            guard let state = currencyStates[currency] else { return nil }
            return DeepSeekCurrencyContribution(
                currency: currency,
                dayCosts: state.dayCosts,
                unavailableCostDays: state.unavailableCostDays,
                modelCosts: state.modelCosts.totals,
                unavailableModels: state.modelCosts.unavailable,
                apiKeyIDs: state.apiKeyIDs,
                hasIncompleteCost: state.hasIncompleteCost)
        }
    }

    private struct MergedCurrencyState {
        var dayCosts: [String: Double] = [:]
        var unavailableCostDays = Set<String>()
        var modelCosts = ModelCostTotals()
        var apiKeyIDs = Set<String>()
        var hasIncompleteCost = false

        var totalSpend: Double {
            var total = 0.0
            for cost in self.dayCosts.values {
                guard let next = DeepSeekUsageCostParser.checkedNonNegativeCostAdd(total, cost) else {
                    return .infinity
                }
                total = next
            }
            return total
        }

        mutating func merge(_ contribution: DeepSeekCurrencyContribution) {
            self.apiKeyIDs.formUnion(contribution.apiKeyIDs)
            self.unavailableCostDays.formUnion(contribution.unavailableCostDays)
            self.hasIncompleteCost = self.hasIncompleteCost || contribution.hasIncompleteCost
            for (day, cost) in contribution.dayCosts where !self.unavailableCostDays.contains(day) {
                if let next = DeepSeekUsageCostParser.checkedNonNegativeCostAdd(self.dayCosts[day] ?? 0, cost) {
                    self.dayCosts[day] = next
                } else {
                    self.unavailableCostDays.insert(day)
                    self.dayCosts.removeValue(forKey: day)
                }
            }
            for day in self.unavailableCostDays {
                self.dayCosts.removeValue(forKey: day)
            }
            for unavailableModel in contribution.unavailableModels {
                self.modelCosts.add(nil, model: unavailableModel)
            }
            for (model, cost) in contribution.modelCosts {
                self.modelCosts.add(cost, model: model)
            }
        }
    }

    private struct MergedByAPIKeyAccumulator {
        var admittedChunks: [DeepSeekChunkFoldResult] = []
        var dayTokens: [String: Int] = [:]
        var dayModelRequests: [String: Int] = [:]
        var dayFunctionRequests: [String: Int] = [:]
        var categoryTotals: [DeepSeekUsageCategory: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var periodTokens = 0
        var periodRequests = 0
        var coveredDays = 0
        var apiKeyIDs = Set<String>()
        var currencyOrder: [String] = []
        var currencyStates: [String: MergedCurrencyState] = [:]

        /// Atomically merges `chunk` only if every metric is non-negative and all resulting
        /// day, category, model, and period totals fit within `Int` without overflow.
        mutating func tryMerge(_ chunk: DeepSeekChunkFoldResult) -> Bool {
            guard let nextCoveredDays = DeepSeekUsageCostParser.checkedNonNegativeAdd(
                self.coveredDays,
                chunk.window.dayCount),
                let (nextDayTokens, nextPeriodTokens) = Self.mergeDayTokens(
                    current: self.dayTokens,
                    currentPeriod: self.periodTokens,
                    adding: chunk.dayTokens),
                let (nextDayModelRequests, nextDayFunctionRequests, nextPeriodRequests) = Self.mergeDayRequests(
                    currentModel: self.dayModelRequests,
                    currentFunction: self.dayFunctionRequests,
                    currentPeriod: self.periodRequests,
                    addingModel: chunk.dayModelRequests,
                    addingFunction: chunk.dayFunctionRequests),
                let nextCategoryTotals = Self.mergeCategoryTotals(
                    current: self.categoryTotals,
                    adding: chunk.categoryTotals),
                let nextModelTokens = Self.mergeModelTokens(
                    current: self.modelTokens,
                    adding: chunk.modelTokens)
            else {
                return false
            }

            self.admittedChunks.append(chunk)
            self.dayTokens = nextDayTokens
            self.dayModelRequests = nextDayModelRequests
            self.dayFunctionRequests = nextDayFunctionRequests
            self.categoryTotals = nextCategoryTotals
            self.modelTokens = nextModelTokens
            self.periodTokens = nextPeriodTokens
            self.periodRequests = nextPeriodRequests
            self.coveredDays = nextCoveredDays
            self.apiKeyIDs.formUnion(chunk.apiKeyIDs)

            for contribution in chunk.currencyTotals {
                if self.currencyStates[contribution.currency] == nil {
                    self.currencyOrder.append(contribution.currency)
                    self.currencyStates[contribution.currency] = MergedCurrencyState()
                }
                self.currencyStates[contribution.currency]?.merge(contribution)
            }
            return true
        }

        /// Per-key checked non-negative addition; `nil` when any key is negative or overflows `Int`.
        private static func checkedAdd<Key: Hashable>(_ deltas: [Key: Int], to map: [Key: Int]) -> [Key: Int]? {
            var next = map
            for (key, delta) in deltas {
                guard let updated = DeepSeekUsageCostParser.checkedNonNegativeAdd(next[key, default: 0], delta)
                else { return nil }
                next[key] = updated
            }
            return next
        }

        private static func mergeDayTokens(
            current: [String: Int],
            currentPeriod: Int,
            adding: [String: Int]) -> ([String: Int], Int)?
        {
            guard let nextDays = checkedAdd(adding, to: current),
                  let periodDelta = CheckedSum.integers(adding.values),
                  let nextPeriod = DeepSeekUsageCostParser.checkedNonNegativeAdd(currentPeriod, periodDelta)
            else { return nil }
            return (nextDays, nextPeriod)
        }

        private static func mergeDayRequests(
            currentModel: [String: Int],
            currentFunction: [String: Int],
            currentPeriod: Int,
            addingModel: [String: Int],
            addingFunction: [String: Int]) -> ([String: Int], [String: Int], Int)?
        {
            guard let nextModel = checkedAdd(addingModel, to: currentModel),
                  let nextFunction = checkedAdd(addingFunction, to: currentFunction)
            else { return nil }
            var nextPeriod = currentPeriod
            for day in Set(addingModel.keys).union(addingFunction.keys) {
                guard DeepSeekUsageCostParser.checkedNonNegativeAdd(
                    nextModel[day, default: 0],
                    nextFunction[day, default: 0]) != nil,
                    let chunkDelta = DeepSeekUsageCostParser.checkedNonNegativeAdd(
                        addingModel[day, default: 0],
                        addingFunction[day, default: 0]),
                    let updatedPeriod = DeepSeekUsageCostParser.checkedNonNegativeAdd(nextPeriod, chunkDelta)
                else { return nil }
                nextPeriod = updatedPeriod
            }
            return (nextModel, nextFunction, nextPeriod)
        }

        private static func mergeCategoryTotals(
            current: [DeepSeekUsageCategory: Int],
            adding: [DeepSeekUsageCategory: Int]) -> [DeepSeekUsageCategory: Int]?
        {
            guard let next = checkedAdd(adding, to: current),
                  CheckedSum.integers(DeepSeekUsageCostParser.tokenCategories.compactMap { next[$0] }) != nil
            else { return nil }
            return next
        }

        private static func mergeModelTokens(
            current: [String: Int],
            adding: [String: Int]) -> [String: Int]?
        {
            guard let next = checkedAdd(adding, to: current),
                  CheckedSum.integers(next.values) != nil
            else { return nil }
            return next
        }
    }

    /// Merges disjoint validated chunk folds into one summary, selecting a single preferred currency
    /// across the combined range and computing truthful coverage intervals. Chunks whose totals are
    /// invalid or would overflow `Int` across windows are excluded so coverage stays honestly partial.
    package static func mergeByAPIKeyChunks(
        _ chunks: [DeepSeekChunkFoldResult],
        plan: DeepSeekHistoryPlan,
        failedChunkCount: Int = 0) -> DeepSeekUsageSummary
    {
        // Keep only planned windows in this plan, deduplicating by exact window (latest replacement wins).
        let plannedWindows = Set(plan.chunks)
        var byWindow: [DeepSeekUsageWindow: DeepSeekChunkFoldResult] = [:]
        for chunk in chunks where plannedWindows.contains(chunk.window) {
            byWindow[chunk.window] = chunk
        }
        // Preserve plan order (newest-first) when iterating so currency tie-breaking favors recent order.
        let orderedChunks = plan.chunks.compactMap { byWindow[$0] }

        var merged = MergedByAPIKeyAccumulator()
        for chunk in orderedChunks {
            _ = merged.tryMerge(chunk)
        }

        let selectedCurrency = self.preferredCurrency(order: merged.currencyOrder, spend: { currency in
            merged.currencyStates[currency]?.totalSpend ?? 0
        })
        let selectedState = merged.currencyStates[selectedCurrency]
        var apiKeyIDs = merged.apiKeyIDs
        if let selectedKeys = selectedState?.apiKeyIDs {
            apiKeyIDs.formUnion(selectedKeys)
        }
        let dayCosts = selectedState?.dayCosts ?? [:]
        let unavailableCostDays = selectedState?.unavailableCostDays ?? []
        let hasIncompleteCost = selectedState?.hasIncompleteCost ?? false

        let dates = Set(merged.dayTokens.keys)
            .union(merged.dayModelRequests.keys)
            .union(merged.dayFunctionRequests.keys)
            .union(dayCosts.keys)
            .union(unavailableCostDays)

        var daily: [DeepSeekDailyUsage] = []
        daily.reserveCapacity(dates.count)
        for date in dates.sorted() {
            let tokens = merged.dayTokens[date, default: 0]
            let requests = self.checkedNonNegativeAdd(
                merged.dayModelRequests[date, default: 0],
                merged.dayFunctionRequests[date, default: 0]) ?? 0
            let cost = (hasIncompleteCost || unavailableCostDays.contains(date)) ? nil : dayCosts[date]
            daily.append(DeepSeekDailyUsage(
                date: date,
                totalTokens: tokens,
                cost: cost,
                requestCount: requests))
        }

        let breakdown = Self.tokenCategories.map { category in
            DeepSeekCategoryBreakdown(category: category, tokens: merged.categoryTotals[category] ?? 0, cost: nil)
        }
        let topModel = merged.modelTokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key

        let coveredWindowsAscending = merged.admittedChunks.map(\.window).sorted { $0.startSeconds < $1.startSeconds }
        let coveredIntervals = self.coalescedDayIntervals(from: coveredWindowsAscending)
        let missingChunks = max(failedChunkCount, plan.chunks.count - merged.admittedChunks.count)
        let coverage = DeepSeekUsageCoverage(
            requestedPeriod: plan.period,
            requestedStartDay: plan.requestedStartDayKey,
            requestedEndDay: plan.requestedEndDayKey,
            requestedDays: plan.requestedDays,
            coveredIntervals: coveredIntervals,
            coveredDays: merged.coveredDays,
            failedChunkCount: missingChunks)

        let today = daily.first { $0.date == plan.anchorDayKey }
        let todayCost: Double? = (hasIncompleteCost || unavailableCostDays.contains(plan.anchorDayKey))
            ? nil
            : dayCosts[plan.anchorDayKey]
        let periodCost = self.summedPeriodCost(
            dayCosts: dayCosts,
            hasAdmittedChunks: !merged.admittedChunks.isEmpty,
            hasIncompleteCost: hasIncompleteCost,
            unavailableCostDays: unavailableCostDays)

        return DeepSeekUsageSummary(
            todayTokens: today?.totalTokens ?? 0,
            currentMonthTokens: merged.periodTokens,
            todayCost: todayCost,
            currentMonthCost: periodCost,
            requestCount: today?.requestCount ?? 0,
            currentMonthRequestCount: merged.periodRequests,
            topModel: topModel,
            categoryBreakdown: breakdown,
            daily: daily,
            currency: selectedCurrency,
            modelCosts: selectedState?.modelCosts.values ?? [],
            apiKeyCount: apiKeyIDs.count,
            period: .last30Days,
            coverage: coverage,
            timeZoneSeconds: plan.timeZoneSeconds,
            updatedAt: plan.anchorDate)
    }

    private static func summedPeriodCost(
        dayCosts: [String: Double],
        hasAdmittedChunks: Bool,
        hasIncompleteCost: Bool,
        unavailableCostDays: Set<String>) -> Double?
    {
        guard hasAdmittedChunks, !hasIncompleteCost, unavailableCostDays.isEmpty else { return nil }
        var total = 0.0
        for cost in dayCosts.values {
            guard let next = self.checkedNonNegativeCostAdd(total, cost) else { return nil }
            total = next
        }
        return total
    }

    private static func preferredCurrency(order: [String], spend: (String) -> Double) -> String {
        if order.contains("USD"), spend("USD") > 0 {
            return "USD"
        }
        if let firstPositive = order.first(where: { spend($0) > 0 }) {
            return firstPositive
        }
        if order.contains("USD") {
            return "USD"
        }
        return order.first ?? "CNY"
    }

    private static func coalescedDayIntervals(from ascendingWindows: [DeepSeekUsageWindow]) -> [CostUsageDayInterval] {
        guard !ascendingWindows.isEmpty else { return [] }
        var intervals: [CostUsageDayInterval] = []
        var currentStartDay = ascendingWindows[0].startDayKey
        var currentEndDay = ascendingWindows[0].endDayKey
        var currentEndSeconds = ascendingWindows[0].endSeconds

        for window in ascendingWindows.dropFirst() {
            if window.startSeconds == currentEndSeconds {
                currentEndDay = window.endDayKey
                currentEndSeconds = window.endSeconds
            } else {
                intervals.append(CostUsageDayInterval(startDay: currentStartDay, endDay: currentEndDay))
                currentStartDay = window.startDayKey
                currentEndDay = window.endDayKey
                currentEndSeconds = window.endSeconds
            }
        }
        intervals.append(CostUsageDayInterval(startDay: currentStartDay, endDay: currentEndDay))
        return intervals
    }

    private static func decodeByAPIKeyPayloads(amountData: Data, costData: Data) throws
        -> (ByAPIKeyAmountBiz, ByAPIKeyCostBiz)
    {
        let amount: ByAPIKeyEnvelope<ByAPIKeyAmountBiz>
        let cost: ByAPIKeyEnvelope<ByAPIKeyCostBiz>
        do {
            amount = try JSONDecoder().decode(ByAPIKeyEnvelope<ByAPIKeyAmountBiz>.self, from: amountData)
        } catch {
            throw DeepSeekUsageError.parseFailed("amount: \(self.decodingFailureDescription(error))")
        }
        do {
            cost = try JSONDecoder().decode(ByAPIKeyEnvelope<ByAPIKeyCostBiz>.self, from: costData)
        } catch {
            throw DeepSeekUsageError.parseFailed("cost: \(self.decodingFailureDescription(error))")
        }
        if let code = amount.code, code != 0 {
            if self.isAuthenticationError(code) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("amount code \(code)")
        }
        if let code = cost.code, code != 0 {
            if self.isAuthenticationError(code) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("cost code \(code)")
        }
        if let bizCode = amount.data?.bizCode, bizCode != 0 {
            if self.isAuthenticationError(bizCode) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("amount biz_code \(bizCode)")
        }
        if let bizCode = cost.data?.bizCode, bizCode != 0 {
            if self.isAuthenticationError(bizCode) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("cost biz_code \(bizCode)")
        }
        guard let amountBiz = amount.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing amount biz_data")
        }
        guard let costBiz = cost.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing cost biz_data")
        }

        return (amountBiz, costBiz)
    }

    private static func dayString(fromUnix time: Int, calendar: Calendar) -> String {
        self.dayString(Date(timeIntervalSince1970: TimeInterval(time)), calendar: calendar)
    }
}

private struct ByAPIKeyEnvelope<BizData: Decodable>: Decodable {
    let code: Int?
    let data: ByAPIKeyEnvelopeData<BizData>?

    private enum CodingKeys: String, CodingKey {
        case code, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        if let code, code != 0 {
            // Preserve error codes even when an error envelope carries an unexpected `data` shape.
            self.data = try? container.decodeIfPresent(ByAPIKeyEnvelopeData<BizData>.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(ByAPIKeyEnvelopeData<BizData>.self, forKey: .data)
        }
    }
}

private struct ByAPIKeyEnvelopeData<BizData: Decodable>: Decodable {
    let bizCode: Int?
    let bizData: BizData?

    private enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent(BizData.self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent(BizData.self, forKey: .bizData)
        }
    }
}

private struct ByAPIKeyAmountBiz: Decodable {
    let series: [ByAPIKeyAmountSeries]
    let functionSeries: [ByAPIKeyAmountSeries]?

    private enum CodingKeys: String, CodingKey {
        case series
        case functionSeries = "function_series"
    }
}

private struct ByAPIKeyAmountSeries: Decodable {
    let apiKey: ByAPIKeyIdentity?
    let model: String?
    let buckets: [ByAPIKeyAmountBucket]

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model, buckets
    }
}

private struct ByAPIKeyAmountBucket: Decodable {
    let time: Int
    let usage: [String: ByAPIKeyScalar]
}

private struct ByAPIKeyCostBiz: Decodable {
    let data: [ByAPIKeyCostCurrency]
}

private struct ByAPIKeyCostCurrency: Decodable {
    let currency: String
    let series: [ByAPIKeyCostSeries]

    private enum CodingKeys: String, CodingKey {
        case currency, series
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCurrency = try container.decode(String.self, forKey: .currency)
        let trimmed = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .currency,
                in: container,
                debugDescription: "Expected a non-empty currency code")
        }
        self.currency = trimmed
        self.series = try container.decode([ByAPIKeyCostSeries].self, forKey: .series)
    }
}

private struct ByAPIKeyCostSeries: Decodable {
    let apiKey: ByAPIKeyIdentity?
    let model: String?
    let buckets: [ByAPIKeyCostBucket]?

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model, buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKey = try container.decodeIfPresent(ByAPIKeyIdentity.self, forKey: .apiKey)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.buckets = try container.decodeIfPresent([ByAPIKeyCostBucket].self, forKey: .buckets)
        if self.buckets == nil, self.model == nil, self.apiKey == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.buckets,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized cost series entry missing buckets, model, and api_key"))
        }
    }
}

private struct ByAPIKeyCostBucket: Decodable {
    let time: Int
    let cost: ByAPIKeyScalar?

    private enum CodingKeys: String, CodingKey {
        case time, cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.time = try container.decode(Int.self, forKey: .time)
        guard container.contains(.cost) else {
            throw DecodingError.keyNotFound(
                CodingKeys.cost,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing cost field in cost bucket"))
        }
        self.cost = try container.decodeIfPresent(ByAPIKeyScalar.self, forKey: .cost)
    }
}

private struct ByAPIKeyIdentity: Decodable {
    let name: String?
    let trackingID: String?
    enum CodingKeys: String, CodingKey { case name; case trackingID = "tracking_id" }

    init(from decoder: Decoder) throws {
        if let trackingID = try? decoder.singleValueContainer().decode(String.self) {
            self.trackingID = trackingID
            self.name = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.trackingID = try container.decodeIfPresent(String.self, forKey: .trackingID)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    var id: String {
        let tracking = self.trackingID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tracking.isEmpty {
            return tracking
        }
        let name = self.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "unknown" : name
    }
}

private struct ByAPIKeyScalar: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = String(double)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a scalar usage value"))
        }
    }
}

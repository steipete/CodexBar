import Foundation

extension MiniMaxUsageSummary {
    public var hasProjectableCost: Bool {
        self.days.contains { self.projectedCostUSD(for: $0) != nil }
    }

    public func projectedCostUSD(for day: MiniMaxUsageSummaryDay) -> Double? {
        let breakdown = self.projectedModelBreakdowns(for: day)
        guard breakdown.contains(where: { $0.costUSD != nil }) else { return nil }
        return breakdown.compactMap(\.costUSD).reduce(0, +)
    }

    public func projectedCostUSD(lastDays: Int) -> Double? {
        let days = self.trendDays(last: lastDays)
        var total = 0.0
        var seen = false
        for day in days {
            guard let cost = self.projectedCostUSD(for: day) else { continue }
            total += cost
            seen = true
        }
        return seen ? total : nil
    }

    public func projectedModelBreakdowns(
        for day: MiniMaxUsageSummaryDay) -> [CostUsageDailyReport.ModelBreakdown]
    {
        if !day.models.isEmpty {
            return day.models.compactMap { model in
                guard let costUSD = MiniMaxUsagePricing.minimaxCostUSD(
                    model: model.model,
                    inputToken: model.inputToken,
                    cacheReadToken: model.cacheReadToken,
                    cacheCreateToken: model.cacheCreateToken,
                    outputToken: model.outputToken)
                else {
                    return nil
                }
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: model.model,
                    costUSD: costUSD,
                    totalTokens: model.totalToken)
            }
        }

        guard day.totalToken > 0,
              let costUSD = MiniMaxUsagePricing.minimaxCostUSD(
                  model: "MiniMax-M2.7",
                  inputToken: day.totalInputToken,
                  cacheReadToken: day.totalCacheReadToken,
                  cacheCreateToken: day.totalCacheCreateToken,
                  outputToken: day.totalOutputToken)
        else {
            return []
        }

        return [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "Day totals",
                costUSD: costUSD,
                totalTokens: day.totalToken),
        ]
    }

    public func toCostUsageTokenSnapshot(
        historyDays: Int = 30,
        now: Date = Date()) -> CostUsageTokenSnapshot?
    {
        guard self.hasDisplayableData else { return nil }

        let clampedHistoryDays = max(1, min(365, historyDays))
        let selectedDays = Array(self.days.suffix(clampedHistoryDays))
        guard !selectedDays.isEmpty else { return nil }

        var entries: [CostUsageDailyReport.Entry] = []
        entries.reserveCapacity(selectedDays.count)
        var windowCost = 0.0
        var windowCostSeen = false
        var windowTokens = 0

        for day in selectedDays {
            let breakdown = self.projectedModelBreakdowns(for: day)
            let dayCost = breakdown.compactMap(\.costUSD).reduce(0, +)
            let hasCost = breakdown.contains { $0.costUSD != nil }
            if hasCost {
                windowCost += dayCost
                windowCostSeen = true
            }
            windowTokens += day.totalToken

            entries.append(CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: day.totalInputToken,
                outputTokens: day.totalOutputToken,
                cacheReadTokens: day.totalCacheReadToken > 0 ? day.totalCacheReadToken : nil,
                cacheCreationTokens: day.totalCacheCreateToken > 0 ? day.totalCacheCreateToken : nil,
                totalTokens: day.totalToken,
                costUSD: hasCost ? dayCost : nil,
                modelsUsed: breakdown.isEmpty ? nil : breakdown.map(\.modelName),
                modelBreakdowns: breakdown.isEmpty ? nil : breakdown))
        }

        guard windowCostSeen else { return nil }
        if windowCost == 0, self.isPlanIncludedOnly(days: selectedDays) {
            return nil
        }

        let latestEntry = entries.last
        let sessionTokens = self.snapshotDay?.totalToken ?? latestEntry?.totalTokens
        let sessionCostUSD = self.snapshotDay.flatMap { day in
            entries.first(where: { $0.date == day.date })?.costUSD
        } ?? latestEntry?.costUSD

        return CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: windowTokens > 0 ? windowTokens : nil,
            last30DaysCostUSD: windowCostSeen ? windowCost : nil,
            currencyCode: "USD",
            historyDays: clampedHistoryDays,
            historyLabel: nil,
            daily: entries,
            updatedAt: now)
    }

    private func isPlanIncludedOnly(days: [MiniMaxUsageSummaryDay]) -> Bool {
        let models = days.flatMap(\.models)
        return !models.isEmpty && models.allSatisfy {
            MiniMaxUsagePricing.normalizeModel($0.model).contains("coding-plan")
        }
    }
}

import Foundation

extension DeepSeekUsageSummary {
    public var hasDisplayableData: Bool {
        if self.todayTokens > 0 || self.currentMonthTokens > 0 { return true }
        return !self.daily.isEmpty
    }

    public var currencySymbol: String {
        self.currency == "CNY" ? "¥" : "$"
    }

    public var prefersCostTrend: Bool {
        self.daily.contains { ($0.cost ?? 0) > 0 }
    }

    public var last7DaysTokens: Int {
        self.daysWithinRollingWindow(dayCount: 7).reduce(0) { $0 + $1.totalTokens }
    }

    public var last30DaysTokens: Int {
        self.daysWithinRollingWindow(dayCount: 30).reduce(0) { $0 + $1.totalTokens }
    }

    public var last7DaysCost: Double? {
        self.summedCost(self.daysWithinRollingWindow(dayCount: 7))
    }

    public var last30DaysCost: Double? {
        self.summedCost(self.daysWithinRollingWindow(dayCount: 30))
    }

    public var cacheHitPercent: Double? {
        Self.cacheHitPercent(
            hitTokens: self.categoryBreakdown.first { $0.category == .promptCacheHitToken }?.tokens ?? 0,
            missTokens: self.categoryBreakdown.first { $0.category == .promptCacheMissToken }?.tokens ?? 0)
    }

    public func trendDays(last count: Int) -> [DeepSeekDailyUsage] {
        self.daysWithinRollingWindow(dayCount: max(1, count))
    }

    public func toCostUsageTokenSnapshot(historyDays: Int = 30) -> CostUsageTokenSnapshot {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let selected = self.daily
        let entries = selected.map { day in
            let modelBreakdowns = day.models.map {
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0.model,
                    costUSD: $0.cost.map { max($0, 0) },
                    totalTokens: $0.tokens)
            }
            let modelsUsed = day.models.map(\.model)
            let inputTokens = day.models.reduce(0) { $0 + $1.cacheHitTokens + $1.cacheMissTokens }
            let outputTokens = day.models.reduce(0) { $0 + $1.outputTokens }
            return CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: inputTokens > 0 ? inputTokens : nil,
                outputTokens: outputTokens > 0 ? outputTokens : nil,
                cacheReadTokens: {
                    let value = day.models.reduce(0) { $0 + $1.cacheHitTokens }
                    return value > 0 ? value : nil
                }(),
                cacheCreationTokens: nil,
                totalTokens: day.totalTokens,
                costUSD: day.cost.map { max($0, 0) },
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: self.todayTokens > 0 ? self.todayTokens : nil,
            sessionCostUSD: self.todayCost.map { max($0, 0) },
            sessionRequests: self.requestCount > 0 ? self.requestCount : nil,
            last30DaysTokens: {
                if self.currentMonthTokens > 0 { return self.currentMonthTokens }
                return self.last30DaysTokens > 0 ? self.last30DaysTokens : nil
            }(),
            last30DaysCostUSD: self.currentMonthCost.map { max($0, 0) } ?? self.last30DaysCost,
            last30DaysRequests: self.currentMonthRequestCount > 0 ? self.currentMonthRequestCount : nil,
            currencyCode: self.currency,
            historyDays: selected.isEmpty ? clampedHistoryDays : max(1, min(365, selected.count)),
            historyLabel: "This month",
            daily: entries,
            updatedAt: self.updatedAt)
    }

    static func cacheHitPercent(hitTokens: Int, missTokens: Int) -> Double? {
        let input = hitTokens + missTokens
        guard input > 0 else { return nil }
        return Double(hitTokens) / Double(input) * 100
    }

    func daysWithinRollingWindow(dayCount: Int) -> [DeepSeekDailyUsage] {
        let calendar = Self.displayCalendar
        let endDay = calendar.startOfDay(for: self.updatedAt)
        guard let windowStart = calendar.date(byAdding: .day, value: -(max(1, dayCount) - 1), to: endDay) else {
            return []
        }
        return self.daily.filter { day in
            guard let date = Self.dayKeyFormatter.date(from: day.date) else { return false }
            let dayStart = calendar.startOfDay(for: date)
            return dayStart >= windowStart && dayStart <= endDay
        }
        .sorted { $0.date < $1.date }
    }

    private static var displayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Self.displayCalendar
        formatter.timeZone = Self.displayCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func summedCost(_ days: some Sequence<DeepSeekDailyUsage>) -> Double? {
        var total: Double?
        for day in days {
            guard let cost = day.cost else { continue }
            total = (total ?? 0) + max(cost, 0)
        }
        return total
    }
}

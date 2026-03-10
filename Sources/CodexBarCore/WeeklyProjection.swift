import Foundation

public struct WeeklyProjectionPoint: Sendable {
    public let dayOfWeek: Int // 1=Mon ... 7=Sun
    public let dayLabel: String // "Mon", "Tue", ...
    public let thisWeekValue: Double? // actual data point
    public let lastWeekValue: Double? // comparison point
    public let projectedValue: Double? // extrapolated (future days only)

    public init(
        dayOfWeek: Int,
        dayLabel: String,
        thisWeekValue: Double?,
        lastWeekValue: Double?,
        projectedValue: Double?)
    {
        self.dayOfWeek = dayOfWeek
        self.dayLabel = dayLabel
        self.thisWeekValue = thisWeekValue
        self.lastWeekValue = lastWeekValue
        self.projectedValue = projectedValue
    }
}

public struct WeeklyProjection: Sendable {
    public let points: [WeeklyProjectionPoint]
    public let metric: Metric
    public let thisWeekTotal: Double?
    public let lastWeekTotal: Double?
    public let projectedEndOfWeek: Double?
    public let changePercent: Double? // week-over-week change

    public enum Metric: Sendable {
        case percentage
        case tokens
        case cost
    }

    public init(
        points: [WeeklyProjectionPoint],
        metric: Metric,
        thisWeekTotal: Double?,
        lastWeekTotal: Double?,
        projectedEndOfWeek: Double?,
        changePercent: Double?)
    {
        self.points = points
        self.metric = metric
        self.thisWeekTotal = thisWeekTotal
        self.lastWeekTotal = lastWeekTotal
        self.projectedEndOfWeek = projectedEndOfWeek
        self.changePercent = changePercent
    }

    public static func compute(
        currentWeek: [WeeklyUsageRecord],
        previousWeek: [WeeklyUsageRecord],
        now: Date = Date()) -> WeeklyProjection
    {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        let todayDayOfWeek = cal.component(.weekday, from: now)
        // Convert from Calendar weekday (1=Sun...7=Sat) to ISO 8601 (1=Mon...7=Sun)
        let isoDayOfWeek = todayDayOfWeek == 1 ? 7 : todayDayOfWeek - 1

        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        // Build lookup dictionaries by dayOfWeek
        let currentByDay = Dictionary(uniqueKeysWithValues: currentWeek.map { ($0.dayOfWeek, $0) })
        let previousByDay = Dictionary(uniqueKeysWithValues: previousWeek.map { ($0.dayOfWeek, $0) })

        // Determine which metric to use: prefer percentage, fall back to tokens, then cost
        let metric = Self.detectMetric(currentWeek: currentWeek, previousWeek: previousWeek)

        // Compute average daily rate from this week's data.
        // For percentage (cumulative): daily rate = latestValue / daysElapsed
        // For tokens/cost (non-cumulative daily values): daily rate = mean of values
        let currentValues = currentWeek.compactMap { Self.value(for: $0, metric: metric) }
        let daysWithData = currentValues.count
        let latestValue = currentWeek
            .max { $0.dayOfWeek < $1.dayOfWeek }
            .flatMap { Self.value(for: $0, metric: metric) }
        let avgDailyRate: Double? = if daysWithData > 0 {
            switch metric {
            case .percentage:
                (latestValue ?? 0) / Double(daysWithData)
            case .tokens, .cost:
                currentValues.reduce(0, +) / Double(daysWithData)
            }
        } else {
            nil
        }

        var points: [WeeklyProjectionPoint] = []
        for day in 1...7 {
            let label = dayLabels[day - 1]
            let currentRecord = currentByDay[day]
            let previousRecord = previousByDay[day]

            let thisWeekValue = currentRecord.flatMap { Self.value(for: $0, metric: metric) }
            let lastWeekValue = previousRecord.flatMap { Self.value(for: $0, metric: metric) }

            // Only project future days (after today)
            let projectedValue: Double? = if day > isoDayOfWeek, let avgDailyRate {
                switch metric {
                case .percentage:
                    // Cumulative: project what the running total will be on that day
                    (latestValue ?? 0) + avgDailyRate * Double(day - isoDayOfWeek)
                case .tokens, .cost:
                    // Non-cumulative: flat daily rate per future day
                    avgDailyRate
                }
            } else {
                nil
            }

            points.append(WeeklyProjectionPoint(
                dayOfWeek: day,
                dayLabel: label,
                thisWeekValue: thisWeekValue,
                lastWeekValue: lastWeekValue,
                projectedValue: projectedValue))
        }

        // Compute totals
        let thisWeekTotal = Self.total(for: currentWeek, metric: metric)
        let lastWeekTotal = Self.total(for: previousWeek, metric: metric)

        // Project end-of-week
        let projectedEndOfWeek: Double? = if let thisWeekTotal, let avgDailyRate {
            thisWeekTotal + avgDailyRate * Double(max(0, 7 - isoDayOfWeek))
        } else {
            nil
        }

        // Week-over-week change
        let changePercent: Double? = if let thisWeekTotal, let lastWeekTotal, lastWeekTotal > 0 {
            ((thisWeekTotal - lastWeekTotal) / lastWeekTotal) * 100
        } else {
            nil
        }

        return WeeklyProjection(
            points: points,
            metric: metric,
            thisWeekTotal: thisWeekTotal,
            lastWeekTotal: lastWeekTotal,
            projectedEndOfWeek: projectedEndOfWeek,
            changePercent: changePercent)
    }

    // MARK: - Private

    private static func detectMetric(
        currentWeek: [WeeklyUsageRecord],
        previousWeek: [WeeklyUsageRecord]) -> Metric
    {
        let allRecords = currentWeek + previousWeek
        let hasPercent = allRecords.contains { $0.weeklyUsedPercent != nil }
        if hasPercent { return .percentage }
        let hasTokens = allRecords.contains { $0.totalTokens != nil }
        if hasTokens { return .tokens }
        return .cost
    }

    private static func value(for record: WeeklyUsageRecord, metric: Metric) -> Double? {
        switch metric {
        case .percentage:
            record.weeklyUsedPercent
        case .tokens:
            record.totalTokens.map(Double.init)
        case .cost:
            record.costUSD
        }
    }

    private static func total(for records: [WeeklyUsageRecord], metric: Metric) -> Double? {
        let values = records.compactMap { Self.value(for: $0, metric: metric) }
        guard !values.isEmpty else { return nil }
        switch metric {
        case .percentage:
            // For percentage, use the latest (highest dayOfWeek) value as the "total"
            return records
                .max { $0.dayOfWeek < $1.dayOfWeek }
                .flatMap { Self.value(for: $0, metric: metric) }
        case .tokens, .cost:
            return values.reduce(0, +)
        }
    }
}

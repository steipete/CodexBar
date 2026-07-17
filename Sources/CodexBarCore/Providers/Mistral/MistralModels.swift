import Foundation

// MARK: - API Response Models

/// Top-level response from `GET https://admin.mistral.ai/api/billing/v2/usage`.
struct MistralBillingResponse: Codable {
    let completion: MistralModelUsageCategory?
    let ocr: MistralModelUsageCategory?
    let connectors: MistralModelUsageCategory?
    let librariesApi: MistralLibrariesUsageCategory?
    let fineTuning: MistralFineTuningCategory?
    let audio: MistralModelUsageCategory?
    let vibeUsage: Double?
    let date: String?
    let previousMonth: String?
    let nextMonth: String?
    let startDate: String?
    let endDate: String?
    let currency: String?
    let currencySymbol: String?
    let prices: [MistralPrice]?

    enum CodingKeys: String, CodingKey {
        case completion, ocr, connectors, audio, date, currency, prices
        case librariesApi = "libraries_api"
        case fineTuning = "fine_tuning"
        case vibeUsage = "vibe_usage"
        case previousMonth = "previous_month"
        case nextMonth = "next_month"
        case startDate = "start_date"
        case endDate = "end_date"
        case currencySymbol = "currency_symbol"
    }
}

struct MistralModelUsageCategory: Codable {
    let models: [String: MistralModelUsageData]?
}

struct MistralLibrariesUsageCategory: Codable {
    let pages: MistralModelUsageCategory?
    let tokens: MistralModelUsageCategory?
}

struct MistralFineTuningCategory: Codable {
    let training: [String: MistralModelUsageData]?
    let storage: [String: MistralModelUsageData]?
}

struct MistralModelUsageData: Codable {
    let input: [MistralUsageEntry]?
    let output: [MistralUsageEntry]?
    let cached: [MistralUsageEntry]?
}

struct MistralUsageEntry: Codable {
    let usageType: String?
    let eventType: String?
    let billingMetric: String?
    let billingDisplayName: String?
    let billingGroup: String?
    let timestamp: String?
    let value: Int?
    let valuePaid: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, value
        case usageType = "usage_type"
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingDisplayName = "billing_display_name"
        case billingGroup = "billing_group"
        case valuePaid = "value_paid"
    }
}

struct MistralPrice: Codable {
    let eventType: String?
    let billingMetric: String?
    let billingGroup: String?
    let price: String?

    enum CodingKeys: String, CodingKey {
        case price
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingGroup = "billing_group"
    }
}

// MARK: - Intermediate Snapshot

public struct MistralDailyUsageBucket: Codable, Equatable, Sendable, Identifiable {
    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let cost: Double
        public let inputTokens: Int
        public let cachedTokens: Int
        public let outputTokens: Int

        public var id: String {
            self.name
        }

        public var totalTokens: Int {
            self.inputTokens + self.cachedTokens + self.outputTokens
        }

        public init(name: String, cost: Double, inputTokens: Int, cachedTokens: Int, outputTokens: Int) {
            self.name = name
            self.cost = cost
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
        }
    }

    public let day: String
    public let cost: Double
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let models: [ModelBreakdown]

    public var id: String {
        self.day
    }

    public var totalTokens: Int {
        self.inputTokens + self.cachedTokens + self.outputTokens
    }

    public init(
        day: String,
        cost: Double,
        inputTokens: Int,
        cachedTokens: Int,
        outputTokens: Int,
        models: [ModelBreakdown])
    {
        self.day = day
        self.cost = cost
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.models = models
    }
}

public struct MistralUsageSnapshot: Codable, Sendable {
    public let totalCost: Double
    public let currency: String
    public let currencySymbol: String
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCachedTokens: Int
    public let modelCount: Int
    public let daily: [MistralDailyUsageBucket]
    public let credits: MistralCreditsSnapshot?
    public let startDate: Date?
    public let endDate: Date?
    public let updatedAt: Date

    public init(
        totalCost: Double,
        currency: String,
        currencySymbol: String,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCachedTokens: Int,
        modelCount: Int,
        daily: [MistralDailyUsageBucket] = [],
        credits: MistralCreditsSnapshot? = nil,
        startDate: Date?,
        endDate: Date?,
        updatedAt: Date)
    {
        self.totalCost = totalCost
        self.currency = currency
        self.currencySymbol = currencySymbol
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.modelCount = modelCount
        self.daily = daily.sorted { $0.day < $1.day }
        self.credits = credits
        self.startDate = startDate
        self.endDate = endDate
        self.updatedAt = updatedAt
    }

    public func with(credits: MistralCreditsSnapshot?) -> MistralUsageSnapshot {
        MistralUsageSnapshot(
            totalCost: self.totalCost,
            currency: self.currency,
            currencySymbol: self.currencySymbol,
            totalInputTokens: self.totalInputTokens,
            totalOutputTokens: self.totalOutputTokens,
            totalCachedTokens: self.totalCachedTokens,
            modelCount: self.modelCount,
            daily: self.daily,
            credits: credits,
            startDate: self.startDate,
            endDate: self.endDate,
            updatedAt: self.updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Negative totalCost means a refund/credit adjustment; clamp to zero rather than
        // showing a confusing negative amount in the menu bar.
        let spendText = if self.totalCost > 0 {
            "\(self.currencySymbol)\(String(format: "%.4f", self.totalCost)) this month"
        } else {
            "\(self.currencySymbol)0.0000 this month"
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .mistral,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "API spend: \(spendText)")
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            mistralUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public func toCostUsageTokenSnapshot(historyDays: Int = 30) -> CostUsageTokenSnapshot {
        let window = self.dailyWindow(requestedHistoryDays: historyDays)
        let buckets = window.rows.map(\.bucket)
        let hasUnplacedCost = window.rows.contains { row in
            row.date == nil && (row.bucket.cost != 0 || row.bucket.models.contains { $0.cost != 0 })
        }
        let hasUnplacedTokens = window.rows.contains { row in
            row.date == nil && (
                row.bucket.inputTokens != 0
                    || row.bucket.cachedTokens != 0
                    || row.bucket.outputTokens != 0
                    || row.bucket.models.contains {
                        $0.inputTokens != 0 || $0.cachedTokens != 0 || $0.outputTokens != 0
                    })
        }
        let costDataIsComplete = window.coverageIsEstablished
            && self.dailyCostMatchesSnapshot()
            && !hasUnplacedCost
        let tokenDataIsComplete = window.coverageIsEstablished
            && self.dailyTokensMatchSnapshot()
            && !hasUnplacedTokens
        let windowCosts = costDataIsComplete ? Self.nonnegativeWindowCosts(buckets.map(\.cost)) : nil
        let windowCostIsComplete = windowCosts != nil
        let displayedCosts = windowCosts?.map(Optional.some) ?? Array(repeating: nil, count: buckets.count)
        let rowTokens: [Int?] = buckets.map { bucket in
            tokenDataIsComplete ? Self.tokenTotal(for: bucket) : nil
        }
        let windowTokensAreComplete = tokenDataIsComplete && rowTokens.allSatisfy { $0 != nil }
        let entries = buckets.enumerated().map { index, bucket in
            let modelBreakdowns = Self.modelBreakdowns(
                for: bucket,
                costsAreComplete: windowCostIsComplete,
                tokensAreComplete: tokenDataIsComplete)
            let modelsUsed = bucket.models.map(\.name)
            return CostUsageDailyReport.Entry(
                date: bucket.day,
                inputTokens: tokenDataIsComplete ? bucket.inputTokens : nil,
                outputTokens: tokenDataIsComplete ? bucket.outputTokens : nil,
                cacheReadTokens: tokenDataIsComplete ? bucket.cachedTokens : nil,
                cacheCreationTokens: nil,
                totalTokens: rowTokens[index],
                costUSD: displayedCosts[index],
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        let latestIndex = window.rows.enumerated()
            .compactMap { index, row in row.date.map { (index: index, date: $0) } }
            .max { $0.date < $1.date }?
            .index
        let totalCost = windowCostIsComplete
            ? Self.safeCostSum(displayedCosts.compactMap(\.self))
            : nil
        let totalTokens = windowTokensAreComplete
            ? Self.safeIntSum(rowTokens.compactMap(\.self))
            : nil
        return CostUsageTokenSnapshot(
            sessionTokens: latestIndex.flatMap { rowTokens[$0] },
            sessionCostUSD: latestIndex.flatMap { displayedCosts[$0] },
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            currencyCode: self.currency,
            historyDays: window.coveredDays,
            historyCoverageIsEstablished: window.coverageIsEstablished,
            historyLabel: window.isMonthToDate ? "This month" : nil,
            daily: entries,
            updatedAt: window.observationEnd)
    }

    private struct WindowedBucket {
        let bucket: MistralDailyUsageBucket
        let date: Date?
    }

    private struct DailyWindow {
        let rows: [WindowedBucket]
        let coveredDays: Int
        let coverageIsEstablished: Bool
        let isMonthToDate: Bool
        let observationEnd: Date
    }

    private struct DailyCoverage {
        let days: Int
        let end: Date
        let isEstablished: Bool
    }

    private func dailyWindow(requestedHistoryDays: Int) -> DailyWindow {
        let requestedDays = max(1, min(365, requestedHistoryDays))
        let calendar = Self.apiCalendar
        let selectionEnd = calendar.startOfDay(for: min(self.endDate ?? self.updatedAt, self.updatedAt))
        let windowStart = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: selectionEnd)
            ?? selectionEnd
        var rows: [WindowedBucket] = []
        var selectedDates: [Date] = []
        for bucket in self.daily {
            guard let date = Self.apiDay(from: bucket.day, calendar: calendar) else {
                rows.append(WindowedBucket(bucket: bucket, date: nil))
                continue
            }
            guard date >= windowStart, date <= selectionEnd else { continue }
            rows.append(WindowedBucket(bucket: bucket, date: date))
            selectedDates.append(date)
        }
        let coverage = self.dailyCoverage(
            windowStart: windowStart,
            windowEnd: selectionEnd,
            selectedDates: selectedDates,
            calendar: calendar)

        return DailyWindow(
            rows: rows,
            coveredDays: coverage.days,
            coverageIsEstablished: coverage.isEstablished,
            isMonthToDate: self.isMonthToDateWindow(
                windowStart: windowStart,
                windowEnd: selectionEnd,
                calendar: calendar),
            observationEnd: coverage.end)
    }

    private func dailyCoverage(
        windowStart: Date,
        windowEnd: Date,
        selectedDates: [Date],
        calendar: Calendar) -> DailyCoverage
    {
        if let startDate = self.startDate, let endDate = self.endDate,
           let coveredDays = Self.inclusiveDayCount(
               from: max(calendar.startOfDay(for: startDate), windowStart),
               through: min(calendar.startOfDay(for: min(endDate, self.updatedAt)), windowEnd),
               calendar: calendar)
        {
            let coveredEnd = min(calendar.startOfDay(for: min(endDate, self.updatedAt)), windowEnd)
            return DailyCoverage(days: coveredDays, end: coveredEnd, isEstablished: true)
        }

        if let firstDay = selectedDates.min(), let lastDay = selectedDates.max(),
           let coveredDays = Self.inclusiveDayCount(from: firstDay, through: lastDay, calendar: calendar)
        {
            return DailyCoverage(days: coveredDays, end: lastDay, isEstablished: true)
        }

        return DailyCoverage(days: 1, end: windowEnd, isEstablished: false)
    }

    private func isMonthToDateWindow(windowStart: Date, windowEnd: Date, calendar: Calendar) -> Bool {
        guard let startDate = self.startDate, let endDate = self.endDate else { return false }
        let monthStart = calendar.startOfDay(for: startDate)
        let observationEnd = calendar.startOfDay(for: min(endDate, self.updatedAt))
        return calendar.component(.day, from: monthStart) == 1
            && calendar.isDate(monthStart, equalTo: self.updatedAt, toGranularity: .month)
            && calendar.startOfDay(for: endDate) >= calendar.startOfDay(for: self.updatedAt)
            && windowStart <= monthStart
            && windowEnd >= observationEnd
    }

    private func dailyCostMatchesSnapshot() -> Bool {
        guard self.hasNonnegativeCosts(),
              let dailyCost = Self.safeCostSum(self.daily.map(\.cost))
        else { return false }
        return Self.costsMatch(self.totalCost, dailyCost)
    }

    private func hasNonnegativeCosts() -> Bool {
        guard self.totalCost.isFinite, self.totalCost >= 0 else { return false }
        return self.daily.allSatisfy { bucket in
            bucket.cost.isFinite
                && bucket.cost >= 0
                && bucket.models.allSatisfy { $0.cost.isFinite && $0.cost >= 0 }
        }
    }

    private func dailyTokensMatchSnapshot() -> Bool {
        guard self.hasNonnegativeTokenCounters(),
              let snapshotTokens = Self.safeIntSum([
                  self.totalInputTokens,
                  self.totalCachedTokens,
                  self.totalOutputTokens,
              ]),
              let dailyTokens = Self.safeIntSum(self.daily.flatMap { bucket in
                  [bucket.inputTokens, bucket.cachedTokens, bucket.outputTokens]
              })
        else { return false }
        return snapshotTokens == dailyTokens
    }

    private func hasNonnegativeTokenCounters() -> Bool {
        guard [self.totalInputTokens, self.totalCachedTokens, self.totalOutputTokens]
            .allSatisfy({ $0 >= 0 })
        else { return false }
        return self.daily.allSatisfy { bucket in
            [bucket.inputTokens, bucket.cachedTokens, bucket.outputTokens].allSatisfy { $0 >= 0 }
                && bucket.models.allSatisfy { model in
                    [model.inputTokens, model.cachedTokens, model.outputTokens].allSatisfy { $0 >= 0 }
                }
        }
    }

    private static func nonnegativeWindowCosts(_ rawCosts: [Double]) -> [Double]? {
        guard rawCosts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return rawCosts
    }

    private static func modelBreakdowns(
        for bucket: MistralDailyUsageBucket,
        costsAreComplete: Bool,
        tokensAreComplete: Bool) -> [CostUsageDailyReport.ModelBreakdown]
    {
        bucket.models.map { model in
            let modelCost = costsAreComplete && model.cost.isFinite && model.cost >= 0 ? model.cost : nil
            let modelTokens = tokensAreComplete ? Self.safeIntSum([
                model.inputTokens,
                model.cachedTokens,
                model.outputTokens,
            ]) : nil
            return CostUsageDailyReport.ModelBreakdown(
                modelName: model.name,
                costUSD: modelCost,
                totalTokens: modelTokens)
        }
    }

    private static func tokenTotal(for bucket: MistralDailyUsageBucket) -> Int? {
        self.safeIntSum([bucket.inputTokens, bucket.cachedTokens, bucket.outputTokens])
    }

    private static func safeCostSum(_ values: [Double]) -> Double? {
        var total = 0.0
        for value in values {
            guard value.isFinite else { return nil }
            total += value
            guard total.isFinite else { return nil }
        }
        return total
    }

    private static func safeIntSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    private static func costsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        let tolerance = min(1e-6, max(1e-9, max(abs(lhs), abs(rhs)) * 1e-12))
        return abs(lhs - rhs) <= tolerance
    }

    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private static func inclusiveDayCount(from start: Date, through end: Date, calendar: Calendar) -> Int? {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay,
              let difference = calendar.dateComponents([.day], from: startDay, to: endDay).day,
              difference >= 0
        else { return nil }
        return min(365, difference + 1)
    }

    private static func apiDay(from rawValue: String, calendar: Calendar) -> Date? {
        let bytes = Array(rawValue.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) })
        else { return nil }
        let parts = rawValue.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
                  year: year,
                  month: month,
                  day: day)
        else { return nil }
        return calendar.startOfDay(for: date)
    }
}

public struct MistralCreditsSnapshot: Codable, Equatable, Sendable {
    public let walletAmount: Double
    public let creditNotesAmount: Double
    public let ongoingUsageBalance: Double
    public let currency: String

    public init(
        walletAmount: Double,
        creditNotesAmount: Double,
        ongoingUsageBalance: Double,
        currency: String)
    {
        self.walletAmount = walletAmount
        self.creditNotesAmount = creditNotesAmount
        self.ongoingUsageBalance = ongoingUsageBalance
        self.currency = currency
    }

    public var availableAmount: Double {
        let amount = self.walletAmount + self.creditNotesAmount - self.ongoingUsageBalance
        return amount.isFinite ? max(0, amount) : 0
    }

    public var formattedAvailableAmount: String {
        UsageFormatter.currencyString(self.availableAmount, currencyCode: self.currency)
    }
}

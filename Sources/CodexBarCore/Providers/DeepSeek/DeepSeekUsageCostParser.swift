import Foundation

// MARK: - Amount Response Models

struct DeepSeekAmountPayload: Decodable {
    let code: Int?
    let msg: String?
    let data: DeepSeekAmountData?

    private enum CodingKeys: String, CodingKey {
        case code, msg, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        self.msg = try container.decodeIfPresent(String.self, forKey: .msg)
        if let code, code != 0 {
            // Error envelopes are not schema-stable. Preserve their code even if `data` has an unexpected shape.
            self.data = try? container.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
        }
    }
}

struct DeepSeekAmountData: Decodable {
    let bizCode: Int?
    let bizMsg: String?
    let bizData: DeepSeekAmountBizData?

    private enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizMsg = "biz_msg"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        self.bizMsg = try container.decodeIfPresent(String.self, forKey: .bizMsg)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
        }
    }
}

struct DeepSeekAmountBizData: Decodable {
    let total: [DeepSeekModelUsage]?
    let days: [DeepSeekDayUsage]?

    private enum CodingKeys: String, CodingKey {
        case total, days
    }
}

// MARK: - Cost Response Models

struct DeepSeekCostPayload: Decodable {
    let code: Int?
    let msg: String?
    let data: DeepSeekCostData?

    private enum CodingKeys: String, CodingKey {
        case code, msg, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        self.msg = try container.decodeIfPresent(String.self, forKey: .msg)
        if let code, code != 0 {
            self.data = try? container.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
        }
    }
}

struct DeepSeekCostData: Decodable {
    let bizCode: Int?
    let bizMsg: String?
    let bizData: [DeepSeekCostBizDataItem]?

    private enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizMsg = "biz_msg"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        self.bizMsg = try container.decodeIfPresent(String.self, forKey: .bizMsg)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent([DeepSeekCostBizDataItem].self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent([DeepSeekCostBizDataItem].self, forKey: .bizData)
        }
    }
}

struct DeepSeekCostBizDataItem: Decodable {
    let total: [DeepSeekCostModelUsage]?
    let days: [DeepSeekCostDayUsage]?
    let currency: String?

    private enum CodingKeys: String, CodingKey {
        case total, days, currency
    }
}

// MARK: - Shared Models

struct DeepSeekModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekUsageItem]?

    private enum CodingKeys: String, CodingKey {
        case model, usage
    }
}

struct DeepSeekDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekModelUsage]?

    private enum CodingKeys: String, CodingKey {
        case date, data
    }
}

struct DeepSeekUsageItem: Decodable {
    let type: String?
    let amount: String?

    private enum CodingKeys: String, CodingKey {
        case type, amount
    }
}

struct DeepSeekCostModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekCostItem]?

    private enum CodingKeys: String, CodingKey {
        case model, usage
    }
}

struct DeepSeekCostDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekCostModelUsage]?

    private enum CodingKeys: String, CodingKey {
        case date, data
    }
}

struct DeepSeekCostItem: Decodable {
    let type: String?
    let amount: String?

    private enum CodingKeys: String, CodingKey {
        case type, amount
    }
}

// MARK: - Domain Models

/// One fixed-offset half-open `[start, end)` query window for DeepSeek `by_api_key` endpoints.
public struct DeepSeekUsageWindow: Sendable, Equatable, Hashable {
    public let start: Date
    public let end: Date
    public let dayCount: Int
    public let timeZoneSeconds: Int
    public let startDayKey: String
    public let endDayKey: String

    public var startSeconds: Int {
        Int(self.start.timeIntervalSince1970)
    }

    public var endSeconds: Int {
        Int(self.end.timeIntervalSince1970)
    }

    public init(
        start: Date,
        end: Date,
        dayCount: Int,
        timeZoneSeconds: Int,
        startDayKey: String,
        endDayKey: String)
    {
        self.start = start
        self.end = end
        self.dayCount = dayCount
        self.timeZoneSeconds = timeZoneSeconds
        self.startDayKey = startDayKey
        self.endDayKey = endDayKey
    }
}

/// Planned newest-first disjoint `[start, end)` chunks for a single DeepSeek history load.
public struct DeepSeekHistoryPlan: Sendable, Equatable, Hashable {
    public static let defaultMaxChunkDays = 30
    public static let maxHistoryDays = 365

    public let period: CostReportingPeriod
    public let anchorDate: Date
    public let anchorDayKey: String
    public let timeZoneSeconds: Int
    public let requestedStart: Date
    public let requestedEnd: Date
    public let requestedStartDayKey: String
    public let requestedEndDayKey: String
    public let requestedDays: Int
    public let chunks: [DeepSeekUsageWindow]

    public var isWide: Bool {
        self.chunks.count > 1
    }

    public var recentChunk: DeepSeekUsageWindow {
        self.chunks[0]
    }

    public var requestedStartSeconds: Int {
        Int(self.requestedStart.timeIntervalSince1970)
    }

    public var fixedOffsetCalendar: Calendar {
        CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: self.timeZoneSeconds)
    }

    package func withAnchorDate(_ anchorDate: Date) -> DeepSeekHistoryPlan {
        DeepSeekHistoryPlan(
            period: self.period,
            anchorDate: anchorDate,
            anchorDayKey: self.anchorDayKey,
            timeZoneSeconds: self.timeZoneSeconds,
            requestedStart: self.requestedStart,
            requestedEnd: self.requestedEnd,
            requestedStartDayKey: self.requestedStartDayKey,
            requestedEndDayKey: self.requestedEndDayKey,
            requestedDays: self.requestedDays,
            chunks: self.chunks)
    }

    /// Reuses valid full-day older chunks already fetched for the same UTC offset, filling uncovered
    /// boundary gaps newest-first under `maxChunkDays` so midnight rollovers do not replay full history.
    package func adaptingToReusableWindows(
        _ reusableWindows: Set<DeepSeekUsageWindow>,
        maxChunkDays: Int = DeepSeekHistoryPlan.defaultMaxChunkDays) -> DeepSeekHistoryPlan
    {
        guard self.isWide, !reusableWindows.isEmpty, let head = self.chunks.first else {
            return self
        }
        let chunkLimit = max(1, maxChunkDays)
        let olderStart = self.requestedStartSeconds
        let olderEnd = head.startSeconds
        guard olderStart < olderEnd,
              (olderStart + self.timeZoneSeconds) % 86400 == 0,
              (olderEnd + self.timeZoneSeconds) % 86400 == 0
        else {
            return self
        }

        let fixedCalendar = self.fixedOffsetCalendar
        let plannedOlderWindows = Set(self.chunks.dropFirst())
        let olderBounds = olderStart..<olderEnd
        let candidates = reusableWindows.filter { window in
            self.isReusableOlderWindow(
                window,
                olderBounds: olderBounds,
                chunkLimit: chunkLimit,
                plannedOlderWindows: plannedOlderWindows,
                fixedCalendar: fixedCalendar)
        }
        guard !candidates.isEmpty else { return self }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.endSeconds != rhs.endSeconds {
                return lhs.endSeconds > rhs.endSeconds
            }
            if lhs.dayCount != rhs.dayCount {
                return lhs.dayCount > rhs.dayCount
            }
            return lhs.startSeconds < rhs.startSeconds
        }

        var accepted: [DeepSeekUsageWindow] = []
        for candidate in sortedCandidates {
            let overlaps = accepted.contains { existing in
                candidate.startSeconds < existing.endSeconds && candidate.endSeconds > existing.startSeconds
            }
            if !overlaps {
                accepted.append(candidate)
            }
        }
        guard !accepted.isEmpty else { return self }

        let acceptedNewestFirst = accepted.sorted { $0.endSeconds > $1.endSeconds }
        var adaptedChunks: [DeepSeekUsageWindow] = [head]
        var cursorEnd = olderEnd

        for reused in acceptedNewestFirst {
            if reused.endSeconds < cursorEnd {
                self.appendNewestFirstGapChunks(
                    from: reused.endSeconds,
                    to: cursorEnd,
                    chunkLimit: chunkLimit,
                    fixedCalendar: fixedCalendar,
                    into: &adaptedChunks)
            }
            adaptedChunks.append(reused)
            cursorEnd = reused.startSeconds
        }
        if olderStart < cursorEnd {
            self.appendNewestFirstGapChunks(
                from: olderStart,
                to: cursorEnd,
                chunkLimit: chunkLimit,
                fixedCalendar: fixedCalendar,
                into: &adaptedChunks)
        }

        return DeepSeekHistoryPlan(
            period: self.period,
            anchorDate: self.anchorDate,
            anchorDayKey: self.anchorDayKey,
            timeZoneSeconds: self.timeZoneSeconds,
            requestedStart: self.requestedStart,
            requestedEnd: self.requestedEnd,
            requestedStartDayKey: self.requestedStartDayKey,
            requestedEndDayKey: self.requestedEndDayKey,
            requestedDays: self.requestedDays,
            chunks: adaptedChunks)
    }

    private func isReusableOlderWindow(
        _ window: DeepSeekUsageWindow,
        olderBounds: Range<Int>,
        chunkLimit: Int,
        plannedOlderWindows: Set<DeepSeekUsageWindow>,
        fixedCalendar: Calendar) -> Bool
    {
        guard window.timeZoneSeconds == self.timeZoneSeconds,
              window.start.timeIntervalSince1970 == TimeInterval(window.startSeconds),
              window.end.timeIntervalSince1970 == TimeInterval(window.endSeconds),
              window.startSeconds >= olderBounds.lowerBound,
              window.endSeconds <= olderBounds.upperBound,
              window.endSeconds > window.startSeconds,
              (window.startSeconds + self.timeZoneSeconds) % 86400 == 0,
              (window.endSeconds + self.timeZoneSeconds) % 86400 == 0
        else {
            return false
        }
        let exactDays = (window.endSeconds - window.startSeconds) / 86400
        guard exactDays >= 1,
              exactDays <= chunkLimit,
              window.dayCount == exactDays,
              exactDays == chunkLimit || plannedOlderWindows.contains(window)
        else {
            return false
        }
        let expectedStartDayKey = CostUsageLocalDay.key(from: window.start, calendar: fixedCalendar)
        let lastIncludedDay = fixedCalendar.date(byAdding: .day, value: -1, to: window.end)
            ?? window.end.addingTimeInterval(-86400)
        let expectedEndDayKey = CostUsageLocalDay.key(from: lastIncludedDay, calendar: fixedCalendar)
        return window.startDayKey == expectedStartDayKey && window.endDayKey == expectedEndDayKey
    }

    private func appendNewestFirstGapChunks(
        from gapStartSeconds: Int,
        to gapEndSeconds: Int,
        chunkLimit: Int,
        fixedCalendar: Calendar,
        into chunks: inout [DeepSeekUsageWindow])
    {
        let totalSeconds = gapEndSeconds - gapStartSeconds
        guard totalSeconds > 0, totalSeconds % 86400 == 0 else { return }
        chunks += Self.newestFirstWindows(
            endingAt: Date(timeIntervalSince1970: TimeInterval(gapEndSeconds)),
            days: totalSeconds / 86400,
            chunkLimit: chunkLimit,
            timeZoneSeconds: self.timeZoneSeconds,
            fixedCalendar: fixedCalendar)
    }

    /// Partitions `days` whole fixed-offset days ending at exclusive `end` into newest-first `[start, end)` chunks.
    private static func newestFirstWindows(
        endingAt end: Date,
        days: Int,
        chunkLimit: Int,
        timeZoneSeconds: Int,
        fixedCalendar: Calendar) -> [DeepSeekUsageWindow]
    {
        var windows: [DeepSeekUsageWindow] = []
        var cursorEnd = end
        var remaining = days
        while remaining > 0 {
            let chunkDays = min(chunkLimit, remaining)
            let chunkStart = fixedCalendar.date(byAdding: .day, value: -chunkDays, to: cursorEnd)
                ?? cursorEnd.addingTimeInterval(-Double(chunkDays) * 86400)
            // Fixed offsets have no DST (a day is exactly 86,400s); the fallback only covers unrepresentable dates.
            let lastIncludedDay = fixedCalendar.date(byAdding: .day, value: -1, to: cursorEnd)
                ?? cursorEnd.addingTimeInterval(-86400)
            windows.append(DeepSeekUsageWindow(
                start: chunkStart,
                end: cursorEnd,
                dayCount: chunkDays,
                timeZoneSeconds: timeZoneSeconds,
                startDayKey: CostUsageLocalDay.key(from: chunkStart, calendar: fixedCalendar),
                endDayKey: CostUsageLocalDay.key(from: lastIncludedDay, calendar: fixedCalendar)))
            cursorEnd = chunkStart
            remaining -= chunkDays
        }
        return windows
    }

    public static func make(
        period: CostReportingPeriod,
        now: Date,
        calendar: Calendar,
        maxChunkDays: Int = DeepSeekHistoryPlan.defaultMaxChunkDays,
        maxHistoryDays: Int = DeepSeekHistoryPlan.maxHistoryDays) -> DeepSeekHistoryPlan
    {
        let offsetSeconds = calendar.timeZone.secondsFromGMT(for: now)
        let fixedCalendar = CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: offsetSeconds)

        let chunkLimit = max(1, maxChunkDays)
        let historyLimit = max(1, maxHistoryDays)
        let todayStart = fixedCalendar.startOfDay(for: now)
        let exclusiveEnd = fixedCalendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86400)

        let requestedDays: Int
        let requestedStart: Date
        switch period {
        case let .rolling(days):
            requestedDays = max(1, min(historyLimit, days))
            requestedStart = fixedCalendar.date(byAdding: .day, value: -(requestedDays - 1), to: todayStart)
                ?? todayStart
        case .monthToDate:
            let monthStart = fixedCalendar.dateInterval(of: .month, for: todayStart)?.start ?? todayStart
            let monthDays = (fixedCalendar.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0) + 1
            requestedDays = max(1, min(historyLimit, monthDays))
            requestedStart = fixedCalendar.date(byAdding: .day, value: -(requestedDays - 1), to: todayStart)
                ?? monthStart
        case .allTime:
            // Keep All bounded until vendor retention is proven; never stamp "All" onto bounded coverage.
            requestedDays = historyLimit
            requestedStart = fixedCalendar.date(byAdding: .day, value: -(requestedDays - 1), to: todayStart)
                ?? todayStart
        }

        let anchorDayKey = CostUsageLocalDay.key(from: todayStart, calendar: fixedCalendar)
        let requestedStartDayKey = CostUsageLocalDay.key(from: requestedStart, calendar: fixedCalendar)

        let chunks = Self.newestFirstWindows(
            endingAt: exclusiveEnd,
            days: requestedDays,
            chunkLimit: chunkLimit,
            timeZoneSeconds: offsetSeconds,
            fixedCalendar: fixedCalendar)

        return DeepSeekHistoryPlan(
            period: period,
            anchorDate: now,
            anchorDayKey: anchorDayKey,
            timeZoneSeconds: offsetSeconds,
            requestedStart: requestedStart,
            requestedEnd: exclusiveEnd,
            requestedStartDayKey: requestedStartDayKey,
            requestedEndDayKey: anchorDayKey,
            requestedDays: requestedDays,
            chunks: chunks)
    }
}

/// Compact per-currency cost contribution from one validated DeepSeek chunk.
public struct DeepSeekCurrencyContribution: Sendable, Equatable {
    public let currency: String
    public let dayCosts: [String: Double]
    public let unavailableCostDays: Set<String>
    public let modelCosts: [String: Double]
    public let unavailableModels: Set<String>
    public let apiKeyIDs: Set<String>
    public let hasIncompleteCost: Bool

    public init(
        currency: String,
        dayCosts: [String: Double],
        unavailableCostDays: Set<String> = [],
        modelCosts: [String: Double],
        unavailableModels: Set<String> = [],
        apiKeyIDs: Set<String> = [],
        hasIncompleteCost: Bool = false)
    {
        self.currency = currency
        self.dayCosts = dayCosts
        self.unavailableCostDays = unavailableCostDays
        self.modelCosts = modelCosts
        self.unavailableModels = unavailableModels
        self.apiKeyIDs = apiKeyIDs
        self.hasIncompleteCost = hasIncompleteCost
    }
}

/// Compact folded totals for one validated `[start, end)` amount/cost pair. Raw payloads are released per fold.
public struct DeepSeekChunkFoldResult: Sendable, Equatable {
    public let window: DeepSeekUsageWindow
    public let dayTokens: [String: Int]
    public let dayModelRequests: [String: Int]
    public let dayFunctionRequests: [String: Int]
    public let categoryTotals: [DeepSeekUsageCategory: Int]
    public let modelTokens: [String: Int]
    public let apiKeyIDs: Set<String>
    public let currencyTotals: [DeepSeekCurrencyContribution]

    public init(
        window: DeepSeekUsageWindow,
        dayTokens: [String: Int],
        dayModelRequests: [String: Int],
        dayFunctionRequests: [String: Int],
        categoryTotals: [DeepSeekUsageCategory: Int],
        modelTokens: [String: Int],
        apiKeyIDs: Set<String>,
        currencyTotals: [DeepSeekCurrencyContribution])
    {
        self.window = window
        self.dayTokens = dayTokens
        self.dayModelRequests = dayModelRequests
        self.dayFunctionRequests = dayFunctionRequests
        self.categoryTotals = categoryTotals
        self.modelTokens = modelTokens
        self.apiKeyIDs = apiKeyIDs
        self.currencyTotals = currencyTotals
    }
}

/// Verified requested versus covered dates for a DeepSeek `by_api_key` report.
public struct DeepSeekUsageCoverage: Sendable, Equatable {
    public let requestedPeriod: CostReportingPeriod
    public let requestedStartDay: String
    public let requestedEndDay: String
    public let requestedDays: Int
    public let coveredIntervals: [CostUsageDayInterval]
    public let coveredDays: Int
    public let failedChunkCount: Int

    public var isComplete: Bool {
        self.coveredDays >= self.requestedDays && self.failedChunkCount == 0
    }

    public var isPartial: Bool {
        !self.isComplete
    }

    public var isBoundedAll: Bool {
        self.requestedPeriod == .allTime
    }

    public init(
        requestedPeriod: CostReportingPeriod,
        requestedStartDay: String,
        requestedEndDay: String,
        requestedDays: Int,
        coveredIntervals: [CostUsageDayInterval],
        coveredDays: Int,
        failedChunkCount: Int = 0)
    {
        self.requestedPeriod = requestedPeriod
        self.requestedStartDay = requestedStartDay
        self.requestedEndDay = requestedEndDay
        self.requestedDays = requestedDays
        self.coveredIntervals = coveredIntervals
        self.coveredDays = coveredDays
        self.failedChunkCount = failedChunkCount
    }
}

public struct DeepSeekUsageSummary: Sendable, Equatable {
    public let todayTokens: Int
    public let currentMonthTokens: Int
    public let todayCost: Double?
    public let currentMonthCost: Double?
    public let requestCount: Int
    public let currentMonthRequestCount: Int
    public let topModel: String?
    public let categoryBreakdown: [DeepSeekCategoryBreakdown]
    public let daily: [DeepSeekDailyUsage]
    public let modelCosts: [DeepSeekModelCost]
    public let currency: String
    public let apiKeyCount: Int
    public let period: DeepSeekUsagePeriod
    public let coverage: DeepSeekUsageCoverage?
    public let timeZoneSeconds: Int?
    public let updatedAt: Date

    public init(
        todayTokens: Int,
        currentMonthTokens: Int,
        todayCost: Double?,
        currentMonthCost: Double?,
        requestCount: Int,
        currentMonthRequestCount: Int,
        topModel: String?,
        categoryBreakdown: [DeepSeekCategoryBreakdown],
        daily: [DeepSeekDailyUsage],
        currency: String,
        modelCosts: [DeepSeekModelCost] = [],
        apiKeyCount: Int = 0,
        period: DeepSeekUsagePeriod = .currentMonth,
        coverage: DeepSeekUsageCoverage? = nil,
        timeZoneSeconds: Int? = nil,
        updatedAt: Date)
    {
        self.todayTokens = todayTokens
        self.currentMonthTokens = currentMonthTokens
        self.todayCost = todayCost
        self.currentMonthCost = currentMonthCost
        self.requestCount = requestCount
        self.currentMonthRequestCount = currentMonthRequestCount
        self.topModel = topModel
        self.categoryBreakdown = categoryBreakdown
        self.daily = daily
        self.modelCosts = modelCosts
        self.currency = currency
        self.apiKeyCount = apiKeyCount
        self.period = period
        self.coverage = coverage
        self.timeZoneSeconds = timeZoneSeconds
        self.updatedAt = updatedAt
    }

    public var periodLabel: String {
        if self.period == .currentMonth {
            return "This month"
        }
        guard let coverage = self.coverage else {
            return "Last 30 days"
        }
        if coverage.requestedPeriod == .monthToDate {
            if coverage.isComplete {
                return "Month to date"
            }
            return "Month to date (\(coverage.coveredDays) of \(coverage.requestedDays) days)"
        }
        if coverage.isComplete {
            return coverage.requestedDays == 1 ? "Today" : "Last \(coverage.requestedDays) days"
        }
        return "Last \(coverage.coveredDays) of \(coverage.requestedDays) days"
    }

    public var compactPeriodLabel: String {
        if self.period == .currentMonth {
            return "This month"
        }
        guard let coverage = self.coverage else {
            return "30d"
        }
        if coverage.requestedPeriod == .monthToDate {
            return coverage.isComplete ? "Month to date" : "\(coverage.coveredDays)/\(coverage.requestedDays)d"
        }
        if coverage.isComplete {
            return coverage.requestedDays == 1 ? "Today" : "\(coverage.requestedDays)d"
        }
        return "\(coverage.coveredDays)/\(coverage.requestedDays)d"
    }
}

public struct DeepSeekModelCost: Sendable, Equatable {
    public let model: String
    public let cost: Double

    public init(model: String, cost: Double) {
        self.model = model
        self.cost = cost
    }
}

public enum DeepSeekUsagePeriod: Sendable, Equatable {
    case last30Days
    case currentMonth
}

public struct DeepSeekCategoryBreakdown: Sendable, Equatable {
    public let category: DeepSeekUsageCategory
    public let tokens: Int
    public let cost: Double?

    public init(category: DeepSeekUsageCategory, tokens: Int, cost: Double?) {
        self.category = category
        self.tokens = tokens
        self.cost = cost
    }
}

public enum DeepSeekUsageCategory: String, Sendable, Equatable {
    case promptCacheHitToken = "PROMPT_CACHE_HIT_TOKEN"
    case promptCacheMissToken = "PROMPT_CACHE_MISS_TOKEN"
    case responseToken = "RESPONSE_TOKEN"
    case request = "REQUEST"

    public init?(rawValue: String) {
        switch rawValue.uppercased() {
        case "PROMPT_CACHE_HIT_TOKEN":
            self = .promptCacheHitToken
        case "PROMPT_CACHE_MISS_TOKEN":
            self = .promptCacheMissToken
        case "RESPONSE_TOKEN":
            self = .responseToken
        case "REQUEST":
            self = .request
        default:
            return nil
        }
    }
}

public struct DeepSeekDailyUsage: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let cost: Double?
    public let requestCount: Int

    public init(date: String, totalTokens: Int, cost: Double?, requestCount: Int) {
        self.date = date
        self.totalTokens = totalTokens
        self.cost = cost
        self.requestCount = requestCount
    }
}

// MARK: - Parsing

package enum DeepSeekUsageCostParser {
    static func decodeAmountPayload(data: Data) throws -> DeepSeekAmountPayload {
        try JSONDecoder().decode(DeepSeekAmountPayload.self, from: data)
    }

    static func decodeCostPayload(data: Data) throws -> DeepSeekCostPayload {
        try JSONDecoder().decode(DeepSeekCostPayload.self, from: data)
    }

    static func parse(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> DeepSeekUsageSummary
    {
        let amountPayload: DeepSeekAmountPayload
        let costPayload: DeepSeekCostPayload
        do {
            amountPayload = try self.decodeAmountPayload(data: amountData)
        } catch {
            throw DeepSeekUsageError.parseFailed("amount: \(self.decodingFailureDescription(error))")
        }
        do {
            costPayload = try self.decodeCostPayload(data: costData)
        } catch {
            throw DeepSeekUsageError.parseFailed("cost: \(self.decodingFailureDescription(error))")
        }

        // Validate responses
        if let code = amountPayload.code, code != 0 {
            if self.isAuthenticationError(code) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("amount code \(code)")
        }
        if let bizCode = amountPayload.data?.bizCode, bizCode != 0 {
            if self.isAuthenticationError(bizCode) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("amount biz_code \(bizCode)")
        }
        if let code = costPayload.code, code != 0 {
            if self.isAuthenticationError(code) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("cost code \(code)")
        }
        if let bizCode = costPayload.data?.bizCode, bizCode != 0 {
            if self.isAuthenticationError(bizCode) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("cost biz_code \(bizCode)")
        }

        guard let amountBizData = amountPayload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing amount biz_data")
        }
        guard amountBizData.total != nil || amountBizData.days != nil else {
            throw DeepSeekUsageError.parseFailed("Missing amount total and days")
        }
        guard let costBizData = costPayload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing cost biz_data")
        }

        let currency = costBizData.first?.currency ?? "CNY"

        // Parse total amounts
        let totalAmounts = amountBizData.total ?? []
        let totalCosts = costBizData.first?.total ?? []

        // Parse daily data
        let dailyAmounts = amountBizData.days ?? []
        let dailyCosts = costBizData.first?.days ?? []

        return try self.aggregate(input: AggregationInput(
            totalAmounts: totalAmounts,
            totalCosts: totalCosts,
            dailyAmounts: dailyAmounts,
            dailyCosts: dailyCosts,
            currency: currency,
            now: now,
            calendar: calendar))
    }

    static let tokenCategories: [DeepSeekUsageCategory] = [
        .promptCacheHitToken,
        .promptCacheMissToken,
        .responseToken,
    ]

    static func isAuthenticationError(_ code: Int) -> Bool {
        code == 40002 || code == 40003
    }

    static func decodingFailureDescription(_ error: any Error) -> String {
        if error is DecodingError {
            return String(describing: error)
        }
        return error.localizedDescription
    }

    // MARK: - Aggregation

    private struct AggregationContext {
        let calendar: Calendar
        let todayString: String
        let startOfMonth: Date
        let now: Date
        let dailyAmountMap: [String: [String: [DeepSeekUsageItem]]]
        let dailyCostMap: [String: [String: [DeepSeekCostItem]]]
        let allDates: Set<String>

        init(
            dailyAmounts: [DeepSeekDayUsage],
            dailyCosts: [DeepSeekCostDayUsage],
            now: Date,
            calendar: Calendar)
        {
            self.calendar = calendar
            self.now = now
            self.todayString = DeepSeekUsageCostParser.dayString(now, calendar: calendar)

            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = 1
            self.startOfMonth = calendar.date(from: components) ?? now

            self.dailyAmountMap = Self.buildAmountMap(from: dailyAmounts)
            self.dailyCostMap = Self.buildCostMap(from: dailyCosts)

            var dates: Set<String> = []
            for date in self.dailyAmountMap.keys {
                dates.insert(date)
            }
            for date in self.dailyCostMap.keys {
                dates.insert(date)
            }
            self.allDates = dates
        }

        static func buildAmountMap(
            from dailyAmounts: [DeepSeekDayUsage]) -> [String: [String: [DeepSeekUsageItem]]]
        {
            var result: [String: [String: [DeepSeekUsageItem]]] = [:]
            for dayUsage in dailyAmounts {
                guard let date = dayUsage.date else { continue }
                var modelMap: [String: [DeepSeekUsageItem]] = [:]
                for modelUsage in dayUsage.data ?? [] {
                    guard let model = modelUsage.model else { continue }
                    let items = modelUsage.usage ?? []
                    if !items.isEmpty {
                        modelMap[model] = items
                    }
                }
                if !modelMap.isEmpty {
                    result[date] = modelMap
                }
            }
            return result
        }

        static func buildCostMap(
            from dailyCosts: [DeepSeekCostDayUsage]) -> [String: [String: [DeepSeekCostItem]]]
        {
            var result: [String: [String: [DeepSeekCostItem]]] = [:]
            for dayUsage in dailyCosts {
                guard let date = dayUsage.date else { continue }
                var modelMap: [String: [DeepSeekCostItem]] = [:]
                for modelUsage in dayUsage.data ?? [] {
                    guard let model = modelUsage.model else { continue }
                    let items = modelUsage.usage ?? []
                    if !items.isEmpty {
                        modelMap[model] = items
                    }
                }
                if !modelMap.isEmpty {
                    result[date] = modelMap
                }
            }
            return result
        }
    }

    private struct AggregationInput {
        let totalAmounts: [DeepSeekModelUsage]
        let totalCosts: [DeepSeekCostModelUsage]
        let dailyAmounts: [DeepSeekDayUsage]
        let dailyCosts: [DeepSeekCostDayUsage]
        let currency: String
        let now: Date
        let calendar: Calendar
    }

    private static func aggregate(input: AggregationInput) throws -> DeepSeekUsageSummary {
        let ctx = AggregationContext(
            dailyAmounts: input.dailyAmounts,
            dailyCosts: input.dailyCosts,
            now: input.now,
            calendar: input.calendar)

        let dailyCtx = DailyAggregationContext(
            allDates: ctx.allDates,
            startOfMonth: ctx.startOfMonth,
            now: ctx.now,
            amountMap: ctx.dailyAmountMap,
            costMap: ctx.dailyCostMap,
            calendar: ctx.calendar)
        let dailyAggregation = try self.buildDailyUsages(ctx: dailyCtx)
        let todayUsage = dailyAggregation.daily.first { $0.date == ctx.todayString }

        // Model and category breakdown from totals
        let (topModel, categoryBreakdown, modelCosts) = try self.buildBreakdowns(
            totalAmounts: input.totalAmounts,
            totalCosts: input.totalCosts)

        return DeepSeekUsageSummary(
            todayTokens: todayUsage?.totalTokens ?? 0,
            currentMonthTokens: dailyAggregation.monthTokens,
            todayCost: todayUsage?.cost,
            currentMonthCost: dailyAggregation.monthCost,
            requestCount: todayUsage?.requestCount ?? 0,
            currentMonthRequestCount: dailyAggregation.monthRequests,
            topModel: topModel,
            categoryBreakdown: categoryBreakdown,
            daily: dailyAggregation.daily,
            currency: input.currency,
            modelCosts: modelCosts,
            apiKeyCount: 0,
            period: .currentMonth,
            updatedAt: input.now)
    }

    private struct DailyAggregationContext {
        let allDates: Set<String>
        let startOfMonth: Date
        let now: Date
        let amountMap: [String: [String: [DeepSeekUsageItem]]]
        let costMap: [String: [String: [DeepSeekCostItem]]]
        let calendar: Calendar
    }

    private struct DailyAggregationResult {
        let daily: [DeepSeekDailyUsage]
        let monthTokens: Int
        let monthCost: Double?
        let monthRequests: Int
    }

    private static func buildBreakdowns(
        totalAmounts: [DeepSeekModelUsage],
        totalCosts: [DeepSeekCostModelUsage]) throws -> (String?, [DeepSeekCategoryBreakdown], [DeepSeekModelCost])
    {
        var modelTokens: [String: Int] = [:]
        var categoryTokens: [DeepSeekUsageCategory: Int] = [:]
        var categoryCosts: [DeepSeekUsageCategory: Double] = [:]
        var unavailableCategoryCosts = Set<DeepSeekUsageCategory>()
        var modelCosts = ModelCostTotals()

        for modelUsage in totalAmounts {
            guard let model = modelUsage.model else { continue }
            var total = modelTokens[model, default: 0]
            for item in modelUsage.usage ?? [] {
                guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                guard let amount = Self.parseNonNegativeInt(item.amount) else {
                    throw DeepSeekUsageError.parseFailed("Invalid \(category.rawValue) total amount")
                }
                if category != .request {
                    total = try Self.checkedAddOrThrow(total, amount, field: "monthly model tokens")
                    categoryTokens[category] = try Self.checkedAddOrThrow(
                        categoryTokens[category, default: 0],
                        amount,
                        field: "monthly category tokens")
                }
            }
            modelTokens[model] = total
        }

        guard CheckedSum.integers(Self.tokenCategories.compactMap { categoryTokens[$0] }) != nil else {
            throw DeepSeekUsageError.parseFailed("Overflow summing monthly sibling token categories")
        }
        guard CheckedSum.integers(modelTokens.values) != nil else {
            throw DeepSeekUsageError.parseFailed("Overflow summing monthly model tokens")
        }

        for costUsage in totalCosts {
            guard let model = costUsage.model else { continue }
            guard let items = costUsage.usage else {
                modelCosts.add(nil, model: model)
                continue
            }
            for item in items {
                guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else {
                    modelCosts.add(nil, model: model)
                    continue
                }
                if category != .request {
                    let amount = Self.parseNonNegativeCost(item.amount)
                    modelCosts.add(amount, model: model)
                    if let amount {
                        if !unavailableCategoryCosts.contains(category) {
                            if let next = Self.checkedNonNegativeCostAdd(
                                categoryCosts[category] ?? 0,
                                amount)
                            {
                                categoryCosts[category] = next
                            } else {
                                unavailableCategoryCosts.insert(category)
                                categoryCosts.removeValue(forKey: category)
                            }
                        }
                    } else {
                        unavailableCategoryCosts.insert(category)
                        categoryCosts.removeValue(forKey: category)
                    }
                }
            }
        }

        let topModel = modelTokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key

        let breakdown = Self.tokenCategories.map { category in
            DeepSeekCategoryBreakdown(
                category: category,
                tokens: categoryTokens[category] ?? 0,
                cost: unavailableCategoryCosts.contains(category) ? nil : categoryCosts[category])
        }

        return (topModel, breakdown, modelCosts.values)
    }

    struct ModelCostTotals {
        private(set) var totals: [String: Double] = [:]
        private(set) var unavailable: Set<String> = []

        mutating func add(_ amount: Double?, model rawModel: String?) {
            guard let model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty, !self.unavailable.contains(model)
            else { return }
            if let amount,
               let total = DeepSeekUsageCostParser.checkedNonNegativeCostAdd(self.totals[model] ?? 0, amount)
            {
                self.totals[model] = total
                return
            }
            // A malformed component must not leave a plausible but incomplete model total.
            self.unavailable.insert(model)
            self.totals.removeValue(forKey: model)
        }

        var values: [DeepSeekModelCost] {
            self.totals.map { DeepSeekModelCost(model: $0.key, cost: $0.value) }.sorted {
                $0.cost == $1.cost ? $0.model < $1.model : $0.cost > $1.cost
            }
        }
    }

    private static func buildDailyUsages(ctx: DailyAggregationContext) throws -> DailyAggregationResult {
        var result: [DeepSeekDailyUsage] = []
        var monthTokens = 0
        var monthRequests = 0
        var monthCost: Double?
        var monthCostUnavailable = false

        for date in ctx.allDates.sorted() {
            guard let parsed = self.parseDate(date, calendar: ctx.calendar),
                  parsed >= ctx.startOfMonth,
                  parsed <= ctx.now
            else { continue }

            var dayTokens = 0
            var dayCost: Double?
            var dayCostUnavailable = false
            var dayRequests = 0

            if let amounts = ctx.amountMap[date] {
                for items in amounts.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        guard let value = Self.parseNonNegativeInt(item.amount) else {
                            throw DeepSeekUsageError.parseFailed("Invalid daily \(category.rawValue) amount")
                        }
                        if category == .request {
                            dayRequests = try Self.checkedAddOrThrow(
                                dayRequests,
                                value,
                                field: "monthly daily requests")
                        } else {
                            dayTokens = try Self.checkedAddOrThrow(
                                dayTokens,
                                value,
                                field: "monthly daily tokens")
                        }
                    }
                }
            }

            if let costs = ctx.costMap[date] {
                for items in costs.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category != .request {
                            if let amount = Self.parseNonNegativeCost(item.amount) {
                                if !dayCostUnavailable {
                                    if let next = Self.checkedNonNegativeCostAdd(dayCost ?? 0, amount) {
                                        dayCost = next
                                    } else {
                                        dayCostUnavailable = true
                                        dayCost = nil
                                    }
                                }
                            } else {
                                dayCostUnavailable = true
                                dayCost = nil
                            }
                        }
                    }
                }
            }

            monthTokens = try Self.checkedAddOrThrow(monthTokens, dayTokens, field: "monthly tokens")
            monthRequests = try Self.checkedAddOrThrow(monthRequests, dayRequests, field: "monthly requests")
            if dayCostUnavailable {
                monthCostUnavailable = true
                monthCost = nil
            } else if let dayCost, !monthCostUnavailable {
                if let next = Self.checkedNonNegativeCostAdd(monthCost ?? 0, dayCost) {
                    monthCost = next
                } else {
                    monthCostUnavailable = true
                    monthCost = nil
                }
            }

            result.append(DeepSeekDailyUsage(
                date: date,
                totalTokens: dayTokens,
                cost: dayCost,
                requestCount: dayRequests))
        }

        return DailyAggregationResult(
            daily: result,
            monthTokens: monthTokens,
            monthCost: monthCostUnavailable ? nil : monthCost,
            monthRequests: monthRequests)
    }

    // MARK: - Helpers

    static func parseNonNegativeInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let parsed = Int(trimmed),
              parsed >= 0
        else {
            return nil
        }
        return parsed
    }

    static func parseNonNegativeCost(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let amount = Double(trimmed),
              amount.isFinite,
              amount.sign != .minus
        else {
            return nil
        }
        return amount
    }

    static func checkedNonNegativeAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0 else { return nil }
        let addition = lhs.addingReportingOverflow(rhs)
        return addition.overflow ? nil : addition.partialValue
    }

    static func checkedAddOrThrow(_ lhs: Int, _ rhs: Int, field: String) throws -> Int {
        guard let sum = self.checkedNonNegativeAdd(lhs, rhs) else {
            throw DeepSeekUsageError.parseFailed("Integer overflow or negative value in \(field)")
        }
        return sum
    }

    static func checkedNonNegativeCostAdd(_ lhs: Double, _ rhs: Double) -> Double? {
        guard lhs.isFinite, lhs.sign != .minus, rhs.isFinite, rhs.sign != .minus else { return nil }
        let sum = lhs + rhs
        return sum.isFinite ? sum : nil
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return "" }
        return CostUsageLocalDay.key(year: year, month: month, day: day)
    }

    private static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }
}

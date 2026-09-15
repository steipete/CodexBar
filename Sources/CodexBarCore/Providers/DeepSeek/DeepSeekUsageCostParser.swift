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
    public let currency: String
    public let apiKeyCount: Int
    public let period: DeepSeekUsagePeriod
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
        apiKeyCount: Int = 0,
        period: DeepSeekUsagePeriod = .currentMonth,
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
        self.currency = currency
        self.apiKeyCount = apiKeyCount
        self.period = period
        self.updatedAt = updatedAt
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

enum DeepSeekUsageCostParser {
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

        let currency = costPayload.data?.bizData?.first?.currency ?? "CNY"

        // Parse total amounts
        let totalAmounts = amountBizData.total ?? []
        let totalCosts = costPayload.data?.bizData?.first?.total ?? []

        // Parse daily data
        let dailyAmounts = amountBizData.days ?? []
        let dailyCosts = costPayload.data?.bizData?.first?.days ?? []

        return self.aggregate(input: AggregationInput(
            totalAmounts: totalAmounts,
            totalCosts: totalCosts,
            dailyAmounts: dailyAmounts,
            dailyCosts: dailyCosts,
            currency: currency,
            now: now,
            calendar: calendar))
    }

    private static func isAuthenticationError(_ code: Int) -> Bool {
        code == 40002 || code == 40003
    }

    private static func decodingFailureDescription(_ error: any Error) -> String {
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
            self.todayString = Self.dayString(now, calendar: calendar)

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

        static func dayString(_ date: Date, calendar: Calendar) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { return "" }
            return String(format: "%04d-%02d-%02d", year, month, day)
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

    private static func aggregate(input: AggregationInput) -> DeepSeekUsageSummary {
        let ctx = AggregationContext(
            dailyAmounts: input.dailyAmounts,
            dailyCosts: input.dailyCosts,
            now: input.now,
            calendar: input.calendar)

        // Today aggregation
        let todayResult = self.aggregateDay(
            dateString: ctx.todayString,
            amountMap: ctx.dailyAmountMap,
            costMap: ctx.dailyCostMap,
            calendar: ctx.calendar)

        // Month aggregation
        let dailyCtx = DailyAggregationContext(
            allDates: ctx.allDates,
            startOfMonth: ctx.startOfMonth,
            now: ctx.now,
            amountMap: ctx.dailyAmountMap,
            costMap: ctx.dailyCostMap,
            calendar: ctx.calendar)
        let monthResult = self.aggregateMonth(ctx: dailyCtx)

        // Model and category breakdown from totals
        let (topModel, categoryBreakdown) = self.buildBreakdowns(
            totalAmounts: input.totalAmounts,
            totalCosts: input.totalCosts)

        // Daily usage array
        let dailyUsages = self.buildDailyUsages(ctx: dailyCtx)

        return DeepSeekUsageSummary(
            todayTokens: todayResult.tokens,
            currentMonthTokens: monthResult.tokens,
            todayCost: todayResult.cost,
            currentMonthCost: monthResult.cost,
            requestCount: todayResult.requests,
            currentMonthRequestCount: monthResult.requests,
            topModel: topModel,
            categoryBreakdown: categoryBreakdown,
            daily: dailyUsages,
            currency: input.currency,
            apiKeyCount: 0,
            period: .currentMonth,
            updatedAt: input.now)
    }

    private struct DayAggregationResult {
        let tokens: Int
        let cost: Double?
        let requests: Int
    }

    private struct DailyAggregationContext {
        let allDates: Set<String>
        let startOfMonth: Date
        let now: Date
        let amountMap: [String: [String: [DeepSeekUsageItem]]]
        let costMap: [String: [String: [DeepSeekCostItem]]]
        let calendar: Calendar
    }

    private static func aggregateDay(
        dateString: String,
        amountMap: [String: [String: [DeepSeekUsageItem]]],
        costMap: [String: [String: [DeepSeekCostItem]]],
        calendar: Calendar) -> DayAggregationResult
    {
        var tokens = 0
        var cost: Double?
        var requests = 0

        if let amounts = amountMap[dateString] {
            for items in amounts.values {
                for item in items {
                    guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                    if category == .request {
                        requests += self.parseTokenAmount(item.amount)
                    } else {
                        tokens += self.parseTokenAmount(item.amount)
                    }
                }
            }
        }

        if let costs = costMap[dateString] {
            for items in costs.values {
                for item in items {
                    guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                    if category != .request {
                        let amount = Self.parseCostAmount(item.amount)
                        if let existing = cost {
                            cost = existing + amount
                        } else {
                            cost = amount
                        }
                    }
                }
            }
        }

        return DayAggregationResult(tokens: tokens, cost: cost, requests: requests)
    }

    private static func aggregateMonth(ctx: DailyAggregationContext) -> DayAggregationResult {
        var tokens = 0
        var cost: Double?
        var requests = 0

        for date in ctx.allDates {
            guard let parsed = self.parseDate(date, calendar: ctx.calendar),
                  parsed >= ctx.startOfMonth,
                  parsed <= ctx.now
            else { continue }

            if let amounts = ctx.amountMap[date] {
                for items in amounts.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category == .request {
                            requests += Self.parseTokenAmount(item.amount)
                        } else {
                            tokens += Self.parseTokenAmount(item.amount)
                        }
                    }
                }
            }

            if let costs = ctx.costMap[date] {
                for items in costs.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category != .request {
                            let amount = Self.parseCostAmount(item.amount)
                            if let existing = cost {
                                cost = existing + amount
                            } else {
                                cost = amount
                            }
                        }
                    }
                }
            }
        }

        return DayAggregationResult(tokens: tokens, cost: cost, requests: requests)
    }

    private static func buildBreakdowns(
        totalAmounts: [DeepSeekModelUsage],
        totalCosts: [DeepSeekCostModelUsage]) -> (String?, [DeepSeekCategoryBreakdown])
    {
        var modelTokens: [String: Int] = [:]
        var categoryTokens: [DeepSeekUsageCategory: Int] = [:]
        var categoryCosts: [DeepSeekUsageCategory: Double] = [:]

        for modelUsage in totalAmounts {
            guard let model = modelUsage.model else { continue }
            var total = 0
            for item in modelUsage.usage ?? [] {
                guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                if category != .request {
                    let amount = Self.parseTokenAmount(item.amount)
                    total += amount
                    categoryTokens[category, default: 0] += amount
                }
            }
            modelTokens[model] = total
        }

        for costUsage in totalCosts {
            guard costUsage.model != nil else { continue }
            for item in costUsage.usage ?? [] {
                guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                if category != .request {
                    let amount = Self.parseCostAmount(item.amount)
                    categoryCosts[category, default: 0] += amount
                }
            }
        }

        let topModel = modelTokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key

        var breakdown: [DeepSeekCategoryBreakdown] = []
        for category in [DeepSeekUsageCategory.promptCacheHitToken, .promptCacheMissToken, .responseToken] {
            breakdown.append(DeepSeekCategoryBreakdown(
                category: category,
                tokens: categoryTokens[category] ?? 0,
                cost: categoryCosts[category]))
        }

        return (topModel, breakdown)
    }

    private static func buildDailyUsages(ctx: DailyAggregationContext) -> [DeepSeekDailyUsage] {
        var result: [DeepSeekDailyUsage] = []

        for date in ctx.allDates.sorted() {
            guard let parsed = self.parseDate(date, calendar: ctx.calendar),
                  parsed >= ctx.startOfMonth,
                  parsed <= ctx.now
            else { continue }

            var dayTokens = 0
            var dayCost: Double?
            var dayRequests = 0

            if let amounts = ctx.amountMap[date] {
                for items in amounts.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category == .request {
                            dayRequests += Self.parseTokenAmount(item.amount)
                        } else {
                            dayTokens += Self.parseTokenAmount(item.amount)
                        }
                    }
                }
            }

            if let costs = ctx.costMap[date] {
                for items in costs.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category != .request {
                            let amount = Self.parseCostAmount(item.amount)
                            if let existing = dayCost {
                                dayCost = existing + amount
                            } else {
                                dayCost = amount
                            }
                        }
                    }
                }
            }

            result.append(DeepSeekDailyUsage(
                date: date,
                totalTokens: dayTokens,
                cost: dayCost,
                requestCount: dayRequests))
        }

        return result
    }

    // MARK: - Helpers

    private static func parseTokenAmount(_ value: String?) -> Int {
        guard let value, let intValue = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return Int(intValue)
    }

    private static func parseCostAmount(_ value: String?) -> Double {
        guard let value else { return 0 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed) ?? 0
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
        let (amount, cost) = try self.decodeByAPIKeyPayloads(amountData: amountData, costData: costData)

        let start = rangeStart ?? calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let end = rangeEnd ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let startSeconds = Int(start.timeIntervalSince1970)
        let endSeconds = Int(end.timeIntervalSince1970)

        var dayAmounts: [String: [String: [DeepSeekUsageItem]]] = [:]
        var categoryTotals: [DeepSeekUsageCategory: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var apiKeyIDs = Set<String>()

        for series in amount.data?.bizData?.series ?? [] {
            if let id = series.apiKey?.id {
                apiKeyIDs.insert(id)
            }
            let model = series.model ?? "unknown"
            for bucket in series.buckets ?? [] where bucket.time >= startSeconds && bucket.time < endSeconds {
                let date = self.dayString(fromUnix: bucket.time, calendar: calendar)
                var items: [DeepSeekUsageItem] = []
                for (type, scalar) in bucket.usage ?? [:] {
                    items.append(DeepSeekUsageItem(type: type, amount: scalar.value))
                    guard let category = DeepSeekUsageCategory(rawValue: type) else { continue }
                    let value = self.parseTokenAmount(scalar.value)
                    if category == .request {
                        continue
                    }
                    categoryTotals[category, default: 0] += value
                    modelTokens[model, default: 0] += value
                }
                let existing = dayAmounts[date]?[model] ?? []
                var merged = existing
                merged.append(contentsOf: items)
                var models = dayAmounts[date] ?? [:]
                models[model] = merged
                dayAmounts[date] = models
            }
        }

        var dayCosts: [String: Double] = [:]
        let costBlocks = cost.data?.bizData?.data ?? []
        let selectedBlock = self.preferredCostBlock(costBlocks)
        let currency = selectedBlock?.currency?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "CNY"
        for series in selectedBlock?.series ?? [] {
            if let id = series.apiKey?.id {
                apiKeyIDs.insert(id)
            }
            for bucket in series.buckets ?? [] where bucket.time >= startSeconds && bucket.time < endSeconds {
                let date = self.dayString(fromUnix: bucket.time, calendar: calendar)
                dayCosts[date, default: 0] += Double(bucket.cost.value) ?? 0
            }
        }

        let todayString = AggregationContext.dayString(now, calendar: calendar)
        var periodTokens = 0
        var periodRequests = 0
        var daily: [DeepSeekDailyUsage] = []
        for date in Set(dayAmounts.keys).union(dayCosts.keys).sorted() {
            var tokens = 0
            var requests = 0
            if let amounts = dayAmounts[date] {
                for items in amounts.values {
                    for item in items {
                        guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                        if category == .request {
                            requests += self.parseTokenAmount(item.amount)
                        } else {
                            tokens += self.parseTokenAmount(item.amount)
                        }
                    }
                }
            }
            periodTokens += tokens
            periodRequests += requests
            daily.append(DeepSeekDailyUsage(
                date: date,
                totalTokens: tokens,
                cost: dayCosts[date],
                requestCount: requests))
        }

        let breakdown = [
            DeepSeekUsageCategory.promptCacheHitToken,
            .promptCacheMissToken,
            .responseToken,
        ].map { category in
            DeepSeekCategoryBreakdown(category: category, tokens: categoryTotals[category] ?? 0, cost: nil)
        }
        let topModel = modelTokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key

        let today = daily.first { $0.date == todayString }
        return DeepSeekUsageSummary(
            todayTokens: today?.totalTokens ?? 0,
            currentMonthTokens: periodTokens,
            todayCost: dayCosts[todayString],
            currentMonthCost: dayCosts.values.reduce(0, +),
            requestCount: today?.requestCount ?? 0,
            currentMonthRequestCount: periodRequests,
            topModel: topModel,
            categoryBreakdown: breakdown,
            daily: daily,
            currency: currency,
            apiKeyCount: apiKeyIDs.count,
            period: .last30Days,
            updatedAt: now)
    }

    private static func decodeByAPIKeyPayloads(amountData: Data, costData: Data) throws
        -> (ByAPIKeyAmountPayload, ByAPIKeyCostPayload)
    {
        let amount: ByAPIKeyAmountPayload
        let cost: ByAPIKeyCostPayload
        do {
            amount = try JSONDecoder().decode(ByAPIKeyAmountPayload.self, from: amountData)
        } catch {
            throw DeepSeekUsageError.parseFailed("amount: \(self.decodingFailureDescription(error))")
        }
        do {
            cost = try JSONDecoder().decode(ByAPIKeyCostPayload.self, from: costData)
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
        guard amount.data?.bizData != nil else {
            throw DeepSeekUsageError.parseFailed("Missing amount biz_data")
        }
        guard cost.data?.bizData != nil else {
            throw DeepSeekUsageError.parseFailed("Missing cost biz_data")
        }

        return (amount, cost)
    }

    private static func preferredCostBlock(_ blocks: [ByAPIKeyCostCurrency]) -> ByAPIKeyCostCurrency? {
        func spend(_ block: ByAPIKeyCostCurrency) -> Double {
            (block.series ?? []).reduce(0) { total, series in
                total + (series.buckets ?? []).reduce(0) { $0 + (Double($1.cost.value) ?? 0) }
            }
        }
        return blocks.first { $0.currency == "USD" && spend($0) > 0 }
            ?? blocks.first { spend($0) > 0 }
            ?? blocks.first { $0.currency == "USD" }
            ?? blocks.first
    }

    private static func dayString(fromUnix time: Int, calendar: Calendar) -> String {
        self.AggregationContext.dayString(Date(timeIntervalSince1970: TimeInterval(time)), calendar: calendar)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}

private struct ByAPIKeyAmountPayload: Decodable {
    let code: Int?
    let data: ByAPIKeyAmountData?
}

private struct ByAPIKeyAmountData: Decodable {
    let bizCode: Int?
    let bizData: ByAPIKeyAmountBiz?
    enum CodingKeys: String, CodingKey { case bizCode = "biz_code"; case bizData = "biz_data" }
}

private struct ByAPIKeyAmountBiz: Decodable {
    let series: [ByAPIKeyAmountSeries]?
}

private struct ByAPIKeyAmountSeries: Decodable {
    let apiKey: ByAPIKeyIdentity?
    let model: String?
    let buckets: [ByAPIKeyAmountBucket]?
    enum CodingKeys: String, CodingKey { case apiKey = "api_key"; case model, buckets }
}

private struct ByAPIKeyAmountBucket: Decodable {
    let time: Int
    let usage: [String: ByAPIKeyScalar]?
}

private struct ByAPIKeyCostPayload: Decodable {
    let code: Int?
    let data: ByAPIKeyCostData?
}

private struct ByAPIKeyCostData: Decodable {
    let bizCode: Int?
    let bizData: ByAPIKeyCostBiz?
    enum CodingKeys: String, CodingKey { case bizCode = "biz_code"; case bizData = "biz_data" }
}

private struct ByAPIKeyCostBiz: Decodable {
    let data: [ByAPIKeyCostCurrency]?
}

private struct ByAPIKeyCostCurrency: Decodable {
    let currency: String?
    let series: [ByAPIKeyCostSeries]?
}

private struct ByAPIKeyCostSeries: Decodable {
    let apiKey: ByAPIKeyIdentity?
    let model: String?
    let buckets: [ByAPIKeyCostBucket]?
    enum CodingKeys: String, CodingKey { case apiKey = "api_key"; case model, buckets }
}

private struct ByAPIKeyCostBucket: Decodable {
    let time: Int
    let cost: ByAPIKeyScalar
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
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = "0"
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

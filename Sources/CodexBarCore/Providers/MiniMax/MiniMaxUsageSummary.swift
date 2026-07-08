import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageSummary: Sendable, Equatable {
    public let totalDays: Int?
    public let totalTokenConsumed: String?
    public let usageRankingPercent: Double?
    public let activeDays: Int?
    public let currentConsecutiveDays: Int?
    public let lastUpdateTime: String?
    public let dailyTokenUsage: [Int]
    public let days: [MiniMaxUsageSummaryDay]

    public var latestDay: MiniMaxUsageSummaryDay? {
        self.days.last
    }

    public var latestActiveDay: MiniMaxUsageSummaryDay? {
        self.days.last { $0.totalToken > 0 }
    }

    public var snapshotDateKey: String {
        Self.dateKey(fromUpdateTime: self.lastUpdateTime) ?? Self.todayDateKey()
    }

    public var snapshotDay: MiniMaxUsageSummaryDay? {
        if let day = self.days.first(where: { $0.date == self.snapshotDateKey }) {
            return day
        }
        return self.latestDay
    }

    public var latestSnapshotTokens: Int {
        if let day = self.snapshotDay, day.totalToken > 0 {
            return day.totalToken
        }
        if let last = self.dailyTokenUsage.last, last > 0 {
            return last
        }
        return self.latestDay?.totalToken ?? 0
    }

    public var last7DaysTokens: Int {
        self.tokenTotal(lastDays: 7)
    }

    public var last30DaysTokens: Int {
        self.tokenTotal(lastDays: 30)
    }

    public func trendDays(last count: Int) -> [MiniMaxUsageSummaryDay] {
        if !self.days.isEmpty {
            return Array(self.days.suffix(count))
        }
        guard !self.dailyTokenUsage.isEmpty else { return [] }
        let values = Array(self.dailyTokenUsage.suffix(count))
        let calendar = Calendar.current
        let snapshotDate = Self.date(fromDateKey: self.snapshotDateKey) ?? Date()
        let snapshotDay = calendar.startOfDay(for: snapshotDate)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return values.enumerated().map { index, tokens in
            let daysBack = values.count - 1 - index
            let date = calendar.date(byAdding: .day, value: -daysBack, to: snapshotDay) ?? snapshotDay
            return MiniMaxUsageSummaryDay(
                date: formatter.string(from: date),
                totalInputToken: 0,
                totalCacheReadToken: 0,
                totalCacheCreateToken: 0,
                totalOutputToken: 0,
                totalToken: tokens,
                cacheHitPercent: nil,
                models: [])
        }
    }

    public var hasDisplayableData: Bool {
        !self.dailyTokenUsage.isEmpty || self.days.contains { $0.totalToken > 0 }
    }

    public var latestModelNames: [String] {
        (self.latestActiveDay?.models ?? []).map(\.model)
    }

    public init(
        totalDays: Int?,
        totalTokenConsumed: String?,
        usageRankingPercent: Double?,
        activeDays: Int?,
        currentConsecutiveDays: Int?,
        lastUpdateTime: String?,
        dailyTokenUsage: [Int],
        days: [MiniMaxUsageSummaryDay])
    {
        self.totalDays = totalDays
        self.totalTokenConsumed = totalTokenConsumed
        self.usageRankingPercent = usageRankingPercent
        self.activeDays = activeDays
        self.currentConsecutiveDays = currentConsecutiveDays
        self.lastUpdateTime = lastUpdateTime
        self.dailyTokenUsage = dailyTokenUsage
        self.days = days
    }

    private func tokenTotal(lastDays count: Int) -> Int {
        if !self.dailyTokenUsage.isEmpty {
            let sum = self.dailyTokenUsage.suffix(count).reduce(0, +)
            if sum > 0 {
                return sum
            }
        }
        return self.days.suffix(count).reduce(0) { $0 + $1.totalToken }
    }

    static func dateKey(fromUpdateTime raw: String?, referenceDate: Date = Date()) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let datePart = raw.split(separator: " ").first.map(String.init) ?? raw
        let parts = datePart.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return nil
        }
        let calendar = Calendar.current
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone.current
        components.year = calendar.component(.year, from: referenceDate)
        components.month = month
        components.day = day
        guard var date = components.date else { return nil }
        let futureThreshold = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
        if date > futureThreshold {
            components.year = (components.year ?? calendar.component(.year, from: referenceDate)) - 1
            guard let adjusted = components.date else { return nil }
            date = adjusted
        }
        return Self.todayDateKey(for: date)
    }

    private static func date(fromDateKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    static func todayDateKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct MiniMaxUsageSummaryDay: Sendable, Equatable {
    public let date: String
    public let totalInputToken: Int
    public let totalCacheReadToken: Int
    public let totalCacheCreateToken: Int
    public let totalOutputToken: Int
    public let totalToken: Int
    public let cacheHitPercent: Double?
    public let models: [MiniMaxUsageSummaryModel]

    public init(
        date: String,
        totalInputToken: Int,
        totalCacheReadToken: Int,
        totalCacheCreateToken: Int,
        totalOutputToken: Int,
        totalToken: Int,
        cacheHitPercent: Double?,
        models: [MiniMaxUsageSummaryModel])
    {
        self.date = date
        self.totalInputToken = totalInputToken
        self.totalCacheReadToken = totalCacheReadToken
        self.totalCacheCreateToken = totalCacheCreateToken
        self.totalOutputToken = totalOutputToken
        self.totalToken = totalToken
        self.cacheHitPercent = cacheHitPercent
        self.models = models
    }
}

public struct MiniMaxUsageSummaryModel: Sendable, Equatable {
    public let model: String
    public let inputToken: Int
    public let cacheReadToken: Int
    public let cacheCreateToken: Int
    public let outputToken: Int
    public let totalToken: Int
    public let cacheHitPercent: Double?

    public init(
        model: String,
        inputToken: Int,
        cacheReadToken: Int,
        cacheCreateToken: Int,
        outputToken: Int,
        totalToken: Int,
        cacheHitPercent: Double?)
    {
        self.model = model
        self.inputToken = inputToken
        self.cacheReadToken = cacheReadToken
        self.cacheCreateToken = cacheCreateToken
        self.outputToken = outputToken
        self.totalToken = totalToken
        self.cacheHitPercent = cacheHitPercent
    }
}

enum MiniMaxUsageSummaryFetcher {
    private static let usageSummaryPath = "backend/account/token_plan/usage_summary"

    static func resolveUsageSummaryURL(
        region: MiniMaxAPIRegion,
        environment: [String: String]) throws -> URL?
    {
        if let rejectedKey = MiniMaxSettingsReader.rejectedEndpointOverrideKey(environment: environment) {
            throw ProviderEndpointOverrideError.minimax(rejectedKey)
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment) {
            let lowered = host.lowercased()
            if !lowered.contains("minimax.io"), !lowered.contains("minimaxi.com"),
               let hostURL = MiniMaxUsageFetcher.url(from: host, path: Self.usageSummaryPath)
            {
                return hostURL
            }
        }
        return MiniMaxTokenPlanCreditFetcher
            .effectiveRegion(for: region, environment: environment)
            .tokenPlanUsageSummaryURL
    }

    static func fetch(
        cookieHeader: String,
        groupID: String?,
        region: MiniMaxAPIRegion,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> MiniMaxUsageSummary
    {
        guard let url = try resolveUsageSummaryURL(region: region, environment: environment) else {
            throw MiniMaxUsageError.apiError("MiniMax usage summary endpoint unavailable for configured host.")
        }
        let effectiveRegion = MiniMaxTokenPlanCreditFetcher.effectiveRegion(for: region, environment: environment)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let groupID = groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !groupID.isEmpty {
            request.setValue(groupID, forHTTPHeaderField: "x-group-id")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        let origin = MiniMaxSubscriptionMetadataFetcher.platformOriginURL(region: effectiveRegion)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "origin")
        request.setValue(origin.absoluteString + "/", forHTTPHeaderField: "referer")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try MiniMaxUsageSummaryParser.parse(data: response.data)
    }
}

private struct MiniMaxUsageSummaryPayload: Decodable {
    let totalDays: Int?
    let totalTokenConsumed: String?
    let usageRankingPercent: Double?
    let activeDays: Int?
    let currentConsecutiveDays: Int?
    let dailyTokenUsage: [Int]
    let dateModelUsage: [MiniMaxUsageSummaryDayPayload]
    let lastUpdateTime: String?
    let baseResp: MiniMaxBaseResponse?

    private enum CodingKeys: String, CodingKey {
        case totalDays = "total_days"
        case totalTokenConsumed = "total_token_consumed"
        case usageRankingPercent = "usage_ranking_percent"
        case activeDays = "active_days"
        case currentConsecutiveDays = "current_consecutive_days"
        case dailyTokenUsage = "daily_token_usage"
        case dateModelUsage = "date_model_usage"
        case lastUpdateTime = "last_update_time"
        case baseResp = "base_resp"
    }
}

private struct MiniMaxUsageSummaryDayPayload: Decodable {
    let date: String
    let totalInputToken: Int
    let totalCacheReadToken: Int
    let totalCacheCreateToken: Int
    let totalOutputToken: Int
    let totalToken: Int
    let cacheHitPercent: String?
    let models: [MiniMaxUsageSummaryModelPayload]

    private enum CodingKeys: String, CodingKey {
        case date
        case totalInputToken = "total_input_token"
        case totalCacheReadToken = "total_cache_read_token"
        case totalCacheCreateToken = "total_cache_create_token"
        case totalOutputToken = "total_output_token"
        case totalToken = "total_token"
        case cacheHitPercent = "cache_hit_percent"
        case models
    }
}

private struct MiniMaxUsageSummaryModelPayload: Decodable {
    let model: String
    let inputToken: Int
    let cacheReadToken: Int
    let cacheCreateToken: Int
    let outputToken: Int
    let totalToken: Int
    let cacheHitPercent: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case inputToken = "input_token"
        case cacheReadToken = "cache_read_token"
        case cacheCreateToken = "cache_create_token"
        case outputToken = "output_token"
        case totalToken = "total_token"
        case cacheHitPercent = "cache_hit_percent"
    }
}

enum MiniMaxUsageSummaryParser {
    static func parse(data: Data) throws -> MiniMaxUsageSummary {
        let payload = try JSONDecoder().decode(MiniMaxUsageSummaryPayload.self, from: data)
        if let status = payload.baseResp?.statusCode, status != 0 {
            let message = payload.baseResp?.statusMessage ?? "status_code \(status)"
            if status == 1004 || message.lowercased().contains("cookie")
                || message.lowercased().contains("login")
            {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError(message)
        }
        return MiniMaxUsageSummary(
            totalDays: payload.totalDays,
            totalTokenConsumed: payload.totalTokenConsumed,
            usageRankingPercent: payload.usageRankingPercent,
            activeDays: payload.activeDays,
            currentConsecutiveDays: payload.currentConsecutiveDays,
            lastUpdateTime: payload.lastUpdateTime,
            dailyTokenUsage: payload.dailyTokenUsage,
            days: payload.dateModelUsage.map(self.day))
    }

    private static func day(_ payload: MiniMaxUsageSummaryDayPayload) -> MiniMaxUsageSummaryDay {
        MiniMaxUsageSummaryDay(
            date: payload.date,
            totalInputToken: payload.totalInputToken,
            totalCacheReadToken: payload.totalCacheReadToken,
            totalCacheCreateToken: payload.totalCacheCreateToken,
            totalOutputToken: payload.totalOutputToken,
            totalToken: payload.totalToken,
            cacheHitPercent: self.percent(from: payload.cacheHitPercent),
            models: payload.models.map(self.model))
    }

    private static func model(_ payload: MiniMaxUsageSummaryModelPayload) -> MiniMaxUsageSummaryModel {
        MiniMaxUsageSummaryModel(
            model: payload.model,
            inputToken: payload.inputToken,
            cacheReadToken: payload.cacheReadToken,
            cacheCreateToken: payload.cacheCreateToken,
            outputToken: payload.outputToken,
            totalToken: payload.totalToken,
            cacheHitPercent: self.percent(from: payload.cacheHitPercent))
    }

    private static func percent(from raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenRouter's account activity for completed UTC days, aggregated by routed model slug.
public struct OpenRouterActivityUsageSnapshot: Codable, Equatable, Sendable {
    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let model: String
        public let promptTokens: Int
        public let completionTokens: Int
        /// Informational only. OpenRouter includes these tokens in `completionTokens`.
        public let reasoningTokens: Int
        public let requests: Int
        public let usageUSD: Double

        public var id: String {
            self.model
        }

        public var totalTokens: Int {
            self.promptTokens + self.completionTokens
        }
    }

    public struct DailyBucket: Codable, Equatable, Sendable, Identifiable {
        public let date: String
        public let promptTokens: Int
        public let completionTokens: Int
        /// Informational only. OpenRouter includes these tokens in `completionTokens`.
        public let reasoningTokens: Int
        public let requests: Int
        public let usageUSD: Double
        public let models: [ModelBreakdown]

        public var id: String {
            self.date
        }

        public var totalTokens: Int {
            self.promptTokens + self.completionTokens
        }
    }

    public let daily: [DailyBucket]
    public let historyDays: Int
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case daily
        case historyDays
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let daily = try container.decode([DailyBucket].self, forKey: .daily)
        let historyDays = try container.decode(Int.self, forKey: .historyDays)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        do {
            try Self.validate(daily: daily, historyDays: historyDays, updatedAt: updatedAt)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .daily,
                in: container,
                debugDescription: "OpenRouter activity history is invalid")
        }
        self.daily = daily
        self.historyDays = historyDays
        self.updatedAt = updatedAt
    }

    /// Decodes the documented `/api/v1/activity` envelope and keeps only the requested
    /// completed UTC-day window. OpenRouter currently exposes at most 30 completed days.
    public init(data: Data, now: Date, historyDays: Int = 30) throws {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let days = max(1, min(30, historyDays))
        let calendar = Self.utcCalendar
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -days, to: today) else {
            throw DecodeError.invalidDateWindow
        }

        var accumulators: [BucketKey: Accumulator] = [:]
        for item in response.data {
            guard let date = Self.date(from: item.date) else { throw DecodeError.invalidActivityItem }
            guard date >= firstDay, date < today else { continue }
            let model = item.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  item.promptTokens >= 0,
                  item.completionTokens >= 0,
                  item.reasoningTokens >= 0,
                  item.requests >= 0,
                  item.usage.isFinite,
                  item.usage >= 0
            else {
                throw DecodeError.invalidActivityItem
            }
            let key = BucketKey(date: item.date, model: model)
            try accumulators[key, default: Accumulator()].add(item)
        }

        let modelBuckets = Dictionary(grouping: accumulators, by: { $0.key.date })
        let daily = try modelBuckets.map { date, values in
            let models = try values.map { key, accumulator in
                try accumulator.modelBreakdown(model: key.model)
            }.sorted(by: Self.modelSort)
            let promptTokens = try Self.sum(models.map(\.promptTokens))
            let completionTokens = try Self.sum(models.map(\.completionTokens))
            _ = try Self.add(promptTokens, completionTokens)
            return try DailyBucket(
                date: date,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                reasoningTokens: Self.sum(models.map(\.reasoningTokens)),
                requests: Self.sum(models.map(\.requests)),
                usageUSD: Self.sum(models.map(\.usageUSD)),
                models: models)
        }.sorted { $0.date < $1.date }
        try Self.validate(daily: daily, historyDays: days, updatedAt: now)
        self.daily = daily
        self.historyDays = days
        self.updatedAt = now
    }

    public func toCostUsageTokenSnapshot() -> CostUsageTokenSnapshot {
        let daily = self.daily.map { bucket in
            CostUsageDailyReport.Entry(
                date: bucket.date,
                inputTokens: bucket.promptTokens,
                outputTokens: bucket.completionTokens,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.requests,
                costUSD: bucket.usageUSD,
                modelsUsed: bucket.models.map(\.model),
                modelBreakdowns: bucket.models.map { model in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model.model,
                        costUSD: model.usageUSD,
                        totalTokens: model.totalTokens,
                        requestCount: model.requests)
                })
        }
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: self.daily.reduce(0) { $0 + $1.totalTokens },
            last30DaysCostUSD: self.daily.reduce(0) { $0 + $1.usageUSD },
            last30DaysRequests: self.daily.reduce(0) { $0 + $1.requests },
            currencyCode: "USD",
            historyDays: self.historyDays,
            historyCoverageIsEstablished: true,
            historyLabel: "OpenRouter account activity · Last \(self.historyDays) completed UTC days",
            daily: daily,
            updatedAt: self.updatedAt)
    }

    private struct Response: Decodable {
        let data: [Item]
    }

    private struct Item: Decodable {
        let date: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let reasoningTokens: Int
        let requests: Int
        let usage: Double

        private enum CodingKeys: String, CodingKey {
            case date
            case model
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case reasoningTokens = "reasoning_tokens"
            case requests
            case usage
        }
    }

    private struct BucketKey: Hashable {
        let date: String
        let model: String
    }

    private struct Accumulator {
        var promptTokens = 0
        var completionTokens = 0
        var reasoningTokens = 0
        var requests = 0
        var usageUSD = 0.0

        mutating func add(_ item: Item) throws {
            self.promptTokens = try OpenRouterActivityUsageSnapshot.add(self.promptTokens, item.promptTokens)
            self.completionTokens = try OpenRouterActivityUsageSnapshot.add(
                self.completionTokens,
                item.completionTokens)
            self.reasoningTokens = try OpenRouterActivityUsageSnapshot.add(
                self.reasoningTokens,
                item.reasoningTokens)
            self.requests = try OpenRouterActivityUsageSnapshot.add(self.requests, item.requests)
            self.usageUSD += item.usage
            guard self.usageUSD.isFinite else { throw DecodeError.numericOverflow }
        }

        func modelBreakdown(model: String) throws -> ModelBreakdown {
            _ = try OpenRouterActivityUsageSnapshot.add(self.promptTokens, self.completionTokens)
            return ModelBreakdown(
                model: model,
                promptTokens: self.promptTokens,
                completionTokens: self.completionTokens,
                reasoningTokens: self.reasoningTokens,
                requests: self.requests,
                usageUSD: self.usageUSD)
        }
    }

    private enum DecodeError: Error {
        case invalidDateWindow
        case invalidActivityItem
        case numericOverflow
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func date(from key: String) -> Date? {
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = self.utcCalendar.date(from: DateComponents(
                  timeZone: self.utcCalendar.timeZone,
                  year: parts[0],
                  month: parts[1],
                  day: parts[2])),
              self.dateKey(date) == key
        else { return nil }
        return date
    }

    private static func dateKey(_ date: Date) -> String {
        let components = self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw DecodeError.numericOverflow }
        return result.partialValue
    }

    private static func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { try self.add($0, $1) }
    }

    private static func sum(_ values: [Double]) throws -> Double {
        let total = values.reduce(0, +)
        guard total.isFinite else { throw DecodeError.numericOverflow }
        return total
    }

    private static func validate(
        daily: [DailyBucket],
        historyDays: Int,
        updatedAt: Date) throws
    {
        guard (1...30).contains(historyDays), daily.count <= historyDays else {
            throw DecodeError.invalidActivityItem
        }
        let today = self.utcCalendar.startOfDay(for: updatedAt)
        guard let firstDay = self.utcCalendar.date(byAdding: .day, value: -historyDays, to: today) else {
            throw DecodeError.invalidDateWindow
        }
        var dates = Set<String>()
        for bucket in daily {
            guard let date = self.date(from: bucket.date),
                  date >= firstDay,
                  date < today,
                  dates.insert(bucket.date).inserted,
                  bucket.promptTokens >= 0,
                  bucket.completionTokens >= 0,
                  bucket.reasoningTokens >= 0,
                  bucket.requests >= 0,
                  bucket.usageUSD.isFinite,
                  bucket.usageUSD >= 0,
                  !bucket.models.isEmpty,
                  bucket.models.count <= 10000
            else { throw DecodeError.invalidActivityItem }
            _ = try self.add(bucket.promptTokens, bucket.completionTokens)

            var modelNames = Set<String>()
            for model in bucket.models {
                guard !model.model.isEmpty,
                      modelNames.insert(model.model).inserted,
                      model.promptTokens >= 0,
                      model.completionTokens >= 0,
                      model.reasoningTokens >= 0,
                      model.requests >= 0,
                      model.usageUSD.isFinite,
                      model.usageUSD >= 0
                else { throw DecodeError.invalidActivityItem }
                _ = try self.add(model.promptTokens, model.completionTokens)
            }
            let promptTokens = try self.sum(bucket.models.map(\.promptTokens))
            let completionTokens = try self.sum(bucket.models.map(\.completionTokens))
            let reasoningTokens = try self.sum(bucket.models.map(\.reasoningTokens))
            let requests = try self.sum(bucket.models.map(\.requests))
            let usageUSD = try self.sum(bucket.models.map(\.usageUSD))
            guard bucket.promptTokens == promptTokens,
                  bucket.completionTokens == completionTokens,
                  bucket.reasoningTokens == reasoningTokens,
                  bucket.requests == requests,
                  bucket.usageUSD == usageUSD
            else { throw DecodeError.invalidActivityItem }
        }
        _ = try self.sum(daily.map { try self.add($0.promptTokens, $0.completionTokens) })
        _ = try self.sum(daily.map(\.requests))
        _ = try self.sum(daily.map(\.usageUSD))
    }

    private static func modelSort(_ lhs: ModelBreakdown, _ rhs: ModelBreakdown) -> Bool {
        if lhs.usageUSD != rhs.usageUSD { return lhs.usageUSD > rhs.usageUSD }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }
}

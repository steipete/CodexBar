import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeAdminAPIUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(endpoint: String, statusCode: Int)
    case parseFailed(endpoint: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Anthropic Admin API key."
        case let .networkError(message):
            "Claude API usage network error: \(message)"
        case let .apiError(endpoint, statusCode):
            "Claude API usage \(endpoint) error: HTTP \(statusCode)"
        case let .parseFailed(endpoint, message):
            "Failed to parse Claude API usage \(endpoint): \(message)"
        }
    }
}

public enum ClaudeAdminAPIUsageFetcher {
    public static let costReportURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    public static let messagesUsageURL =
        URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!

    private static let anthropicVersion = "2023-06-01"
    private static let timeoutSeconds: TimeInterval = 20
    private static let maxDailyBuckets = 31

    public static func fetchUsage(
        apiKey: String,
        costURL: URL = Self.costReportURL,
        messagesURL: URL = Self.messagesUsageURL,
        session: URLSession = .shared,
        now: Date = Date()) async throws -> ClaudeAdminAPIUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeAdminAPIUsageError.missingCredentials
        }

        let calendar = Self.utcCalendar
        let range = Self.dailyRange(now: now, calendar: calendar)
        let costs = try await Self.fetchCostReport(
            apiKey: trimmed,
            baseURL: costURL,
            range: range,
            session: session)
        let messages = try await Self.fetchMessagesUsage(
            apiKey: trimmed,
            baseURL: messagesURL,
            range: range,
            session: session)

        return Self.makeSnapshot(costs: costs, messages: messages, now: now, calendar: calendar)
    }

    static func _parseSnapshotForTesting(
        costs: Data,
        messages: Data,
        now: Date,
        calendar: Calendar = Self.utcCalendar) throws -> ClaudeAdminAPIUsageSnapshot
    {
        let costs = try Self.decodeCosts(costs)
        let messages = try Self.decodeMessages(messages)
        return Self.makeSnapshot(costs: costs, messages: messages, now: now, calendar: calendar)
    }

    private static func fetchCostReport(
        apiKey: String,
        baseURL: URL,
        range: DateRange,
        session: URLSession) async throws -> CostReportResponse
    {
        let url = Self.url(
            baseURL: baseURL,
            range: range,
            queryItems: [
                URLQueryItem(name: "group_by[]", value: "description"),
            ])
        let data = try await Self.fetchData(url: url, apiKey: apiKey, endpoint: "cost_report", session: session)
        return try Self.decodeCosts(data)
    }

    private static func fetchMessagesUsage(
        apiKey: String,
        baseURL: URL,
        range: DateRange,
        session: URLSession) async throws -> MessagesUsageResponse
    {
        let url = Self.url(
            baseURL: baseURL,
            range: range,
            queryItems: [
                URLQueryItem(name: "group_by[]", value: "model"),
            ])
        let data = try await Self.fetchData(url: url, apiKey: apiKey, endpoint: "messages", session: session)
        return try Self.decodeMessages(data)
    }

    private static func fetchData(
        url: URL,
        apiKey: String,
        endpoint: String,
        session: URLSession) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeAdminAPIUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAdminAPIUsageError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw ClaudeAdminAPIUsageError.apiError(endpoint: endpoint, statusCode: httpResponse.statusCode)
        }
        return data
    }

    private static func decodeCosts(_ data: Data) throws -> CostReportResponse {
        do {
            return try JSONDecoder().decode(CostReportResponse.self, from: data)
        } catch {
            throw ClaudeAdminAPIUsageError.parseFailed(endpoint: "cost_report", message: error.localizedDescription)
        }
    }

    private static func decodeMessages(_ data: Data) throws -> MessagesUsageResponse {
        do {
            return try JSONDecoder().decode(MessagesUsageResponse.self, from: data)
        } catch {
            throw ClaudeAdminAPIUsageError.parseFailed(endpoint: "messages", message: error.localizedDescription)
        }
    }

    private static func makeSnapshot(
        costs: CostReportResponse,
        messages: MessagesUsageResponse,
        now: Date,
        calendar: Calendar) -> ClaudeAdminAPIUsageSnapshot
    {
        var accumulators: [String: DailyAccumulator] = [:]

        for bucket in costs.data {
            var accumulator = accumulators[bucket.startingAt] ?? DailyAccumulator(
                startingAt: bucket.startingAt,
                endingAt: bucket.endingAt)
            for result in bucket.results {
                // Anthropic Usage & Cost API docs define `amount` as a decimal string in lowest USD units.
                let value = Self.usdFromAnthropicLowestUnitAmount(result.amount)
                accumulator.costUSD += value
                let item = Self.displayName(result.description ?? result.costType, fallback: "Claude API")
                accumulator.costItems[item, default: 0] += value
            }
            accumulators[bucket.startingAt] = accumulator
        }

        for bucket in messages.data {
            var accumulator = accumulators[bucket.startingAt] ?? DailyAccumulator(
                startingAt: bucket.startingAt,
                endingAt: bucket.endingAt)
            for result in bucket.results {
                let input = result.uncachedInputTokens ?? 0
                let cacheCreation = result.cacheCreation?.totalInputTokens ?? 0
                let cacheRead = result.cacheReadInputTokens ?? 0
                let output = result.outputTokens ?? 0
                let total = input + cacheCreation + cacheRead + output
                accumulator.inputTokens += input
                accumulator.cacheCreationInputTokens += cacheCreation
                accumulator.cacheReadInputTokens += cacheRead
                accumulator.outputTokens += output
                accumulator.totalTokens += total
                let modelName = Self.displayName(result.model, fallback: "Claude API")
                accumulator.models[modelName, default: ModelAccumulator()].add(
                    inputTokens: input,
                    cacheCreationInputTokens: cacheCreation,
                    cacheReadInputTokens: cacheRead,
                    outputTokens: output,
                    totalTokens: total)
            }
            accumulators[bucket.startingAt] = accumulator
        }

        let daily = accumulators.values
            .compactMap { $0.makeBucket(calendar: calendar) }
            .filter { $0.startTime <= now }
            .sorted { $0.startTime < $1.startTime }
        return ClaudeAdminAPIUsageSnapshot(daily: daily, updatedAt: now)
    }

    private static func displayName(_ raw: String?, fallback: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }

    private static func usdFromAnthropicLowestUnitAmount(_ raw: String) -> Double {
        (Double(raw) ?? 0) / 100
    }

    private static func url(baseURL: URL, range: DateRange, queryItems extraItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: Self.rfc3339String(from: range.start)),
            URLQueryItem(name: "ending_at", value: Self.rfc3339String(from: range.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(Self.maxDailyBuckets)),
        ] + extraItems
        return components.url!
    }

    private static func dailyRange(now: Date, calendar: Calendar) -> DateRange {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(Self.maxDailyBuckets - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DateRange(start: start, end: end)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func rfc3339Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func rfc3339String(from date: Date) -> String {
        self.rfc3339Formatter().string(from: date)
    }

    fileprivate static func dayKey(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    fileprivate static func parseDate(_ raw: String) -> Date? {
        self.rfc3339Formatter().date(from: raw)
    }
}

private struct DateRange {
    let start: Date
    let end: Date
}

private struct DailyAccumulator {
    let startingAt: String
    let endingAt: String
    var costUSD: Double = 0
    var inputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var costItems: [String: Double] = [:]
    var models: [String: ModelAccumulator] = [:]

    func makeBucket(calendar: Calendar) -> ClaudeAdminAPIUsageSnapshot.DailyBucket? {
        guard let start = ClaudeAdminAPIUsageFetcher.parseDate(self.startingAt),
              let end = ClaudeAdminAPIUsageFetcher.parseDate(self.endingAt)
        else { return nil }
        return ClaudeAdminAPIUsageSnapshot.DailyBucket(
            day: ClaudeAdminAPIUsageFetcher.dayKey(from: start, calendar: calendar),
            startTime: start,
            endTime: end,
            costUSD: self.costUSD,
            inputTokens: self.inputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens,
            costItems: self.costItems
                .map { ClaudeAdminAPIUsageSnapshot.CostBreakdown(name: $0.key, costUSD: $0.value) }
                .sorted {
                    if $0.costUSD == $1.costUSD { return $0.name < $1.name }
                    return $0.costUSD > $1.costUSD
                },
            models: self.models
                .map { name, total in total.makeModel(name: name) }
                .sorted {
                    if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
                    return $0.totalTokens > $1.totalTokens
                })
    }
}

private struct ModelAccumulator {
    var inputTokens = 0
    var cacheCreationInputTokens = 0
    var cacheReadInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0

    mutating func add(
        inputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int)
    {
        self.inputTokens += inputTokens
        self.cacheCreationInputTokens += cacheCreationInputTokens
        self.cacheReadInputTokens += cacheReadInputTokens
        self.outputTokens += outputTokens
        self.totalTokens += totalTokens
    }

    func makeModel(name: String) -> ClaudeAdminAPIUsageSnapshot.ModelBreakdown {
        ClaudeAdminAPIUsageSnapshot.ModelBreakdown(
            name: name,
            inputTokens: self.inputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens)
    }
}

private struct CostReportResponse: Decodable {
    let data: [CostBucket]
    let hasMore: Bool?
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct CostBucket: Decodable {
    let startingAt: String
    let endingAt: String
    let results: [CostResult]

    private enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct CostResult: Decodable {
    let currency: String?
    let amount: String
    let description: String?
    let costType: String?

    private enum CodingKeys: String, CodingKey {
        case currency
        case amount
        case description
        case costType = "cost_type"
    }
}

private struct MessagesUsageResponse: Decodable {
    let data: [MessagesBucket]
    let hasMore: Bool?
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct MessagesBucket: Decodable {
    let startingAt: String
    let endingAt: String
    let results: [MessagesResult]

    private enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct MessagesResult: Decodable {
    let uncachedInputTokens: Int?
    let cacheCreation: CacheCreation?
    let cacheReadInputTokens: Int?
    let outputTokens: Int?
    let model: String?

    private enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreation = "cache_creation"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}

private struct CacheCreation: Decodable {
    let ephemeral1HInputTokens: Int?
    let ephemeral5MInputTokens: Int?

    var totalInputTokens: Int {
        (self.ephemeral1HInputTokens ?? 0) + (self.ephemeral5MInputTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case ephemeral1HInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5MInputTokens = "ephemeral_5m_input_tokens"
    }
}

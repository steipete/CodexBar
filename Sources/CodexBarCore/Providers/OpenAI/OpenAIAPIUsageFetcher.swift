import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAIAPIUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(endpoint: String, statusCode: Int)
    case parseFailed(endpoint: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing OpenAI Admin API key."
        case let .networkError(message):
            "OpenAI API usage network error: \(message)"
        case let .apiError(endpoint, statusCode):
            "OpenAI API usage \(endpoint) error: HTTP \(statusCode)"
        case let .parseFailed(endpoint, message):
            "Failed to parse OpenAI API usage \(endpoint): \(message)"
        }
    }

    var isCredentialRejected: Bool {
        switch self {
        case let .apiError(_, statusCode):
            statusCode == 401 || statusCode == 403
        default:
            false
        }
    }
}

public enum OpenAIAPIUsageFetcher {
    public static let organizationCostsURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    public static let organizationCompletionsUsageURL =
        URL(string: "https://api.openai.com/v1/organization/usage/completions")!

    private static let timeoutSeconds: TimeInterval = 20
    private static let maxDailyBuckets = 31

    public static func fetchUsage(
        apiKey: String,
        costsURL: URL = Self.organizationCostsURL,
        completionsURL: URL = Self.organizationCompletionsUsageURL,
        session: URLSession = .shared,
        now: Date = Date()) async throws -> OpenAIAPIUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIAPIUsageError.missingCredentials
        }

        let calendar = Self.utcCalendar
        let range = Self.dailyRange(now: now, calendar: calendar)
        let costs = try await Self.fetchCosts(
            apiKey: trimmed,
            baseURL: costsURL,
            range: range,
            session: session)
        let completions = try await Self.fetchCompletions(
            apiKey: trimmed,
            baseURL: completionsURL,
            range: range,
            session: session)

        return Self.makeSnapshot(
            costs: costs,
            completions: completions,
            now: now,
            calendar: calendar)
    }

    static func _parseSnapshotForTesting(
        costs: Data,
        completions: Data,
        now: Date,
        calendar: Calendar = Self.utcCalendar) throws -> OpenAIAPIUsageSnapshot
    {
        let costs = try Self.decodeCosts(costs)
        let completions = try Self.decodeCompletions(completions)
        return Self.makeSnapshot(costs: costs, completions: completions, now: now, calendar: calendar)
    }

    private static func fetchCosts(
        apiKey: String,
        baseURL: URL,
        range: DateRange,
        session: URLSession) async throws -> CostsResponse
    {
        let url = Self.url(
            baseURL: baseURL,
            range: range,
            queryItems: [
                URLQueryItem(name: "group_by", value: "line_item"),
            ])
        let data = try await Self.fetchData(url: url, apiKey: apiKey, endpoint: "costs", session: session)
        return try Self.decodeCosts(data)
    }

    private static func fetchCompletions(
        apiKey: String,
        baseURL: URL,
        range: DateRange,
        session: URLSession) async throws -> CompletionsUsageResponse
    {
        let url = Self.url(
            baseURL: baseURL,
            range: range,
            queryItems: [
                URLQueryItem(name: "group_by", value: "model"),
            ])
        let data = try await Self.fetchData(url: url, apiKey: apiKey, endpoint: "completions", session: session)
        return try Self.decodeCompletions(data)
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIAPIUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAPIUsageError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw OpenAIAPIUsageError.apiError(endpoint: endpoint, statusCode: httpResponse.statusCode)
        }
        return data
    }

    private static func decodeCosts(_ data: Data) throws -> CostsResponse {
        do {
            return try JSONDecoder().decode(CostsResponse.self, from: data)
        } catch {
            throw OpenAIAPIUsageError.parseFailed(endpoint: "costs", message: error.localizedDescription)
        }
    }

    private static func decodeCompletions(_ data: Data) throws -> CompletionsUsageResponse {
        do {
            return try JSONDecoder().decode(CompletionsUsageResponse.self, from: data)
        } catch {
            throw OpenAIAPIUsageError.parseFailed(endpoint: "completions", message: error.localizedDescription)
        }
    }

    private static func makeSnapshot(
        costs: CostsResponse,
        completions: CompletionsUsageResponse,
        now: Date,
        calendar: Calendar) -> OpenAIAPIUsageSnapshot
    {
        var accumulators: [Int: DailyAccumulator] = [:]

        for bucket in costs.data {
            var accumulator = accumulators[bucket.startTime] ?? DailyAccumulator(
                startTime: bucket.startTime,
                endTime: bucket.endTime)
            for result in bucket.results {
                let value = result.amount?.value ?? 0
                accumulator.costUSD += value
                let lineItem = Self.displayName(result.lineItem, fallback: "API")
                accumulator.lineItems[lineItem, default: 0] += value
            }
            accumulators[bucket.startTime] = accumulator
        }

        for bucket in completions.data {
            var accumulator = accumulators[bucket.startTime] ?? DailyAccumulator(
                startTime: bucket.startTime,
                endTime: bucket.endTime)
            for result in bucket.results {
                let input = result.inputTokens ?? 0
                let cached = result.inputCachedTokens ?? 0
                let output = result.outputTokens ?? 0
                let audioInput = result.inputAudioTokens ?? 0
                let audioOutput = result.outputAudioTokens ?? 0
                let requests = result.numModelRequests ?? 0
                let totalTokens = input + output + audioInput + audioOutput
                accumulator.requests += requests
                accumulator.inputTokens += input + audioInput
                accumulator.cachedInputTokens += cached
                accumulator.outputTokens += output + audioOutput
                accumulator.totalTokens += totalTokens
                let modelName = Self.displayName(result.model, fallback: "Responses and Chat Completions")
                accumulator.models[modelName, default: ModelAccumulator()].add(
                    requests: requests,
                    inputTokens: input + audioInput,
                    cachedInputTokens: cached,
                    outputTokens: output + audioOutput,
                    totalTokens: totalTokens)
            }
            accumulators[bucket.startTime] = accumulator
        }

        let daily = accumulators.values
            .filter { $0.startDate <= now }
            .sorted { $0.startTime < $1.startTime }
            .map { $0.makeBucket(calendar: calendar) }
        return OpenAIAPIUsageSnapshot(daily: daily, updatedAt: now)
    }

    private static func displayName(_ raw: String?, fallback: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }

    private static func url(baseURL: URL, range: DateRange, queryItems extraItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(range.startTime)),
            URLQueryItem(name: "end_time", value: String(range.endTime)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(Self.maxDailyBuckets)),
        ] + extraItems
        return components.url!
    }

    private static func dailyRange(now: Date, calendar: Calendar) -> DateRange {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(Self.maxDailyBuckets - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DateRange(startTime: Int(start.timeIntervalSince1970), endTime: Int(end.timeIntervalSince1970))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private struct DateRange {
    let startTime: Int
    let endTime: Int
}

private struct DailyAccumulator {
    let startTime: Int
    let endTime: Int
    var costUSD: Double = 0
    var requests: Int = 0
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var lineItems: [String: Double] = [:]
    var models: [String: ModelAccumulator] = [:]

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(self.startTime))
    }

    func makeBucket(calendar: Calendar) -> OpenAIAPIUsageSnapshot.DailyBucket {
        OpenAIAPIUsageSnapshot.DailyBucket(
            day: Self.dayKey(from: self.startDate, calendar: calendar),
            startTime: self.startDate,
            endTime: Date(timeIntervalSince1970: TimeInterval(self.endTime)),
            costUSD: self.costUSD,
            requests: self.requests,
            inputTokens: self.inputTokens,
            cachedInputTokens: self.cachedInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens,
            lineItems: self.lineItems
                .map { OpenAIAPIUsageSnapshot.LineItemBreakdown(name: $0.key, costUSD: $0.value) }
                .sorted {
                    if $0.costUSD == $1.costUSD { return $0.name < $1.name }
                    return $0.costUSD > $1.costUSD
                },
            models: self.models
                .map { $0.value.makeModel(name: $0.key) }
                .sorted {
                    if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
                    return $0.totalTokens > $1.totalTokens
                })
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

private struct ModelAccumulator {
    var requests = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0

    mutating func add(
        requests: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int)
    {
        self.requests += requests
        self.inputTokens += inputTokens
        self.cachedInputTokens += cachedInputTokens
        self.outputTokens += outputTokens
        self.totalTokens += totalTokens
    }

    func makeModel(name: String) -> OpenAIAPIUsageSnapshot.ModelBreakdown {
        OpenAIAPIUsageSnapshot.ModelBreakdown(
            name: name,
            requests: self.requests,
            inputTokens: self.inputTokens,
            cachedInputTokens: self.cachedInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens)
    }
}

private struct CostsResponse: Decodable {
    let data: [CostBucket]
}

private struct CostBucket: Decodable {
    let startTime: Int
    let endTime: Int
    let results: [CostResult]

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct CostResult: Decodable {
    struct Amount: Decodable {
        let value: Double?
        let currency: String?
    }

    let amount: Amount?
    let lineItem: String?

    private enum CodingKeys: String, CodingKey {
        case amount
        case lineItem = "line_item"
    }
}

private struct CompletionsUsageResponse: Decodable {
    let data: [CompletionsUsageBucket]
}

private struct CompletionsUsageBucket: Decodable {
    let startTime: Int
    let endTime: Int
    let results: [CompletionsUsageResult]

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct CompletionsUsageResult: Decodable {
    let inputTokens: Int?
    let inputCachedTokens: Int?
    let inputAudioTokens: Int?
    let outputTokens: Int?
    let outputAudioTokens: Int?
    let numModelRequests: Int?
    let model: String?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputTokens = "output_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case model
    }
}

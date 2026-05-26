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

    private static let maxDailyBucketLimit = 31
    private static let timeoutSeconds: TimeInterval = 20

    private struct EndpointRequestContext {
        let apiKey: String
        let projectID: String?
        let transport: any ProviderHTTPTransport
        let retryPolicy: ProviderHTTPRetryPolicy
    }

    private struct UsageEndpoint<Bucket> {
        let name: String
        let baseURL: URL
        let queryItems: [URLQueryItem]
        let decodeBuckets: (Data) throws -> [Bucket]
    }

    private typealias SnapshotMetadata = (now: Date, calendar: Calendar, historyDays: Int, projectID: String?)

    public static func fetchUsage(
        apiKey: String,
        projectID: String? = nil,
        costsURL: URL = Self.organizationCostsURL,
        completionsURL: URL = Self.organizationCompletionsUsageURL,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date(),
        historyDays: Int = 30,
        retryPolicy: ProviderHTTPRetryPolicy = .transientIdempotent) async throws -> OpenAIAPIUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIAPIUsageError.missingCredentials
        }
        let normalizedProjectID = OpenAIAPISettingsReader.cleaned(projectID)

        let calendar = Self.utcCalendar
        let clampedHistoryDays = max(1, min(365, historyDays))
        let ranges = Self.dailyRanges(now: now, calendar: calendar, historyDays: clampedHistoryDays)
        let requestContext = EndpointRequestContext(
            apiKey: trimmed,
            projectID: normalizedProjectID,
            transport: transport,
            retryPolicy: retryPolicy)
        let costs = try await Self.fetchBuckets(
            endpoint: Self.costsEndpoint(baseURL: costsURL),
            context: requestContext,
            ranges: ranges)
        let completions = try await Self.fetchBuckets(
            endpoint: Self.completionsEndpoint(baseURL: completionsURL),
            context: requestContext,
            ranges: ranges)

        return Self.makeSnapshot(
            costs: costs,
            completions: completions,
            metadata: SnapshotMetadata(
                now: now,
                calendar: calendar,
                historyDays: clampedHistoryDays,
                projectID: normalizedProjectID))
    }

    static func _parseSnapshotForTesting(
        costs: Data,
        completions: Data,
        now: Date,
        calendar: Calendar = Self.utcCalendar,
        historyDays: Int = 30,
        projectID: String? = nil) throws -> OpenAIAPIUsageSnapshot
    {
        try self.makeSnapshot(
            costs: self.decodeCosts(costs).data,
            completions: self.decodeCompletions(completions).data,
            metadata: SnapshotMetadata(
                now: now,
                calendar: calendar,
                historyDays: historyDays,
                projectID: OpenAIAPISettingsReader.cleaned(projectID)))
    }

    private static func costsEndpoint(baseURL: URL) -> UsageEndpoint<OpenAICostBucket> {
        UsageEndpoint(
            name: "costs",
            baseURL: baseURL,
            queryItems: [URLQueryItem(name: "group_by", value: "line_item")],
            decodeBuckets: { try self.decodeCosts($0).data })
    }

    private static func completionsEndpoint(
        baseURL: URL) -> UsageEndpoint<OpenAICompletionsUsageBucket>
    {
        UsageEndpoint(
            name: "completions",
            baseURL: baseURL,
            queryItems: [URLQueryItem(name: "group_by", value: "model")],
            decodeBuckets: { try self.decodeCompletions($0).data })
    }

    private static func fetchBuckets<Bucket>(
        endpoint: UsageEndpoint<Bucket>,
        context: EndpointRequestContext,
        ranges: [DateRange]) async throws -> [Bucket]
    {
        var buckets: [Bucket] = []
        for range in ranges {
            let url = Self.url(
                baseURL: endpoint.baseURL,
                range: range,
                queryItems: endpoint.queryItems + Self.projectQueryItems(projectID: context.projectID))
            let data = try await Self.fetchData(
                url: url,
                apiKey: context.apiKey,
                endpoint: endpoint.name,
                transport: context.transport,
                retryPolicy: context.retryPolicy)
            try buckets.append(contentsOf: endpoint.decodeBuckets(data))
        }
        return buckets
    }

    private static func projectQueryItems(projectID: String?) -> [URLQueryItem] {
        guard let projectID else { return [] }
        return [URLQueryItem(name: "project_ids", value: projectID)]
    }

    private static func fetchData(
        url: URL,
        apiKey: String,
        endpoint: String,
        transport: any ProviderHTTPTransport,
        retryPolicy: ProviderHTTPRetryPolicy) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request, retryPolicy: retryPolicy)
        } catch {
            throw OpenAIAPIUsageError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw OpenAIAPIUsageError.apiError(endpoint: endpoint, statusCode: response.statusCode)
        }
        return response.data
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
        costs: [OpenAICostBucket],
        completions: [OpenAICompletionsUsageBucket],
        metadata: SnapshotMetadata) -> OpenAIAPIUsageSnapshot
    {
        var accumulators: [Int: DailyAccumulator] = [:]

        for bucket in costs {
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

        for bucket in completions {
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
            .filter { $0.startDate <= metadata.now }
            .sorted { $0.startTime < $1.startTime }
            .map { $0.makeBucket(calendar: metadata.calendar) }
        return OpenAIAPIUsageSnapshot(
            daily: daily,
            updatedAt: metadata.now,
            historyDays: metadata.historyDays,
            projectID: metadata.projectID)
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
            URLQueryItem(name: "limit", value: String(range.limit)),
        ] + extraItems
        return components.url!
    }

    private static func dailyRanges(now: Date, calendar: Calendar, historyDays: Int) -> [DateRange] {
        let today = calendar.startOfDay(for: now)
        let clampedHistoryDays = max(1, min(365, historyDays))
        var cursor = calendar.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: today) ?? today
        var remainingDays = clampedHistoryDays
        var ranges: [DateRange] = []
        ranges.reserveCapacity(Int(ceil(Double(clampedHistoryDays) / Double(Self.maxDailyBucketLimit))))

        while remainingDays > 0 {
            let chunkDays = min(Self.maxDailyBucketLimit, remainingDays)
            let end = calendar.date(byAdding: .day, value: chunkDays, to: cursor) ?? cursor
            ranges.append(DateRange(
                startTime: Int(cursor.timeIntervalSince1970),
                endTime: Int(end.timeIntervalSince1970),
                limit: chunkDays))
            cursor = end
            remainingDays -= chunkDays
        }
        return ranges
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
    let limit: Int
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

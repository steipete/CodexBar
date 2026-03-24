import Foundation

public struct OpenAIAPIUsageSnapshotResult: Sendable, Equatable {
    public let snapshot: CostUsageTokenSnapshot
    public let errorMessage: String?

    public init(snapshot: CostUsageTokenSnapshot, errorMessage: String?) {
        self.snapshot = snapshot
        self.errorMessage = errorMessage
    }
}

/// Fetches Codex API-key usage from the OpenAI REST API.
///
/// Strategy:
/// - Prefer the current organization endpoints for 30-day cost + token history.
/// - Fallback to the legacy `/v1/usage` endpoint for today's token counts when org usage
///   permissions are unavailable.
/// - Return partial data plus a user-facing error when spend is blocked by key scopes.
public enum OpenAIAPIUsageFetcher {
    private struct UTCWindow: Sendable {
        let startInclusive: Date
        let endExclusive: Date
    }

    private struct PartialResult<Value: Sendable>: Sendable {
        let value: Value
        let error: OpenAIAPIError?
    }

    private struct OrganizationPage<Result: Decodable & Sendable>: Decodable {
        let data: [Bucket<Result>]
        let hasMore: Bool?
        let nextPage: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case nextPage = "next_page"
        }
    }

    private struct Bucket<Result: Decodable & Sendable>: Decodable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }

    private struct OrganizationCostResult: Decodable, Sendable {
        struct Amount: Decodable, Sendable {
            let value: Double?
            let currency: String?
        }

        let amount: Amount?
        let lineItem: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case lineItem = "line_item"
        }
    }

    private struct OrganizationCompletionsResult: Decodable, Sendable {
        let inputTokens: Int?
        let outputTokens: Int?
        let inputCachedTokens: Int?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case inputCachedTokens = "input_cached_tokens"
            case model
        }
    }

    private struct LegacyTokenUsageResponse: Decodable, Sendable {
        let data: [LegacyTokenEntry]
    }

    private struct LegacyTokenEntry: Decodable, Sendable {
        let nContextTokensTotal: Int
        let nGeneratedTokensTotal: Int

        enum CodingKeys: String, CodingKey {
            case nContextTokensTotal = "n_context_tokens_total"
            case nGeneratedTokensTotal = "n_generated_tokens_total"
        }
    }

    private struct DailyAccumulator: Sendable {
        struct ModelAccumulator: Sendable {
            var totalTokens: Int = 0
        }

        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var hasTokenData = false
        var costUSD: Double = 0
        var hasCostData = false
        var modelsUsed: Set<String> = []
        var modelBreakdowns: [String: ModelAccumulator] = [:]

        mutating func addCost(_ cost: Double?) {
            guard let cost else { return }
            self.costUSD += cost
            self.hasCostData = true
        }

        mutating func addTokens(
            input: Int,
            output: Int,
            cacheRead: Int = 0,
            model: String? = nil)
        {
            guard input > 0 || output > 0 || cacheRead > 0 else { return }
            self.inputTokens += input
            self.outputTokens += output
            self.cacheReadTokens += cacheRead
            self.hasTokenData = true

            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedModel.isEmpty else { return }
            self.modelsUsed.insert(trimmedModel)
            var breakdown = self.modelBreakdowns[trimmedModel] ?? ModelAccumulator()
            breakdown.totalTokens += input + output
            self.modelBreakdowns[trimmedModel] = breakdown
        }

        func entry(for date: String) -> CostUsageDailyReport.Entry? {
            guard self.hasTokenData || self.hasCostData else { return nil }
            let modelNames = self.modelsUsed.sorted()
            let breakdowns = self.modelBreakdowns
                .keys
                .sorted()
                .compactMap { name -> CostUsageDailyReport.ModelBreakdown? in
                    guard let breakdown = self.modelBreakdowns[name] else { return nil }
                    return CostUsageDailyReport.ModelBreakdown(
                        modelName: name,
                        costUSD: nil,
                        totalTokens: breakdown.totalTokens > 0 ? breakdown.totalTokens : nil)
                }
            let totalTokens = self.hasTokenData ? self.inputTokens + self.outputTokens : nil
            return CostUsageDailyReport.Entry(
                date: date,
                inputTokens: self.hasTokenData ? self.inputTokens : nil,
                outputTokens: self.hasTokenData ? self.outputTokens : nil,
                cacheReadTokens: self.cacheReadTokens > 0 ? self.cacheReadTokens : nil,
                totalTokens: totalTokens,
                costUSD: self.hasCostData ? self.costUSD : nil,
                modelsUsed: modelNames.isEmpty ? nil : modelNames,
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns)
        }
    }

    // MARK: - Public entry point

    public static func loadSnapshot(
        apiKey: String,
        now: Date = Date(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        })
        async -> OpenAIAPIUsageSnapshotResult
    {
        let window = self.utcWindow(containing: now)

        async let costsFetch = self.fetchOrganizationCostsSafe(
            apiKey: apiKey,
            start: window.startInclusive,
            endExclusive: window.endExclusive,
            dataLoader: dataLoader)
        async let orgUsageFetch = self.fetchOrganizationUsageSafe(
            apiKey: apiKey,
            start: window.startInclusive,
            endExclusive: window.endExclusive,
            dataLoader: dataLoader)
        async let legacyUsageFetch = self.fetchLegacyTodayUsageSafe(
            apiKey: apiKey,
            date: now,
            dataLoader: dataLoader)

        let (costs, orgUsage, legacyUsage) = await (costsFetch, orgUsageFetch, legacyUsageFetch)

        let daily = self.buildDailyReport(
            costs: costs.value,
            organizationUsage: orgUsage.value,
            legacyTodayUsage: legacyUsage.value,
            now: now)
        let snapshot = CostUsageFetcher.tokenSnapshot(from: daily, now: now)
        let errorMessage = self.errorMessage(
            costError: costs.error,
            organizationUsageError: orgUsage.error,
            hasData: !snapshot.daily.isEmpty)

        return OpenAIAPIUsageSnapshotResult(
            snapshot: snapshot,
            errorMessage: errorMessage)
    }

    // MARK: - Current org usage endpoints

    private static func fetchOrganizationCostsSafe(
        apiKey: String,
        start: Date,
        endExclusive: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async -> PartialResult<[Bucket<OrganizationCostResult>]>
    {
        do {
            return try await PartialResult(
                value: self.fetchOrganizationCosts(
                    apiKey: apiKey,
                    start: start,
                    endExclusive: endExclusive,
                    dataLoader: dataLoader),
                error: nil)
        } catch let error as OpenAIAPIError {
            return PartialResult(value: [], error: error)
        } catch {
            return PartialResult(
                value: [],
                error: OpenAIAPIError(statusCode: -1, body: error.localizedDescription))
        }
    }

    private static func fetchOrganizationCosts(
        apiKey: String,
        start: Date,
        endExclusive: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async throws -> [Bucket<OrganizationCostResult>]
    {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endExclusive.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        let data = try await self.apiRequest(url: components.url!, apiKey: apiKey, dataLoader: dataLoader)
        return try JSONDecoder().decode(OrganizationPage<OrganizationCostResult>.self, from: data).data
    }

    private static func fetchOrganizationUsageSafe(
        apiKey: String,
        start: Date,
        endExclusive: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async -> PartialResult<[Bucket<OrganizationCompletionsResult>]>
    {
        do {
            return try await PartialResult(
                value: self.fetchOrganizationUsage(
                    apiKey: apiKey,
                    start: start,
                    endExclusive: endExclusive,
                    dataLoader: dataLoader),
                error: nil)
        } catch let error as OpenAIAPIError {
            return PartialResult(value: [], error: error)
        } catch {
            return PartialResult(
                value: [],
                error: OpenAIAPIError(statusCode: -1, body: error.localizedDescription))
        }
    }

    private static func fetchOrganizationUsage(
        apiKey: String,
        start: Date,
        endExclusive: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async throws -> [Bucket<OrganizationCompletionsResult>]
    {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endExclusive.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        let data = try await self.apiRequest(url: components.url!, apiKey: apiKey, dataLoader: dataLoader)
        return try JSONDecoder().decode(OrganizationPage<OrganizationCompletionsResult>.self, from: data).data
    }

    // MARK: - Legacy today-token fallback

    private static func fetchLegacyTodayUsageSafe(
        apiKey: String,
        date: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async -> PartialResult<[LegacyTokenEntry]>
    {
        do {
            return try await PartialResult(
                value: self.fetchLegacyTodayUsage(apiKey: apiKey, date: date, dataLoader: dataLoader),
                error: nil)
        } catch let error as OpenAIAPIError {
            return PartialResult(value: [], error: error)
        } catch {
            return PartialResult(
                value: [],
                error: OpenAIAPIError(statusCode: -1, body: error.localizedDescription))
        }
    }

    private static func fetchLegacyTodayUsage(
        apiKey: String,
        date: Date,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async throws -> [LegacyTokenEntry]
    {
        var components = URLComponents(string: "https://api.openai.com/v1/usage")!
        components.queryItems = [URLQueryItem(name: "date", value: self.dayKey(from: date))]
        let data = try await self.apiRequest(url: components.url!, apiKey: apiKey, dataLoader: dataLoader)
        return try JSONDecoder().decode(LegacyTokenUsageResponse.self, from: data).data
    }

    // MARK: - Merge helpers

    private static func buildDailyReport(
        costs: [Bucket<OrganizationCostResult>],
        organizationUsage: [Bucket<OrganizationCompletionsResult>],
        legacyTodayUsage: [LegacyTokenEntry],
        now: Date) -> CostUsageDailyReport
    {
        var dailyMap: [String: DailyAccumulator] = [:]

        for bucket in costs {
            let day = self.dayKey(from: Date(timeIntervalSince1970: bucket.startTime))
            var accumulator = dailyMap[day] ?? DailyAccumulator()
            for result in bucket.results {
                accumulator.addCost(result.amount?.value)
            }
            dailyMap[day] = accumulator
        }

        for bucket in organizationUsage {
            let day = self.dayKey(from: Date(timeIntervalSince1970: bucket.startTime))
            var accumulator = dailyMap[day] ?? DailyAccumulator()
            for result in bucket.results {
                accumulator.addTokens(
                    input: result.inputTokens ?? 0,
                    output: result.outputTokens ?? 0,
                    cacheRead: result.inputCachedTokens ?? 0,
                    model: result.model)
            }
            dailyMap[day] = accumulator
        }

        let today = self.dayKey(from: now)
        let legacyInput = legacyTodayUsage.reduce(0) { $0 + $1.nContextTokensTotal }
        let legacyOutput = legacyTodayUsage.reduce(0) { $0 + $1.nGeneratedTokensTotal }
        if legacyInput > 0 || legacyOutput > 0 {
            var accumulator = dailyMap[today] ?? DailyAccumulator()
            if !accumulator.hasTokenData {
                accumulator.addTokens(input: legacyInput, output: legacyOutput)
                dailyMap[today] = accumulator
            }
        }

        let entries = dailyMap.keys.sorted().compactMap { day in
            dailyMap[day]?.entry(for: day)
        }

        let inputValues = entries.compactMap(\.inputTokens)
        let outputValues = entries.compactMap(\.outputTokens)
        let cacheValues = entries.compactMap(\.cacheReadTokens)
        let tokenValues = entries.compactMap(\.totalTokens)
        let costValues = entries.compactMap(\.costUSD)

        let finalSummary: CostUsageDailyReport.Summary? =
            entries.isEmpty
                ? nil
                : CostUsageDailyReport.Summary(
                    totalInputTokens: inputValues.isEmpty ? nil : inputValues.reduce(0, +),
                    totalOutputTokens: outputValues.isEmpty ? nil : outputValues.reduce(0, +),
                    cacheReadTokens: cacheValues.isEmpty ? nil : cacheValues.reduce(0, +),
                    totalTokens: tokenValues.isEmpty ? nil : tokenValues.reduce(0, +),
                    totalCostUSD: costValues.isEmpty ? nil : costValues.reduce(0, +))

        return CostUsageDailyReport(data: entries, summary: finalSummary)
    }

    private static func errorMessage(
        costError: OpenAIAPIError?,
        organizationUsageError: OpenAIAPIError?,
        hasData: Bool) -> String?
    {
        if let costError {
            if let missingScopes = self.missingScopes(from: costError), !missingScopes.isEmpty {
                let scopesText = missingScopes.map { "`\($0)`" }.joined(separator: ", ")
                let grantText = missingScopes.count == 1 ? "Grant that scope" : "Grant those scopes"
                if hasData {
                    return "OpenAI blocked spend data for this key: missing \(scopesText). " +
                        "Token usage is shown, but cost is unavailable. " +
                        "\(grantText) or use an organization/admin key with usage access."
                }
                return "OpenAI blocked spend data for this key: missing \(scopesText). " +
                    "\(grantText) or use an organization/admin key with usage access."
            }
            let reason = self.permissionHint(for: costError)
            if hasData {
                return "OpenAI blocked spend data for this key. \(reason)"
            }
            return "OpenAI blocked spend data for this key. \(reason)"
        }

        if let organizationUsageError, !hasData {
            return "This API key cannot read OpenAI usage history. \(self.permissionHint(for: organizationUsageError))"
        }

        return nil
    }

    private static func permissionHint(for error: OpenAIAPIError) -> String {
        let message = (error.apiMessage ?? error.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()

        if lower.contains("api.usage.read") {
            return "Grant the `api.usage.read` scope or use an organization/admin key with usage access."
        }
        if lower.contains("insufficient permissions") {
            return "OpenAI says this key does not have permission to read organization usage/cost data."
        }
        if lower.contains("session key") {
            return "OpenAI only allows that billing endpoint from a signed-in browser session."
        }
        if error.statusCode == 401 {
            return "OpenAI rejected the API key."
        }
        if !message.isEmpty {
            return message
        }
        return "OpenAI returned HTTP \(error.statusCode)."
    }

    private static func missingScopes(from error: OpenAIAPIError) -> [String]? {
        let message = (error.apiMessage ?? error.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        let pattern = "(?i)missing scopes:\\s*(.+?)(?:\\.\\s*check|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: nsRange),
              let range = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        let scopes = message[range]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return scopes.isEmpty ? nil : scopes
    }

    // MARK: - Helpers

    private static func apiRequest(
        url: URL,
        apiKey: String,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        async throws -> Data
    {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIAPIError(statusCode: code, body: body)
        }
        return data
    }

    private static func utcWindow(containing now: Date) -> UTCWindow {
        let start = self.utcStartOfDay(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: -29, to: now) ?? now)
        let end = self.utcStartOfDay(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now)
        return UTCWindow(startInclusive: start, endExclusive: end)
    }

    private static func utcStartOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }

    private static func dayKey(from date: Date) -> String {
        let utcDay = self.utcStartOfDay(date)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: utcDay)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}

public struct OpenAIAPIError: LocalizedError, Sendable {
    public let statusCode: Int
    public let body: String

    public var apiMessage: String? {
        guard let data = self.body.data(using: .utf8), !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["error"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return message
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return message
            }
        }
        return nil
    }

    public var errorDescription: String? {
        self.apiMessage ?? "OpenAI API error \(self.statusCode)"
    }
}

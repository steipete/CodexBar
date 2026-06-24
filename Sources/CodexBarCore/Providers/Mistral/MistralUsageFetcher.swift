import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MistralUsageFetcher {
    private static let baseURL = URL(string: "https://admin.mistral.ai")!

    public struct MistralVibeUsageResult: Equatable, Sendable {
        public let usagePercentage: Double
        public let resetAt: Date?
    }

    public static func fetchUsage(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 15) async throws -> MistralUsageSnapshot
    {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        let usagePath = self.baseURL.appendingPathComponent("/api/billing/v2/usage")
        var components = URLComponents(url: usagePath, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "year", value: "\(year)"),
        ]
        guard let url = components.url else {
            throw MistralUsageError.apiError("Failed to construct URL")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN")
        }

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw MistralUsageError.invalidCredentials
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MistralUsageError.apiError("HTTP \(response.statusCode): \(body)")
        }

        return try Self.parseResponse(data: data, updatedAt: now)
    }

    public static func fetchVibeUsage(
        csrfToken: String,
        cookieHeader: String? = nil,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralVibeUsageResult
    {
        let urlString = "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D"
        guard let url = URL(string: urlString) else {
            throw MistralUsageError.apiError("Failed to construct URL")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        let validatedCSRFToken = try Self.validatedVibeCSRFToken(csrfToken)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // Forward ory_session_* and csrftoken cookies — scoped to what console.mistral.ai needs.
        let consoleCookie = Self.consoleCookieHeader(
            csrfToken: validatedCSRFToken,
            adminCookieHeader: cookieHeader)
        request.setValue(consoleCookie, forHTTPHeaderField: "Cookie")
        request.setValue(validatedCSRFToken, forHTTPHeaderField: "X-CSRFToken")

        let response = try await transport.response(for: request)
        let data = response.data

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw MistralUsageError.invalidCredentials
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MistralUsageError.apiError("HTTP \(response.statusCode): \(body)")
        }

        return try Self.parseVibeUsage(data: data)
    }

    static func parseVibeUsage(data: Data) throws -> MistralVibeUsageResult {
        let responses: [VibeUsageResponse]
        do {
            responses = try JSONDecoder().decode([VibeUsageResponse].self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        guard let json = responses.first?.result.data.json else {
            throw MistralUsageError.parseFailed("Empty response array")
        }
        guard json.usagePercentage.isFinite, (0...100).contains(json.usagePercentage) else {
            throw MistralUsageError.parseFailed("Invalid usage percentage")
        }
        return MistralVibeUsageResult(
            usagePercentage: json.usagePercentage,
            resetAt: json.resetAt.flatMap(Self.parseISO8601Date))
    }

    static func vibeCookieHeader(csrfToken: String) throws -> String {
        try "csrftoken=\(self.validatedVibeCSRFToken(csrfToken))"
    }

    /// Builds a minimal Cookie header for console.mistral.ai.
    /// Only csrftoken + ory_session_* pass through; all other admin.mistral.ai cookies stay origin-bound.
    static func consoleCookieHeader(csrfToken: String, adminCookieHeader: String?) -> String {
        var pairs = ["csrftoken=\(csrfToken)"]
        if let adminCookies = adminCookieHeader {
            let sessionPairs = CookieHeaderNormalizer.pairs(from: adminCookies)
                .filter { $0.name.hasPrefix("ory_session_") }
                .map { "\($0.name)=\($0.value)" }
            pairs.append(contentsOf: sessionPairs)
        }
        return pairs.joined(separator: "; ")
    }

    private static func validatedVibeCSRFToken(_ csrfToken: String) throws -> String {
        let token = csrfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: ";,\r\n")
        guard !token.isEmpty, token.rangeOfCharacter(from: forbidden) == nil else {
            throw MistralUsageError.invalidCredentials
        }
        return token
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func parseResponse(data: Data, updatedAt: Date) throws -> MistralUsageSnapshot {
        let decoder = JSONDecoder()
        let billing: MistralBillingResponse
        do {
            billing = try decoder.decode(MistralBillingResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }

        let prices = Self.buildPriceIndex(billing.prices ?? [])
        var totalCost: Double = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0
        var modelCount = 0
        var daily: [String: DailyAccumulator] = [:]

        // Aggregate completion tokens
        if let models = billing.completion?.models {
            for (modelName, modelData) in models {
                modelCount += 1
                let (input, output, cached, cost) = Self.aggregateModel(modelData, prices: prices)
                totalInput += input
                totalOutput += output
                totalCached += cached
                totalCost += cost
                Self.addDailyEntries(
                    modelName: modelName,
                    data: modelData,
                    prices: prices,
                    daily: &daily,
                    countsTokens: true)
            }
        }

        // Aggregate OCR, connectors, audio if present
        for category in [billing.ocr, billing.connectors, billing.audio] {
            if let models = category?.models {
                for (modelName, modelData) in models {
                    let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                    totalCost += cost
                    Self.addDailyEntries(
                        modelName: modelName,
                        data: modelData,
                        prices: prices,
                        daily: &daily,
                        countsTokens: false)
                }
            }
        }

        // Aggregate libraries_api (pages + tokens)
        if let models = billing.librariesApi?.pages?.models {
            for (modelName, modelData) in models {
                let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                totalCost += cost
                Self.addDailyEntries(
                    modelName: modelName,
                    data: modelData,
                    prices: prices,
                    daily: &daily,
                    countsTokens: false)
            }
        }
        if let models = billing.librariesApi?.tokens?.models {
            for (modelName, modelData) in models {
                let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                totalCost += cost
                Self.addDailyEntries(
                    modelName: modelName,
                    data: modelData,
                    prices: prices,
                    daily: &daily,
                    countsTokens: true)
            }
        }

        // Aggregate fine_tuning (training + storage)
        for models in [billing.fineTuning?.training, billing.fineTuning?.storage] {
            if let models {
                for (modelName, modelData) in models {
                    let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                    totalCost += cost
                    Self.addDailyEntries(
                        modelName: modelName,
                        data: modelData,
                        prices: prices,
                        daily: &daily,
                        countsTokens: false)
                }
            }
        }

        let currency = billing.currency ?? "EUR"
        let currencySymbol = billing.currencySymbol ?? "€"

        let startDate = billing.startDate.flatMap { Self.parseDate($0) }
        let endDate = billing.endDate.flatMap { Self.parseDate($0) }

        return MistralUsageSnapshot(
            totalCost: totalCost,
            currency: currency,
            currencySymbol: currencySymbol,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCachedTokens: totalCached,
            modelCount: modelCount,
            daily: daily.values.map { $0.makeBucket() },
            startDate: startDate,
            endDate: endDate,
            updatedAt: updatedAt)
    }

    // MARK: - Private Helpers

    private static func buildPriceIndex(_ prices: [MistralPrice]) -> [String: Double] {
        var index: [String: Double] = [:]
        for price in prices {
            guard let metric = price.billingMetric,
                  let group = price.billingGroup,
                  let priceStr = price.price,
                  let value = Double(priceStr)
            else { continue }
            let key = "\(metric)::\(group)"
            index[key] = value
        }
        return index
    }

    private static func aggregateModel(
        _ data: MistralModelUsageData,
        prices: [String: Double]) -> (input: Int, output: Int, cached: Int, cost: Double)
    {
        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0
        var totalCost: Double = 0

        for entry in data.input ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalInput += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        for entry in data.output ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalOutput += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        for entry in data.cached ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalCached += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        return (totalInput, totalOutput, totalCached, totalCost)
    }

    private static func addDailyEntries(
        modelName: String,
        data: MistralModelUsageData,
        prices: [String: Double],
        daily: inout [String: DailyAccumulator],
        countsTokens: Bool)
    {
        self.addDaily(
            entries: data.input ?? [],
            context: DailyEntryContext(
                kind: .input,
                modelName: modelName,
                prices: prices,
                countsTokens: countsTokens),
            daily: &daily)
        self.addDaily(
            entries: data.output ?? [],
            context: DailyEntryContext(
                kind: .output,
                modelName: modelName,
                prices: prices,
                countsTokens: countsTokens),
            daily: &daily)
        self.addDaily(
            entries: data.cached ?? [],
            context: DailyEntryContext(
                kind: .cached,
                modelName: modelName,
                prices: prices,
                countsTokens: countsTokens),
            daily: &daily)
    }

    fileprivate enum TokenKind {
        case input
        case cached
        case output
    }

    private static func addDaily(
        entries: [MistralUsageEntry],
        context: DailyEntryContext,
        daily: inout [String: DailyAccumulator])
    {
        for entry in entries {
            guard let day = dayKey(from: entry.timestamp) else { continue }
            let units = entry.valuePaid ?? entry.value ?? 0
            let cost = Self.cost(for: entry, units: units, prices: context.prices)
            var accumulator = daily[day] ?? DailyAccumulator(day: day)
            accumulator.add(
                modelName: Self.displayModelName(context.modelName, entry: entry),
                kind: context.kind,
                units: units,
                cost: cost,
                countsTokens: context.countsTokens)
            daily[day] = accumulator
        }
    }

    private static func cost(for entry: MistralUsageEntry, units: Int, prices: [String: Double]) -> Double {
        guard let metric = entry.billingMetric, let group = entry.billingGroup else { return 0 }
        return Double(units) * (prices["\(metric)::\(group)"] ?? 0)
    }

    private static func displayModelName(_ raw: String, entry: MistralUsageEntry) -> String {
        if let display = entry.billingDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !display.isEmpty
        {
            return display
        }
        return raw.split(separator: "::").first.map(String.init) ?? raw
    }

    private static func dayKey(from timestamp: String?) -> String? {
        guard let trimmed = timestamp?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count >= 10 {
            return String(trimmed.prefix(10))
        }
        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private struct DailyEntryContext {
    let kind: MistralUsageFetcher.TokenKind
    let modelName: String
    let prices: [String: Double]
    let countsTokens: Bool
}

private struct DailyAccumulator {
    let day: String
    var cost: Double = 0
    var inputTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var models: [String: ModelAccumulator] = [:]

    mutating func add(
        modelName: String,
        kind: MistralUsageFetcher.TokenKind,
        units: Int,
        cost: Double,
        countsTokens: Bool)
    {
        self.cost += cost
        var model = self.models[modelName] ?? ModelAccumulator(name: modelName)
        model.cost += cost
        guard countsTokens else {
            self.models[modelName] = model
            return
        }
        switch kind {
        case .input:
            self.inputTokens += units
            model.inputTokens += units
        case .cached:
            self.cachedTokens += units
            model.cachedTokens += units
        case .output:
            self.outputTokens += units
            model.outputTokens += units
        }
        self.models[modelName] = model
    }

    func makeBucket() -> MistralDailyUsageBucket {
        MistralDailyUsageBucket(
            day: self.day,
            cost: self.cost,
            inputTokens: self.inputTokens,
            cachedTokens: self.cachedTokens,
            outputTokens: self.outputTokens,
            models: self.models.values
                .map { $0.makeBreakdown() }
                .sorted {
                    if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
                    return $0.totalTokens > $1.totalTokens
                })
    }
}

private struct ModelAccumulator {
    let name: String
    var cost: Double = 0
    var inputTokens = 0
    var cachedTokens = 0
    var outputTokens = 0

    func makeBreakdown() -> MistralDailyUsageBucket.ModelBreakdown {
        MistralDailyUsageBucket.ModelBreakdown(
            name: self.name,
            cost: self.cost,
            inputTokens: self.inputTokens,
            cachedTokens: self.cachedTokens,
            outputTokens: self.outputTokens)
    }
}

private struct VibeUsageResponse: Decodable {
    let result: VibeResult
    struct VibeResult: Decodable {
        let data: VibeData
        struct VibeData: Decodable {
            let json: VibeJson
            struct VibeJson: Decodable {
                let usagePercentage: Double
                let resetAt: String?
                enum CodingKeys: String, CodingKey {
                    case usagePercentage = "usage_percentage"
                    case resetAt = "reset_at"
                }
            }
        }
    }
}

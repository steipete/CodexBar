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
        timeout: TimeInterval = 15,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralUsageSnapshot
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

        let response = try await transport.response(for: request)
        let data = response.data

        try Self.validate(statusCode: response.statusCode, data: data)

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

        try Self.validate(statusCode: response.statusCode, data: data)

        return try Self.parseVibeUsage(data: data)
    }

    static func fetchSubscriptionBudgets(
        cookieHeader: String,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralSubscriptionBudgets
    {
        let url = self.baseURL.appendingPathComponent("subscription")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")

        let response = try await transport.response(for: request)
        try Self.validate(statusCode: response.statusCode, data: response.data)
        guard response.response.url?.scheme?.lowercased() == "https",
              response.response.url?.host?.lowercased() == self.baseURL.host,
              let html = String(data: response.data, encoding: .utf8),
              !html.isEmpty
        else {
            throw MistralUsageError.parseFailed("Invalid subscription page response")
        }
        do {
            return try MistralSubscriptionBudgetParser.parse(html: html)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
    }

    /// Subscription allowances from the JSON endpoint backing the Admin subscription page.
    /// Mirrors the `budget` record embedded in that page, without scraping Next.js flight data.
    static func fetchBudget(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralSubscriptionBudgets
    {
        let data = try await self.fetchAdminJSON(
            path: "/api/billing/v2/budget",
            referer: "https://admin.mistral.ai/subscription",
            session: AdminSession(cookieHeader: cookieHeader, csrfToken: csrfToken),
            timeout: timeout,
            transport: transport)
        do {
            return try MistralSubscriptionBudgetParser.parse(jsonData: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
    }

    public static func fetchAccount(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralAccountSnapshot
    {
        let data = try await self.fetchAdminJSON(
            path: "/api/users/me",
            referer: "https://admin.mistral.ai/organization/usage",
            session: AdminSession(cookieHeader: cookieHeader, csrfToken: csrfToken),
            timeout: timeout,
            transport: transport)
        return try Self.parseAccount(data: data)
    }

    public static func fetchCredits(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralCreditsSnapshot
    {
        let data = try await self.fetchAdminJSON(
            path: "/api/billing/credits",
            referer: "https://admin.mistral.ai/organization/billing",
            session: AdminSession(cookieHeader: cookieHeader, csrfToken: csrfToken),
            timeout: timeout,
            transport: transport)
        return try Self.parseCredits(data: data)
    }

    private struct AdminSession {
        let cookieHeader: String
        let csrfToken: String?
    }

    private static func fetchAdminJSON(
        path: String,
        referer: String,
        session: AdminSession,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport) async throws -> Data
    {
        let url = self.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken = session.csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN")
        }

        let response = try await transport.response(for: request)
        try Self.validate(statusCode: response.statusCode, data: response.data)
        return response.data
    }

    /// Mistral Admin answers a missing or expired `ory_session_*` cookie with a redirect to
    /// `auth.mistral.ai` instead of a 401; the shared client refuses cross-host redirects, so the raw
    /// 302 surfaces here. Treat it as invalid credentials so the next browser session gets a chance.
    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    static func validate(statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200:
            return
        case 401, 403:
            throw MistralUsageError.invalidCredentials
        case let code where Self.redirectStatusCodes.contains(code):
            throw MistralUsageError.invalidCredentials
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MistralUsageError.apiError("HTTP \(statusCode): \(body)")
        }
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
            resetAt: ISO8601DateParser.parse(json.resetAt))
    }

    static func parseCredits(data: Data) throws -> MistralCreditsSnapshot {
        let response: MistralCreditsResponse
        do {
            response = try JSONDecoder().decode(MistralCreditsResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }

        let snapshot = MistralCreditsSnapshot(
            walletAmount: response.walletAmount,
            creditNotesAmount: response.creditNotesAmount ?? 0,
            ongoingUsageBalance: response.ongoingUsageBalance ?? 0,
            currency: response.currency)
        let amounts = [snapshot.walletAmount, snapshot.creditNotesAmount, snapshot.ongoingUsageBalance]
        let available = snapshot.walletAmount + snapshot.creditNotesAmount - snapshot.ongoingUsageBalance
        guard amounts.allSatisfy(\.isFinite), available.isFinite else {
            throw MistralUsageError.parseFailed("Invalid credit amount")
        }
        return snapshot
    }

    static func parseAccount(data: Data) throws -> MistralAccountSnapshot {
        let response: MistralUserResponse
        do {
            response = try JSONDecoder().decode(MistralUserResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        func cleaned(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return MistralAccountSnapshot(
            email: cleaned(response.email),
            organizationName: cleaned(response.organization?.name),
            chatPlan: cleaned(response.organization?.activeChatPlan),
            apiPlan: cleaned(response.organization?.activeApiPlan),
            codePlan: cleaned(response.organization?.activeCodePlan),
            hasVibePro: response.organization?.hasVibePro ?? false)
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
        var totalTokens = TokenCounts()
        var modelCount = 0
        var daily: [String: DailyAccumulator] = [:]

        // Token-metered categories: API completions, Le Chat, and Vibe Code completions.
        // Vibe Code entries are consumed against the Vibe plan; their tokens count, their billed cost is
        // whatever exceeds the plan (`value_paid`).
        let tokenCategories: [MistralModelUsageCategory?] = [
            billing.completion,
            billing.chat,
            billing.vibeCode?.completion,
        ]
        for category in tokenCategories {
            for (modelName, modelData) in category?.models ?? [:] {
                modelCount += 1
                let aggregate = try Self.aggregateModel(modelData, prices: prices, countsTokens: true)
                try totalTokens.add(aggregate.tokens)
                Self.accumulateFiniteCost(aggregate.cost, into: &totalCost)
                try Self.addDailyEntries(
                    modelName: modelName,
                    data: modelData,
                    prices: prices,
                    daily: &daily,
                    countsTokens: true)
            }
        }

        // Cost-only categories (pages, seconds, characters, connector calls, library indexing, fine-tuning).
        let costOnlyModels: [[String: MistralModelUsageData]?] = [
            billing.ocr?.models,
            billing.connectors?.models,
            billing.audio?.models,
            billing.audioCharacters?.models,
            billing.vibeCode?.ocr?.models,
            billing.vibeCode?.connectors?.models,
            billing.vibeCode?.audio?.models,
            billing.vibeCode?.audioCharacters?.models,
            billing.librariesApi?.pages?.models,
            billing.librariesApi?.tokens?.models,
            billing.librariesApi?.audioSeconds?.models,
            billing.fineTuning?.training,
            billing.fineTuning?.storage,
        ]
        for models in costOnlyModels {
            for (modelName, modelData) in models ?? [:] {
                let (_, cost) = try Self.aggregateModel(modelData, prices: prices, countsTokens: false)
                Self.accumulateFiniteCost(cost, into: &totalCost)
                try Self.addDailyEntries(
                    modelName: modelName,
                    data: modelData,
                    prices: prices,
                    daily: &daily,
                    countsTokens: false)
            }
        }

        let rawCurrency = billing.currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currency = rawCurrency.isEmpty ? "XXX" : rawCurrency.uppercased()
        let rawCurrencySymbol = billing.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultCurrencySymbol = switch currency {
        case "EUR": "€"
        case "XXX": "¤"
        default: currency
        }
        let currencySymbol = rawCurrencySymbol.isEmpty ? defaultCurrencySymbol : rawCurrencySymbol

        let startDate = ISO8601DateParser.parse(billing.startDate)
        let endDate = ISO8601DateParser.parse(billing.endDate)
        _ = try totalTokens.total()

        return try MistralUsageSnapshot(
            totalCost: totalCost,
            currency: currency,
            currencySymbol: currencySymbol,
            totalInputTokens: totalTokens.input,
            totalOutputTokens: totalTokens.output,
            totalCachedTokens: totalTokens.cached,
            modelCount: modelCount,
            daily: daily.values.map { try $0.makeBucket() },
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
                  let value = Double(priceStr),
                  value.isFinite
            else { continue }
            let key = "\(metric)::\(group)"
            index[key] = value
        }
        return index
    }

    private static func aggregateModel(
        _ data: MistralModelUsageData,
        prices: [String: Double],
        countsTokens: Bool) throws -> (tokens: TokenCounts, cost: Double)
    {
        var tokens = TokenCounts()
        var totalCost: Double = 0
        let lanes: [(TokenKind, [MistralUsageEntry]?)] = [
            (.input, data.input), (.output, data.output), (.cached, data.cached),
        ]
        for (kind, entries) in lanes {
            for entry in entries ?? [] {
                if countsTokens { try tokens.add(Self.consumedUnits(entry), kind: kind) }
                Self.accumulateFiniteCost(
                    Self.cost(for: entry, units: Self.billedUnits(entry), prices: prices),
                    into: &totalCost)
            }
        }
        return (tokens, totalCost)
    }

    private static func addDailyEntries(
        modelName: String,
        data: MistralModelUsageData,
        prices: [String: Double],
        daily: inout [String: DailyAccumulator],
        countsTokens: Bool) throws
    {
        try self.addDaily(
            entries: data.input ?? [],
            context: DailyEntryContext(
                kind: .input,
                modelName: modelName,
                prices: prices,
                countsTokens: countsTokens),
            daily: &daily)
        try self.addDaily(
            entries: data.output ?? [],
            context: DailyEntryContext(
                kind: .output,
                modelName: modelName,
                prices: prices,
                countsTokens: countsTokens),
            daily: &daily)
        try self.addDaily(
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
        daily: inout [String: DailyAccumulator]) throws
    {
        for entry in entries {
            guard let day = dayKey(from: entry.timestamp) else { continue }
            let cost = Self.cost(for: entry, units: Self.billedUnits(entry), prices: context.prices)
            var accumulator = daily[day] ?? DailyAccumulator(day: day)
            try accumulator.add(
                modelName: Self.displayModelName(context.modelName, entry: entry),
                kind: context.kind,
                units: Self.consumedUnits(entry),
                cost: cost,
                countsTokens: context.countsTokens)
            daily[day] = accumulator
        }
    }

    /// Units actually consumed (tokens, pages, seconds), including usage covered by an included allowance.
    private static func consumedUnits(_ entry: MistralUsageEntry) -> Int {
        entry.value ?? entry.valuePaid ?? 0
    }

    /// Units billed pay-as-you-go. Usage covered by the included API allowance or the Vibe plan reports
    /// `value_paid == 0`; pay-as-you-go accounts report `value_paid == value`.
    private static func billedUnits(_ entry: MistralUsageEntry) -> Int {
        entry.valuePaid ?? entry.value ?? 0
    }

    private static func cost(for entry: MistralUsageEntry, units: Int, prices: [String: Double]) -> Double {
        guard let metric = entry.billingMetric, let group = entry.billingGroup else { return 0 }
        let cost = Double(units) * (prices["\(metric)::\(group)"] ?? 0)
        return cost.isFinite ? cost : 0
    }

    fileprivate static func accumulateFiniteCost(_ cost: Double, into total: inout Double) {
        guard cost.isFinite else { return }
        let updatedTotal = total + cost
        guard updatedTotal.isFinite else { return }
        total = updatedTotal
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
}

private struct DailyEntryContext {
    let kind: MistralUsageFetcher.TokenKind
    let modelName: String
    let prices: [String: Double]
    let countsTokens: Bool
}

private struct TokenCounts {
    var input = 0
    var cached = 0
    var output = 0

    mutating func add(_ units: Int, kind: MistralUsageFetcher.TokenKind) throws {
        let lane: WritableKeyPath<Self, Int> = switch kind {
        case .input: \.input
        case .cached: \.cached
        case .output: \.output
        }
        let addition = self[keyPath: lane].addingReportingOverflow(units)
        guard !addition.overflow else { throw MistralUsageError.parseFailed("Token count exceeds supported range") }
        self[keyPath: lane] = addition.partialValue
    }

    mutating func add(_ other: Self) throws {
        try self.add(other.input, kind: .input)
        try self.add(other.output, kind: .output)
        try self.add(other.cached, kind: .cached)
    }

    func total() throws -> Int {
        guard let total = MistralTokenMath.total(input: self.input, cached: self.cached, output: self.output) else {
            throw MistralUsageError.parseFailed("Token count exceeds supported range")
        }
        return total
    }
}

private struct DailyAccumulator {
    let day: String
    var cost: Double = 0
    var tokens = TokenCounts()
    var models: [String: ModelAccumulator] = [:]

    mutating func add(
        modelName: String,
        kind: MistralUsageFetcher.TokenKind,
        units: Int,
        cost: Double,
        countsTokens: Bool) throws
    {
        MistralUsageFetcher.accumulateFiniteCost(cost, into: &self.cost)
        var model = self.models[modelName] ?? ModelAccumulator(name: modelName)
        MistralUsageFetcher.accumulateFiniteCost(cost, into: &model.cost)
        if countsTokens {
            try self.tokens.add(units, kind: kind)
            try model.tokens.add(units, kind: kind)
        }
        self.models[modelName] = model
    }

    func makeBucket() throws -> MistralDailyUsageBucket {
        _ = try self.tokens.total()
        let models = try self.models.values.map { model in
            try (breakdown: model.makeBreakdown(), total: model.tokens.total())
        }.sorted {
            if $0.total == $1.total { return $0.breakdown.name < $1.breakdown.name }
            return $0.total > $1.total
        }
        return MistralDailyUsageBucket(
            day: self.day,
            cost: self.cost,
            inputTokens: self.tokens.input,
            cachedTokens: self.tokens.cached,
            outputTokens: self.tokens.output,
            models: models.map(\.breakdown))
    }
}

private struct ModelAccumulator {
    let name: String
    var cost: Double = 0
    var tokens = TokenCounts()

    func makeBreakdown() -> MistralDailyUsageBucket.ModelBreakdown {
        MistralDailyUsageBucket.ModelBreakdown(
            name: self.name,
            cost: self.cost,
            inputTokens: self.tokens.input,
            cachedTokens: self.tokens.cached,
            outputTokens: self.tokens.output)
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

private struct MistralCreditsResponse: Decodable {
    let walletAmount: Double
    let creditNotesAmount: Double?
    let ongoingUsageBalance: Double?
    let currency: String

    enum CodingKeys: String, CodingKey {
        case currency
        case walletAmount = "wallet_amount"
        case creditNotesAmount = "credit_notes_amount"
        case ongoingUsageBalance = "ongoing_usage_balance"
    }
}

private struct MistralUserResponse: Decodable {
    let email: String?
    let organization: Organization?

    struct Organization: Decodable {
        let name: String?
        let activeChatPlan: String?
        let activeApiPlan: String?
        let activeCodePlan: String?
        let hasVibePro: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case activeChatPlan = "active_chat_plan"
            case activeApiPlan = "active_api_plan"
            case activeCodePlan = "active_code_plan"
            case hasVibePro = "has_vibe_pro"
        }
    }
}

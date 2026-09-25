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

    private static let log = CodexBarLog.logger(LogCategories.provider(.mistral, scope: "usage"))

    /// Current-month usage. The legacy billing endpoint stays first so tenants where it answers keep billed-spend
    /// accounting; when it fails for anything but a session problem, usage is read through the tRPC procedures
    /// behind the Admin usage page (Mistral moved the page there in September 2026 and the legacy endpoint started
    /// answering HTTP 500). Session failures (401/403 or a redirect to the login page) surface immediately so the
    /// next browser session is tried.
    public static func fetchUsage(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 15,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralUsageSnapshot
    {
        let now = Date()
        let legacyError: Error
        do {
            return try await Self.fetchLegacyUsage(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                now: now,
                timeout: timeout,
                transport: transport)
        } catch let error as MistralUsageError {
            if case .invalidCredentials = error { throw error }
            legacyError = error
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            legacyError = error
        }
        Self.log.info(
            "Legacy billing usage failed; reading usage through Admin tRPC procedures",
            metadata: ["error": "\(legacyError.localizedDescription.prefix(200))"])
        return try await MistralUsageTRPCFetcher.fetchUsage(
            session: MistralUsageTRPCFetcher.Session(cookieHeader: cookieHeader, csrfToken: csrfToken),
            now: now,
            timeout: timeout,
            transport: transport)
    }

    /// `GET /api/billing/v2/usage?month&year`: the pre-September-2026 usage source.
    static func fetchLegacyUsage(
        cookieHeader: String,
        csrfToken: String?,
        now: Date = Date(),
        timeout: TimeInterval = 15,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralUsageSnapshot
    {
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

    /// Mistral Admin answers a missing or expired `ory_session_*` cookie with a redirect to `auth.mistral.ai`
    /// rather than a 401; the shared client refuses cross-host redirects, so the raw 3xx surfaces here.
    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    static func isSessionFailure(statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403 || self.redirectStatusCodes.contains(statusCode)
    }

    static func validate(statusCode: Int, data: Data) throws {
        if statusCode == 200 { return }
        if self.isSessionFailure(statusCode: statusCode) { throw MistralUsageError.invalidCredentials }
        let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
        throw MistralUsageError.apiError("HTTP \(statusCode): \(body)")
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

    public static func fetchCredits(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 4,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MistralCreditsSnapshot
    {
        let url = self.baseURL.appendingPathComponent("/api/billing/credits")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/billing", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN")
        }

        let response = try await transport.response(for: request)
        let data = response.data

        try Self.validate(statusCode: response.statusCode, data: data)

        return try Self.parseCredits(data: data)
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

        let prices = MistralPriceIndex(legacyPrices: billing.prices ?? [])
        var entries: [MistralUsageAggregator.Entry] = []

        // API, Le Chat, and Vibe completions share consumed-token and billed-cost accounting.
        for category in [billing.completion, billing.chat, billing.vibeCode?.completion] {
            for (modelName, modelData) in category?.models ?? [:] {
                Self.appendEntries(modelName: modelName, data: modelData, prices: prices, scope: .all, into: &entries)
            }
        }
        for category in [billing.ocr, billing.connectors, billing.audio] {
            for (modelName, modelData) in category?.models ?? [:] {
                Self.appendEntries(modelName: modelName, data: modelData, prices: prices, scope: .none, into: &entries)
            }
        }
        for (modelName, modelData) in billing.librariesApi?.pages?.models ?? [:] {
            Self.appendEntries(modelName: modelName, data: modelData, prices: prices, scope: .none, into: &entries)
        }
        for (modelName, modelData) in billing.librariesApi?.tokens?.models ?? [:] {
            Self.appendEntries(modelName: modelName, data: modelData, prices: prices, scope: .dailyOnly, into: &entries)
        }
        for models in [billing.fineTuning?.training, billing.fineTuning?.storage] {
            for (modelName, modelData) in models ?? [:] {
                Self.appendEntries(modelName: modelName, data: modelData, prices: prices, scope: .none, into: &entries)
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

        return try MistralUsageAggregator.snapshot(entries: entries, period: MistralUsageAggregator.Period(
            costBasis: .billed,
            currency: currency,
            currencySymbol: currencySymbol,
            startDate: ISO8601DateParser.parse(billing.startDate),
            endDate: ISO8601DateParser.parse(billing.endDate),
            updatedAt: updatedAt))
    }

    // MARK: - Private Helpers

    /// Legacy entries: tokens are consumed units (`value`), cost is billed units (`value_paid`) times price.
    private static func appendEntries(
        modelName: String,
        data: MistralModelUsageData,
        prices: MistralPriceIndex,
        scope: MistralUsageAggregator.TokenScope,
        into entries: inout [MistralUsageAggregator.Entry])
    {
        let lanes: [(MistralUsageAggregator.Lane, [MistralUsageEntry]?)] = [
            (.input, data.input), (.output, data.output), (.cached, data.cached),
        ]
        for (lane, laneEntries) in lanes {
            for entry in laneEntries ?? [] {
                let billedUnits = entry.valuePaid ?? entry.value ?? 0
                entries.append(MistralUsageAggregator.Entry(
                    day: MistralUsageAggregator.dayKey(from: entry.timestamp),
                    modelName: Self.displayModelName(modelName, entry: entry),
                    modelKey: modelName,
                    lane: lane,
                    units: entry.value ?? entry.valuePaid ?? 0,
                    cost: Self.cost(for: entry, units: billedUnits, prices: prices),
                    tokenScope: scope))
            }
        }
    }

    private static func cost(for entry: MistralUsageEntry, units: Int, prices: MistralPriceIndex) -> Double {
        guard let metric = entry.billingMetric, let group = entry.billingGroup else { return 0 }
        let lookup = MistralPriceIndex.Lookup(
            billingMetric: metric,
            billingGroup: group,
            eventType: entry.eventType,
            apiZone: nil,
            serviceTier: nil)
        let cost = Double(units) * (prices.price(for: lookup) ?? 0)
        return cost.isFinite ? cost : 0
    }

    private static func displayModelName(_ raw: String, entry: MistralUsageEntry) -> String {
        if let display = entry.billingDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !display.isEmpty
        {
            return display
        }
        return raw.split(separator: "::").first.map(String.init) ?? raw
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

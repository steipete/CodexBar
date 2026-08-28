import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import SweetCookieKit
#endif

public struct CopilotBudgetWebFetcher: Sendable {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case noSessionCookie
        case notLoggedIn
        case accountMismatch(expected: String, actual: String?)
        case badStatus(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .noSessionCookie:
                "No GitHub browser session cookie found."
            case .notLoggedIn:
                "GitHub browser session is not logged in."
            case let .accountMismatch(expected, actual):
                "GitHub browser session belongs to \(actual ?? "an unknown account"), expected \(expected)."
            case let .badStatus(status):
                "GitHub budgets request failed with HTTP \(status)."
            case .invalidResponse:
                "GitHub budgets response could not be decoded."
            }
        }
    }

    struct BudgetResponse: Decodable {
        let budgets: [Budget]
        let hasNextPage: Bool?

        private enum CodingKeys: String, CodingKey {
            case budgets
            case payload
            case hasNextPage
            case hasNextPageSnake = "has_next_page"
        }

        init(budgets: [Budget], hasNextPage: Bool? = nil) {
            self.budgets = budgets
            self.hasNextPage = hasNextPage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let payload = try container.decodeIfPresent(BudgetResponse.self, forKey: .payload) {
                self = payload
                return
            }
            self.budgets = try container.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
            self.hasNextPage = try container.decodeIfPresent(Bool.self, forKey: .hasNextPage)
                ?? container.decodeIfPresent(Bool.self, forKey: .hasNextPageSnake)
        }
    }

    struct Budget: Decodable, Equatable {
        let id: String?
        let name: String?
        let budgetType: String?
        let budgetProductSkus: [String]
        let budgetScope: String?
        let budgetEntityName: String?
        let budgetAmount: Double
        let currentAmount: Double

        init(
            id: String? = nil,
            name: String? = nil,
            budgetType: String? = nil,
            budgetProductSkus: [String] = [],
            budgetScope: String? = nil,
            budgetEntityName: String? = nil,
            budgetAmount: Double,
            currentAmount: Double = 0)
        {
            self.id = id
            self.name = name
            self.budgetType = budgetType
            self.budgetProductSkus = budgetProductSkus
            self.budgetScope = budgetScope
            self.budgetEntityName = budgetEntityName
            self.budgetAmount = budgetAmount
            self.currentAmount = currentAmount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.id = Self.decodeString(container: container, keys: ["id", "uuid", "budget_id", "budgetId"])
            self.name = Self.decodeString(container: container, keys: ["name", "display_name", "displayName", "title"])
            self.budgetType = Self.decodeString(
                container: container,
                keys: ["budget_type", "budgetType", "type", "pricing_target_type", "pricingTargetType"])
            self.budgetProductSkus = Self.decodeStringArray(
                container: container,
                keys: [
                    "budget_product_skus",
                    "budgetProductSkus",
                    "budget_product_sku",
                    "budgetProductSku",
                    "product_skus",
                    "productSkus",
                    "skus",
                    "sku",
                    "product",
                    "product_name",
                    "productName",
                    "pricing_target_id",
                    "pricingTargetId",
                ])
            self.budgetScope = Self.decodeString(container: container, keys: ["budget_scope", "budgetScope", "scope"])
            self.budgetEntityName = Self.decodeString(
                container: container,
                keys: [
                    "budget_entity_name",
                    "budgetEntityName",
                    "entity_name",
                    "entityName",
                    "target_name",
                    "targetName",
                ])
            self.budgetAmount = Self.decodeDouble(
                container: container,
                keys: [
                    "budget_amount",
                    "budgetAmount",
                    "target_amount",
                    "targetAmount",
                    "spending_limit",
                    "spendingLimit",
                    "limit",
                    "amount",
                    "max",
                ]) ?? 0
            self.currentAmount = Self.decodeDouble(
                container: container,
                keys: [
                    "current_usage",
                    "currentUsage",
                    "current_amount",
                    "currentAmount",
                    "usage_amount",
                    "usageAmount",
                    "usage",
                    "spent",
                    "amount_used",
                    "amountUsed",
                ]) ?? 0
        }

        var normalizedSelectors: Set<String> {
            let values = self.budgetProductSkus + [
                self.budgetType,
                self.budgetEntityName,
                self.name,
            ].compactMap(\.self)
            return Set(values.compactMap(CopilotBudgetWebFetcher.normalizedBillingIdentifier))
        }

        private static func decodeString(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> String?
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                    return value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return String(value)
                }
            }
            return nil
        }

        private static func decodeStringArray(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> [String]
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let values = try? container.decodeIfPresent([String].self, forKey: codingKey), !values.isEmpty {
                    return values
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                    return [value]
                }
                if let values = try? container.decodeIfPresent([ProductSKU].self, forKey: codingKey),
                   !values.isEmpty
                {
                    return values.flatMap(\.selectors)
                }
            }
            return []
        }

        private static func decodeDouble(
            container: KeyedDecodingContainer<DynamicCodingKey>,
            keys: [String]) -> Double?
        {
            for key in keys {
                guard let codingKey = DynamicCodingKey(key) else { continue }
                if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                    return value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return Double(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
                   let parsed = Self.parseAmount(value)
                {
                    return parsed
                }
                if let value = try? container.decodeIfPresent(AmountValue.self, forKey: codingKey) {
                    return value.amount
                }
            }
            return nil
        }

        fileprivate static func parseAmount(_ value: String) -> Double? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNegative = trimmed.first == "-"
            guard !trimmed.dropFirst(isNegative ? 1 : 0).contains("-") else { return nil }
            let unsigned = trimmed.filter { $0.isNumber || $0 == "." }
            guard !unsigned.isEmpty else { return nil }
            return Double(isNegative ? "-\(unsigned)" : unsigned)
        }
    }

    struct GitHubWebIdentity: Equatable {
        let id: String?
        let login: String?

        init(id: String?, login: String?) {
            let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.id = trimmedID.isEmpty ? nil : trimmedID
            self.login = trimmedLogin.isEmpty ? nil : trimmedLogin
        }

        var displayName: String? {
            self.login ?? self.id.map { "github:user:\($0)" }
        }
    }

    private struct ProductSKU: Decodable, Equatable {
        let selectors: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.selectors = [
                "sku",
                "name",
                "display_name",
                "displayName",
                "product",
                "product_name",
                "productName",
            ].compactMap { key in
                guard let codingKey = DynamicCodingKey(key) else { return nil }
                return try? container.decodeIfPresent(String.self, forKey: codingKey)
            }
        }
    }

    private struct AmountValue: Decodable {
        let amount: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.amount = [
                "amount",
                "value",
                "total",
                "cents",
                "formatted",
            ].lazy.compactMap { key -> Double? in
                guard let codingKey = DynamicCodingKey(key) else { return nil }
                if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                    return key == "cents" ? value / 100 : value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return key == "cents" ? Double(value) / 100 : Double(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                    return Budget.parseAmount(value)
                }
                return nil
            }.first
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private static let copilotProductID = "copilot"
    private static let copilotPremiumRequestSKU = "copilot_premium_request"
    private static let copilotAgentPremiumRequestSKU = "copilot_agent_premium_request"
    private static let sparkPremiumRequestSKU = "spark_premium_request"
    private static let copilotBudgetSelectors: Set<String> = [
        copilotProductID,
        copilotPremiumRequestSKU,
        copilotAgentPremiumRequestSKU,
        sparkPremiumRequestSKU,
    ]

    private let cookieHeaderOverride: String?
    private let expectedGitHubAccountIdentifier: String?
    private let browserDetection: BrowserDetection
    private let transport: any ProviderHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        cookieHeaderOverride: String? = nil,
        expectedGitHubAccountIdentifier: String? = nil,
        browserDetection: BrowserDetection = BrowserDetection(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.cookieHeaderOverride = CookieHeaderNormalizer.normalize(cookieHeaderOverride ?? "")
        self.expectedGitHubAccountIdentifier = Self.normalizedExpectedAccountIdentifier(
            expectedGitHubAccountIdentifier)
        self.browserDetection = browserDetection
        self.transport = transport
        self.now = now
    }

    public func fetchBudgetWindows() async throws -> [NamedRateWindow] {
        if let cookieHeaderOverride, !cookieHeaderOverride.isEmpty {
            return try await self.fetchBudgetWindows(cookieHeader: cookieHeaderOverride)
        }

        if let cached = CookieHeaderCache.load(provider: .copilot),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                return try await self.fetchBudgetWindows(cookieHeader: cached.cookieHeader)
            } catch {
                if case Error.notLoggedIn = error {
                    CookieHeaderCache.clear(provider: .copilot)
                } else if case Error.accountMismatch = error {
                    CookieHeaderCache.clear(provider: .copilot)
                } else {
                    throw error
                }
            }
        }

        #if os(macOS)
        for session in CopilotGitHubCookieImporter.importSessions(browserDetection: self.browserDetection) {
            do {
                let windows = try await self.fetchBudgetWindows(cookieHeader: session.cookieHeader)
                CookieHeaderCache.store(
                    provider: .copilot,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return windows
            } catch {
                if case Error.notLoggedIn = error {
                    continue
                }
                if case Error.accountMismatch = error {
                    continue
                }
                throw error
            }
        }
        #endif

        throw Error.noSessionCookie
    }

    func fetchBudgetWindows(cookieHeader: String) async throws -> [NamedRateWindow] {
        let nonce = try await self.boundFetchNonce(cookieHeader: cookieHeader)
        var allBudgets: [Budget] = []
        var page = 1
        let maxPages = 20
        var shouldContinue = true
        while shouldContinue, page <= maxPages {
            let response = try await self.fetchBudgetPage(
                cookieHeader: cookieHeader,
                nonce: nonce,
                page: page)
            allBudgets.append(contentsOf: response.budgets)
            shouldContinue = response.hasNextPage == true
            page += 1
        }
        if shouldContinue {
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot budget pagination reached page cap",
                metadata: ["pageCap": "\(maxPages)"])
        }
        return Self.extraRateWindows(from: allBudgets, now: self.now())
    }

    private func boundFetchNonce(cookieHeader: String) async throws -> String? {
        guard self.expectedGitHubAccountIdentifier != nil else {
            return await self.bestEffortFetchNonce(cookieHeader: cookieHeader)
        }
        let metadata = try await self.fetchBudgetPageMetadata(cookieHeader: cookieHeader)
        try self.verifyExpectedGitHubAccount(metadata.identity)
        return metadata.nonce
    }

    private func bestEffortFetchNonce(cookieHeader: String) async -> String? {
        do {
            return try await self.fetchBudgetPageMetadata(cookieHeader: cookieHeader).nonce
        } catch {
            // GitHub accepts some budget requests without a nonce. Keep auth failures and
            // page-shape changes non-fatal so a valid Cookie header can still be tried.
            return nil
        }
    }

    private struct BudgetPageMetadata {
        let nonce: String?
        let identity: GitHubWebIdentity?
    }

    private func fetchBudgetPageMetadata(cookieHeader: String) async throws -> BudgetPageMetadata {
        guard let url = URL(string: "https://github.com/settings/billing/budgets") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response = try await self.transport.response(for: request)
        switch response.statusCode {
        case 200:
            guard let html = String(data: response.data, encoding: .utf8) else { throw Error.invalidResponse }
            return BudgetPageMetadata(
                nonce: Self.extractFetchNonce(from: html),
                identity: Self.extractGitHubWebIdentity(from: html))
        case 401, 403:
            throw Error.notLoggedIn
        default:
            throw Error.badStatus(response.statusCode)
        }
    }

    private func verifyExpectedGitHubAccount(_ actual: GitHubWebIdentity?) throws {
        guard let expected = self.expectedGitHubAccountIdentifier else { return }
        guard let actual else { throw Error.accountMismatch(expected: expected, actual: nil) }
        guard Self.webIdentity(actual, matches: expected) else {
            throw Error.accountMismatch(expected: expected, actual: actual.displayName)
        }
    }

    private func fetchBudgetPage(cookieHeader: String, nonce: String?, page: Int) async throws -> BudgetResponse {
        guard var components = URLComponents(string: "https://github.com/settings/billing/budgets") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "page_size", value: "10"),
            URLQueryItem(name: "scope", value: "customer"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://github.com/settings/billing/budgets", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("true", forHTTPHeaderField: "GitHub-Verified-Fetch")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        if let nonce, !nonce.isEmpty {
            request.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce")
        }

        let response = try await self.transport.response(for: request)
        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(BudgetResponse.self, from: response.data)
            } catch {
                throw Error.invalidResponse
            }
        case 401, 403:
            throw Error.notLoggedIn
        default:
            throw Error.badStatus(response.statusCode)
        }
    }

    static func extractFetchNonce(from html: String) -> String? {
        let patterns = [
            #"x-fetch-nonce"\s+content="([^"]+)""#,
            #"X-Fetch-Nonce"\s*:\s*"([^"]+)""#,
            #"fetchNonce"\s*:\s*"([^"]+)""#,
            #"data-fetch-nonce="([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let nonceRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[nonceRange])
        }
        return nil
    }

    static func extractGitHubWebIdentity(from html: String) -> GitHubWebIdentity? {
        let id = self.extractMetaContent(
            named: [
                "octolytics-actor-id",
                "analytics-user-id",
                "user-id",
            ],
            from: html)
        let login = self.extractMetaContent(
            named: [
                "user-login",
                "octolytics-actor-login",
                "analytics-user-login",
            ],
            from: html)
        let identity = GitHubWebIdentity(id: id, login: login)
        return identity.id == nil && identity.login == nil ? nil : identity
    }

    private static let metaTagRegex = try? NSRegularExpression(
        pattern: #"<meta\b[^>]*>"#,
        options: [.caseInsensitive])

    private static let metaAttributeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(['"])(.*?)\2"#,
        options: [.caseInsensitive])

    private static func extractMetaContent(named names: [String], from html: String) -> String? {
        guard let metaTagRegex, let metaAttributeRegex else { return nil }
        let expectedNames = Set(names.map { $0.lowercased() })
        var contentByName: [String: String] = [:]
        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for tagMatch in metaTagRegex.matches(in: html, range: htmlRange) {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let tagNSRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            var attributes: [String: String] = [:]
            for attributeMatch in metaAttributeRegex.matches(in: tag, range: tagNSRange) {
                guard let keyRange = Range(attributeMatch.range(at: 1), in: tag),
                      let valueRange = Range(attributeMatch.range(at: 3), in: tag)
                else { continue }
                attributes[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
            }
            guard let name = attributes["name"]?.lowercased(),
                  expectedNames.contains(name),
                  contentByName[name] == nil,
                  let content = attributes["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty
            else { continue }
            contentByName[name] = content
        }
        for name in names {
            if let content = contentByName[name.lowercased()] {
                return content
            }
        }
        return nil
    }

    static func webIdentity(_ identity: GitHubWebIdentity?, matches expectedIdentifier: String?) -> Bool {
        guard let expected = self.normalizedExpectedAccountIdentifier(expectedIdentifier),
              let identity
        else { return false }
        if let expectedID = self.githubUserID(from: expected) {
            return identity.id == expectedID
        }
        return identity.login?.lowercased() == expected
    }

    static func normalizedGitHubAccountIdentifier(for identity: CopilotUsageFetcher.GitHubUserIdentity) -> String {
        "github:user:\(identity.id)"
    }

    private static func normalizedExpectedAccountIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func githubUserID(from identifier: String) -> String? {
        let prefix = "github:user:"
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    static func extraRateWindows(from budgets: [Budget], now: Date) -> [NamedRateWindow] {
        var usedIDs = Set<String>()
        let resetDate = self.approximateNextMonthResetDate(now: now)
        return budgets
            .compactMap { budget in
                let selectors = budget.normalizedSelectors
                guard self.isCopilotBudget(budget, selectors: selectors) else { return nil }
                let id = self.uniqueWindowID(for: budget, selectors: selectors, usedIDs: &usedIDs)
                let usedPercent = budget.budgetAmount > 0
                    ? min(999, max(0, budget.currentAmount / budget.budgetAmount * 100))
                    : 0
                let window = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: resetDate.map {
                        UsageFormatter.resetDescription(from: $0, now: now)
                    })
                return NamedRateWindow(
                    id: id,
                    title: self.windowTitle(for: budget, selectors: selectors),
                    window: window)
            }
    }

    private static func isCopilotBudget(_ budget: Budget, selectors: Set<String>) -> Bool {
        guard budget.budgetAmount > 0 else { return false }
        return !selectors.isDisjoint(with: self.copilotBudgetSelectors)
    }

    static func normalizedBillingIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let slug = self.slug(value)
        guard !slug.isEmpty else { return nil }
        let underscored = slug.replacingOccurrences(of: "-", with: "_")
        if underscored == self.copilotProductID {
            return self.copilotProductID
        }
        if underscored == "premium_request" || underscored == "premium_requests" {
            return self.copilotPremiumRequestSKU
        }
        if underscored == "coding_agent_premium_request" || underscored == "coding_agent_premium_requests" {
            return self.copilotAgentPremiumRequestSKU
        }
        if underscored.contains("spark"), underscored.contains("premium"), underscored.contains("request") {
            return self.sparkPremiumRequestSKU
        }
        if underscored.contains("cloud") || underscored.contains("coding"),
           underscored.contains("agent"),
           underscored.contains("premium"),
           underscored.contains("request")
        {
            return self.copilotAgentPremiumRequestSKU
        }
        if underscored.contains("bundled"), underscored.contains("premium"), underscored.contains("request") {
            return self.copilotPremiumRequestSKU
        }
        if underscored.contains("copilot"),
           underscored.contains("agent"),
           underscored.contains("premium"),
           underscored.contains("request")
        {
            return self.copilotAgentPremiumRequestSKU
        }
        if underscored.contains("copilot"), underscored.contains("premium"), underscored.contains("request") {
            return self.copilotPremiumRequestSKU
        }
        return underscored
    }

    private static func windowTitle(for budget: Budget, selectors: Set<String>) -> String {
        let budgetType = if selectors == [self.copilotProductID] {
            "Copilot"
        } else if selectors.contains(self.copilotAgentPremiumRequestSKU) {
            "Copilot Agent Premium Requests"
        } else if selectors.contains(self.sparkPremiumRequestSKU) {
            "Spark Premium Requests"
        } else if selectors.contains(self.copilotPremiumRequestSKU) {
            "All Premium Request SKUs"
        } else if let name = budget.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
        {
            name
        } else {
            "Copilot Premium Requests"
        }
        return "Budget - \(budgetType)"
    }

    private static func uniqueWindowID(
        for budget: Budget,
        selectors: Set<String>,
        usedIDs: inout Set<String>) -> String
    {
        let source = budget.id ?? budget.budgetProductSkus.joined(separator: "-")
        let slug = self.slug(source.isEmpty ? self.windowTitle(for: budget, selectors: selectors) : source)
        let base = slug.isEmpty ? "copilot-budget" : "copilot-budget-\(slug)"
        var candidate = base
        var suffix = 2
        while !usedIDs.insert(candidate).inserted {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func approximateNextMonthResetDate(now: Date) -> Date? {
        // GitHub's budget response does not expose a reset instant. Use the local
        // start of next month as a display-only approximation.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: 1))
        else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

#if os(macOS)
private enum CopilotGitHubCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.copilot]?.browserCookieOrder ?? [.chrome]
    private static let sessionCookieNames: Set<String> = [
        "user_session",
        "__Host-user_session_same_site",
        "_gh_sess",
        "logged_in",
        "dotcom_user",
    ]

    struct SessionInfo {
        let cookies: [HTTPCookie]
        let sourceLabel: String

        var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    static func importSessions(browserDetection: BrowserDetection) -> [SessionInfo] {
        let installedBrowsers = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        return installedBrowsers.flatMap { browser -> [SessionInfo] in
            do {
                return try self.importSessions(from: browser)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                return []
            }
        }
    }

    private static func importSessions(from browser: Browser) throws -> [SessionInfo] {
        let query = BrowserCookieQuery(domains: ["github.com", "www.github.com"])
        let sources = try self.cookieClient.codexBarRecords(matching: query, in: browser)
        return sources.compactMap { source -> SessionInfo? in
            guard !source.records.isEmpty else { return nil }
            let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
            guard cookies.contains(where: { self.sessionCookieNames.contains($0.name) }) else {
                return nil
            }
            return SessionInfo(cookies: cookies, sourceLabel: source.label)
        }
    }
}
#endif

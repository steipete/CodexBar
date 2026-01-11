import Foundation
import SweetCookieKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches Claude usage data directly from the claude.ai API using browser session cookies.
///
/// This approach mirrors what Claude Usage Tracker does, but automatically extracts the session key
/// from browser cookies instead of requiring manual setup.
///
/// API endpoints used:
/// - `GET https://claude.ai/api/organizations` → get org UUID
/// - `GET https://claude.ai/api/organizations/{org_id}/usage` → usage percentages + reset times
public enum ClaudeWebAPIFetcher {
    private static let baseURL = "https://claude.ai/api"
    static let maxProbeBytes = 200_000
    #if os(macOS)
    static let cookieClient = BrowserCookieClient()
    #endif

    public struct OrganizationInfo: Sendable {
        public let id: String
        public let name: String?

        public init(id: String, name: String?) {
            self.id = id
            self.name = name
        }
    }

    public struct SessionKeyInfo: Sendable {
        public let key: String
        public let sourceLabel: String
        public let cookieCount: Int

        public init(key: String, sourceLabel: String, cookieCount: Int) {
            self.key = key
            self.sourceLabel = sourceLabel
            self.cookieCount = cookieCount
        }
    }

    public enum FetchError: LocalizedError, Sendable {
        case noSessionKeyFound(report: CookieExtractionReport?)
        case invalidSessionKey
        case notSupportedOnThisPlatform
        case networkError(Error)
        case invalidResponse
        case unauthorized
        case serverError(statusCode: Int)
        case noOrganization

        public var errorDescription: String? {
            switch self {
            case let .noSessionKeyFound(report):
                let base = "No Claude session key found in browser cookies."
                if let summary = report?.compactSummary() {
                    return "\(base) \(summary)"
                }
                return base
            case .invalidSessionKey:
                return "Invalid Claude session key format."
            case .notSupportedOnThisPlatform:
                return "Claude web fetching is only supported on macOS."
            case let .networkError(error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Claude API."
            case .unauthorized:
                return "Unauthorized. Your Claude session may have expired."
            case let .serverError(code):
                return "Claude API error: HTTP \(code)"
            case .noOrganization:
                return "No Claude organization found for this account."
            }
        }
    }

    /// Claude usage data from the API
    public struct WebUsageData: Sendable {
        public let sessionPercentUsed: Double
        public let sessionResetsAt: Date?
        public let weeklyPercentUsed: Double?
        public let weeklyResetsAt: Date?
        public let sonnetPercentUsed: Double?
        public let extraUsageCost: ProviderCostSnapshot?
        public let accountOrganization: String?
        public let accountEmail: String?
        public let loginMethod: String?

        public init(
            sessionPercentUsed: Double,
            sessionResetsAt: Date?,
            weeklyPercentUsed: Double?,
            weeklyResetsAt: Date?,
            sonnetPercentUsed: Double?,
            extraUsageCost: ProviderCostSnapshot?,
            accountOrganization: String?,
            accountEmail: String?,
            loginMethod: String?)
        {
            self.sessionPercentUsed = sessionPercentUsed
            self.sessionResetsAt = sessionResetsAt
            self.weeklyPercentUsed = weeklyPercentUsed
            self.weeklyResetsAt = weeklyResetsAt
            self.sonnetPercentUsed = sonnetPercentUsed
            self.extraUsageCost = extraUsageCost
            self.accountOrganization = accountOrganization
            self.accountEmail = accountEmail
            self.loginMethod = loginMethod
        }
    }

    public struct ProbeResult: Sendable {
        public let url: String
        public let statusCode: Int?
        public let contentType: String?
        public let topLevelKeys: [String]
        public let emails: [String]
        public let planHints: [String]
        public let notableFields: [String]
        public let bodyPreview: String?
    }

    // MARK: - Public API

    #if os(macOS)

    /// Attempts to fetch Claude usage data using cookies extracted from browsers.
    /// Tries browser cookies using the standard import order.
    public static func fetchUsage(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }

        let sessionInfo = try extractSessionKeyInfo(browserDetection: browserDetection, logger: log)
        log("Found session key: \(sessionInfo.key.prefix(20))...")

        return try await self.fetchUsage(using: sessionInfo, logger: log)
    }

    public static func fetchUsage(
        cookieHeader: String,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }
        let sessionInfo = try self.sessionKeyInfo(cookieHeader: cookieHeader)
        log("Using manual session key (\(sessionInfo.cookieCount) cookies)")
        return try await self.fetchUsage(using: sessionInfo, logger: log)
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?(msg) }
        let sessionKey = sessionKeyInfo.key

        // Fetch organization info
        let organization = try await fetchOrganizationInfo(sessionKey: sessionKey, logger: log)
        log("Organization ID: \(organization.id)")
        if let name = organization.name { log("Organization name: \(name)") }

        var usage = try await fetchUsageData(orgId: organization.id, sessionKey: sessionKey, logger: log)
        if usage.extraUsageCost == nil,
           let extra = await fetchExtraUsageCost(orgId: organization.id, sessionKey: sessionKey, logger: log)
        {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                sonnetPercentUsed: usage.sonnetPercentUsed,
                extraUsageCost: extra,
                accountOrganization: usage.accountOrganization,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod)
        }
        if let account = await fetchAccountInfo(sessionKey: sessionKey, orgId: organization.id, logger: log) {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                sonnetPercentUsed: usage.sonnetPercentUsed,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: usage.accountOrganization,
                accountEmail: account.email,
                loginMethod: account.loginMethod)
        }
        if usage.accountOrganization == nil, let name = organization.name {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                sonnetPercentUsed: usage.sonnetPercentUsed,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: name,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod)
        }
        return usage
    }

    /// Checks if we can find a Claude session key in browser cookies without making API calls.
    public static func hasSessionKey(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        do {
            _ = try self.sessionKeyInfo(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }

    public static func hasSessionKey(cookieHeader: String?) -> Bool {
        guard let cookieHeader else { return false }
        return (try? self.sessionKeyInfo(cookieHeader: cookieHeader)) != nil
    }

    public static func sessionKeyInfo(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo
    {
        try self.extractSessionKeyInfo(browserDetection: browserDetection, logger: logger)
    }

    public static func sessionKeyInfo(cookieHeader: String) throws -> SessionKeyInfo {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        if let sessionKey = Self.findSessionKey(in: pairs) {
            return SessionKeyInfo(
                key: sessionKey,
                sourceLabel: "Manual",
                cookieCount: pairs.count)
        }
        throw FetchError.noSessionKeyFound(report: nil)
    }

    // MARK: - API Calls

    static func fetchOrganizationInfo(
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async throws -> OrganizationInfo
    {
        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        logger?("Organizations API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            return try self.parseOrganizationResponse(data)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func fetchUsageData(
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        logger?("Usage API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            return try self.parseUsageResponse(data)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func parseUsageResponse(_ data: Data) throws -> WebUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }

        // Parse five_hour (session) usage
        var sessionPercent: Double?
        var sessionResets: Date?
        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let utilization = fiveHour["utilization"] as? Int {
                sessionPercent = Double(utilization)
            }
            if let resetsAt = fiveHour["resets_at"] as? String {
                sessionResets = self.parseISO8601Date(resetsAt)
            }
        }
        guard let sessionPercent else {
            // If we can't parse session utilization, treat this as a failure so callers can fall back to the CLI.
            throw FetchError.invalidResponse
        }

        // Parse seven_day (weekly) usage
        var weeklyPercent: Double?
        var weeklyResets: Date?
        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let utilization = sevenDay["utilization"] as? Int {
                weeklyPercent = Double(utilization)
            }
            if let resetsAt = sevenDay["resets_at"] as? String {
                weeklyResets = self.parseISO8601Date(resetsAt)
            }
        }

        // Parse seven_day_sonnet (Sonnet-specific weekly) usage
        var sonnetPercent: Double?
        if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
            if let utilization = sevenDaySonnet["utilization"] as? Int {
                sonnetPercent = Double(utilization)
            }
        } else if let sevenDaySonnetOnly = json["seven_day_sonnet_only"] as? [String: Any] {
            if let utilization = sevenDaySonnetOnly["utilization"] as? Int {
                sonnetPercent = Double(utilization)
            }
        }

        return WebUsageData(
            sessionPercentUsed: sessionPercent,
            sessionResetsAt: sessionResets,
            weeklyPercentUsed: weeklyPercent,
            weeklyResetsAt: weeklyResets,
            sonnetPercentUsed: sonnetPercent,
            extraUsageCost: nil,
            accountOrganization: nil,
            accountEmail: nil,
            loginMethod: nil)
    }

    // MARK: - Extra usage cost (Claude "Extra")

    private struct OverageSpendLimitResponse: Decodable {
        let monthlyCreditLimit: Double?
        let currency: String?
        let usedCredits: Double?
        let isEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case monthlyCreditLimit = "monthly_credit_limit"
            case currency
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    /// Best-effort fetch of Claude Extra spend/limit (does not fail the main usage fetch).
    private static func fetchExtraUsageCost(
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async -> ProviderCostSnapshot?
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            logger?("Overage API status: \(httpResponse.statusCode)")
            guard httpResponse.statusCode == 200 else { return nil }
            return Self.parseOverageSpendLimit(data)
        } catch {
            return nil
        }
    }

    private static func parseOverageSpendLimit(_ data: Data) -> ProviderCostSnapshot? {
        guard let decoded = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data) else { return nil }
        guard decoded.isEnabled == true else { return nil }
        guard let used = decoded.usedCredits,
              let limit = decoded.monthlyCreditLimit,
              let currency = decoded.currency,
              !currency.isEmpty else { return nil }

        let usedAmount = used / 100.0
        let limitAmount = limit / 100.0

        return ProviderCostSnapshot(
            used: usedAmount,
            limit: limitAmount,
            currencyCode: currency,
            period: "Monthly",
            resetsAt: nil,
            updatedAt: Date())
    }

    #if DEBUG

    // MARK: - Test hooks (DEBUG-only)

    public static func _parseUsageResponseForTesting(_ data: Data) throws -> WebUsageData {
        try self.parseUsageResponse(data)
    }

    public static func _parseOrganizationsResponseForTesting(_ data: Data) throws -> OrganizationInfo {
        try self.parseOrganizationResponse(data)
    }

    public static func _parseOverageSpendLimitForTesting(_ data: Data) -> ProviderCostSnapshot? {
        self.parseOverageSpendLimit(data)
    }

    public static func _parseAccountInfoForTesting(_ data: Data, orgId: String?) -> WebAccountInfo? {
        self.parseAccountInfo(data, orgId: orgId)
    }

    #endif

    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct OrganizationResponse: Decodable {
        let uuid: String
        let name: String?
    }

    private static func parseOrganizationResponse(_ data: Data) throws -> OrganizationInfo {
        guard let organizations = try? JSONDecoder().decode([OrganizationResponse].self, from: data) else {
            throw FetchError.invalidResponse
        }
        guard let first = organizations.first else { throw FetchError.noOrganization }
        let name = first.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = (name?.isEmpty ?? true) ? nil : name
        return OrganizationInfo(id: first.uuid, name: sanitized)
    }

    public struct WebAccountInfo: Sendable {
        public let email: String?
        public let loginMethod: String?

        public init(email: String?, loginMethod: String?) {
            self.email = email
            self.loginMethod = loginMethod
        }
    }

    private struct AccountResponse: Decodable {
        let emailAddress: String?
        let memberships: [Membership]?

        enum CodingKeys: String, CodingKey {
            case emailAddress = "email_address"
            case memberships
        }

        struct Membership: Decodable {
            let organization: Organization

            struct Organization: Decodable {
                let uuid: String?
                let name: String?
                let rateLimitTier: String?
                let billingType: String?

                enum CodingKeys: String, CodingKey {
                    case uuid
                    case name
                    case rateLimitTier = "rate_limit_tier"
                    case billingType = "billing_type"
                }
            }
        }
    }

    private static func fetchAccountInfo(
        sessionKey: String,
        orgId: String?,
        logger: ((String) -> Void)? = nil) async -> WebAccountInfo?
    {
        let url = URL(string: "\(baseURL)/account")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            logger?("Account API status: \(httpResponse.statusCode)")
            guard httpResponse.statusCode == 200 else { return nil }
            return Self.parseAccountInfo(data, orgId: orgId)
        } catch {
            return nil
        }
    }

    private static func parseAccountInfo(_ data: Data, orgId: String?) -> WebAccountInfo? {
        guard let response = try? JSONDecoder().decode(AccountResponse.self, from: data) else { return nil }
        let email = response.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let membership = Self.selectMembership(response.memberships, orgId: orgId)
        let plan = Self.inferPlan(
            rateLimitTier: membership?.organization.rateLimitTier,
            billingType: membership?.organization.billingType)
        return WebAccountInfo(email: email, loginMethod: plan)
    }

    private static func selectMembership(
        _ memberships: [AccountResponse.Membership]?,
        orgId: String?) -> AccountResponse.Membership?
    {
        guard let memberships, !memberships.isEmpty else { return nil }
        if let orgId {
            if let match = memberships.first(where: { $0.organization.uuid == orgId }) { return match }
        }
        return memberships.first
    }

    private static func inferPlan(rateLimitTier: String?, billingType: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        let billing = billingType?.lowercased() ?? ""
        if tier.contains("max") { return "Claude Max" }
        if tier.contains("pro") { return "Claude Pro" }
        if tier.contains("team") { return "Claude Team" }
        if tier.contains("enterprise") { return "Claude Enterprise" }
        if billing.contains("stripe"), tier.contains("claude") { return "Claude Pro" }
        return nil
    }

    #else

    public static func fetchUsage(logger: ((String) -> Void)? = nil) async throws -> WebUsageData {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = browserDetection
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        cookieHeader: String,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = cookieHeader
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func probeEndpoints(
        _ endpoints: [String],
        includePreview: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> [ProbeResult]
    {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func hasSessionKey(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        _ = browserDetection
        _ = logger
        return false
    }

    public static func hasSessionKey(cookieHeader: String?) -> Bool {
        guard let cookieHeader else { return false }
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) where pair.name == "sessionKey" {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("sk-ant-") {
                return true
            }
        }
        return false
    }

    public static func sessionKeyInfo(logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo {
        throw FetchError.notSupportedOnThisPlatform
    }

    #endif
}

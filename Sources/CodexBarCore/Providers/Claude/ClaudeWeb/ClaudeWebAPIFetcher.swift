import Foundation
import SweetCookieKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ClaudeWebHTTPTransport {
    #if DEBUG
    @TaskLocal static var overrideForTesting: (any ProviderHTTPTransport)?
    #endif

    static var current: any ProviderHTTPTransport {
        #if DEBUG
        if let override = self.overrideForTesting {
            return override
        }
        #endif
        return ProviderHTTPClient.shared
    }
}

enum ClaudeWebSessionKeyImport {
    #if DEBUG
    @TaskLocal static var overrideForTesting: ClaudeWebAPIFetcher.SessionKeyInfo?
    #endif

    static var currentOverride: ClaudeWebAPIFetcher.SessionKeyInfo? {
        #if DEBUG
        self.overrideForTesting
        #else
        nil
        #endif
    }
}

private actor ClaudeWebBrowserFetchGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var ownerID: UUID?
    private var waiters: [Waiter] = []

    func acquire(id: UUID) async -> Bool {
        if Task.isCancelled { return false }
        guard self.ownerID != nil else {
            self.ownerID = id
            return true
        }
        return await withCheckedContinuation { continuation in
            self.waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    func cancel(id: UUID) {
        if self.ownerID == id { return }
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func release(id: UUID) {
        guard self.ownerID == id else { return }
        guard !self.waiters.isEmpty else {
            self.ownerID = nil
            return
        }
        let waiter = self.waiters.removeFirst()
        self.ownerID = waiter.id
        waiter.continuation.resume(returning: true)
    }
}

private enum ClaudeWebBrowserFetchSerialization {
    private static let gate = ClaudeWebBrowserFetchGate()

    static func run<T>(_ operation: () async throws -> T) async throws -> T {
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await self.gate.acquire(id: id)
        } onCancel: {
            Task { await self.gate.cancel(id: id) }
        }
        guard acquired else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await self.gate.release(id: id)
            return value
        } catch {
            await self.gate.release(id: id)
            throw error
        }
    }
}

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
    private static let maxProbeBytes = 200_000
    #if os(macOS)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.claude]?.browserCookieOrder ?? Browser.defaultImportOrder
    #else
    private static let cookieImportOrder: BrowserCookieImportOrder = []
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
        case noSessionKeyFound
        case invalidSessionKey
        case notSupportedOnThisPlatform
        case networkError(Error)
        case invalidResponse
        case unauthorized
        case serverError(statusCode: Int)
        case noOrganization
        case organizationNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .noSessionKeyFound:
                "No Claude session key found in browser cookies."
            case .invalidSessionKey:
                "Invalid Claude session key format."
            case .notSupportedOnThisPlatform:
                "Claude web fetching is only supported on macOS."
            case let .networkError(error):
                "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                "Invalid response from Claude API."
            case .unauthorized:
                "Sign in to claude.ai (or refresh Claude cookies) to load usage data."
            case let .serverError(code):
                "Claude API error: HTTP \(code)"
            case .noOrganization:
                "No Claude organization found for this account."
            case let .organizationNotFound(id):
                "Claude organization '\(id)' was not found for this session."
            }
        }
    }

    /// Claude usage data from the API
    public struct WebUsageData: Sendable {
        public let sessionPercentUsed: Double
        public let sessionResetsAt: Date?
        public let weeklyPercentUsed: Double?
        public let weeklyResetsAt: Date?
        public let opusPercentUsed: Double?
        public let extraRateWindows: [NamedRateWindow]
        public let extraUsageCost: ProviderCostSnapshot?
        public let accountOrganization: String?
        public let accountEmail: String?
        public let loginMethod: String?
        /// Whether the API reported a `five_hour` session object. When `false` (the API sent
        /// `five_hour: null`, as enterprise/credit accounts with no live session do), `sessionPercentUsed`
        /// is the synthesized `0` placeholder rather than a real reading. Distinguishing this from a real
        /// session that happens to be at `0%` (with or without a reset) lets lane classifiers drop the
        /// placeholder without hiding a genuine empty session.
        public let hasLiveSessionWindow: Bool

        public init(
            sessionPercentUsed: Double,
            sessionResetsAt: Date?,
            weeklyPercentUsed: Double?,
            weeklyResetsAt: Date?,
            opusPercentUsed: Double?,
            extraRateWindows: [NamedRateWindow],
            extraUsageCost: ProviderCostSnapshot?,
            accountOrganization: String?,
            accountEmail: String?,
            loginMethod: String?,
            hasLiveSessionWindow: Bool = true)
        {
            self.sessionPercentUsed = sessionPercentUsed
            self.sessionResetsAt = sessionResetsAt
            self.weeklyPercentUsed = weeklyPercentUsed
            self.weeklyResetsAt = weeklyResetsAt
            self.opusPercentUsed = opusPercentUsed
            self.extraRateWindows = extraRateWindows
            self.extraUsageCost = extraUsageCost
            self.accountOrganization = accountOrganization
            self.accountEmail = accountEmail
            self.loginMethod = loginMethod
            self.hasLiveSessionWindow = hasLiveSessionWindow
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
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        try await ClaudeWebBrowserFetchSerialization.run {
            try await self.fetchUsageSerialized(
                browserDetection: browserDetection,
                targetOrganizationID: targetOrganizationID,
                logger: logger)
        }
    }

    public static func fetchUsage(
        cookieHeader: String,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }
        let sessionInfo = try self.sessionKeyInfo(cookieHeader: cookieHeader)
        log("Using manual session key (\(sessionInfo.cookieCount) cookies)")
        return try await self.fetchUsage(
            using: sessionInfo,
            targetOrganizationID: targetOrganizationID,
            logger: log)
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        try await self.fetchUsage(
            using: sessionKeyInfo,
            targetOrganizationID: targetOrganizationID,
            logger: logger,
            cacheSourceLabel: nil,
            expectedCacheObservation: .authoritative(nil))
    }

    private static func fetchUsageAndRenewCache(
        cachedEntry: CookieHeaderCache.Entry,
        targetOrganizationID: String?,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let sessionInfo = try self.sessionKeyInfo(cookieHeader: cachedEntry.cookieHeader)
        return try await self.fetchUsage(
            using: sessionInfo,
            targetOrganizationID: targetOrganizationID,
            logger: logger,
            cacheSourceLabel: cachedEntry.sourceLabel,
            expectedCacheObservation: .authoritative(cachedEntry))
    }

    private static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        targetOrganizationID: String?,
        logger: ((String) -> Void)?,
        cacheSourceLabel: String?,
        expectedCacheObservation: CookieHeaderCache.ConditionalMutationObservation,
        persistInitialSessionKey: Bool = false) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?(msg) }
        let sessionKey = sessionKeyInfo.key
        let renewalTracker = ClaudeWebSessionKeyRenewalTracker(initialSessionKey: sessionKey)

        // Fetch organization info
        let organization = try await fetchOrganizationInfo(
            sessionKey: sessionKey,
            targetOrganizationID: targetOrganizationID,
            logger: log,
            renewalTracker: renewalTracker)
        log("Organization resolved")

        var usage = try await fetchUsageData(
            orgId: organization.id,
            sessionKey: renewalTracker.sessionKey,
            logger: log,
            renewalTracker: renewalTracker)
        if usage.extraUsageCost == nil,
           let extra = await ClaudeWebExtraUsageCost.fetch(
               baseURL: Self.baseURL,
               orgId: organization.id,
               sessionKey: renewalTracker.sessionKey,
               logger: log,
               renewalTracker: renewalTracker)
        {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraRateWindows: usage.extraRateWindows,
                extraUsageCost: extra,
                accountOrganization: usage.accountOrganization,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod,
                hasLiveSessionWindow: usage.hasLiveSessionWindow)
        }
        if let account = await fetchAccountInfo(
            sessionKey: renewalTracker.sessionKey,
            orgId: organization.id,
            logger: log,
            renewalTracker: renewalTracker)
        {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraRateWindows: usage.extraRateWindows,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: usage.accountOrganization,
                accountEmail: account.email,
                loginMethod: account.loginMethod,
                hasLiveSessionWindow: usage.hasLiveSessionWindow)
        }
        if usage.accountOrganization == nil, let name = organization.name {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraRateWindows: usage.extraRateWindows,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: name,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod,
                hasLiveSessionWindow: usage.hasLiveSessionWindow)
        }
        if let cacheSourceLabel {
            self.persistSessionKeyIfNeeded(
                source: (sessionKey, cacheSourceLabel),
                renewedCookieHeader: renewalTracker.renewedCookieHeader,
                expectedCacheObservation: expectedCacheObservation,
                persistInitialSessionKey: persistInitialSessionKey,
                logger: log)
        }
        return usage
    }

    /// Probes a list of endpoints using the current claude.ai session cookies.
    /// - Parameters:
    ///   - endpoints: Absolute URLs or "/api/..." paths. Supports "{orgId}" placeholder.
    ///   - includePreview: When true, includes a truncated response preview in results.
    public static func probeEndpoints(
        _ endpoints: [String],
        browserDetection: BrowserDetection,
        includePreview: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> [ProbeResult]
    {
        let log: (String) -> Void = { msg in logger?("[claude-probe] \(msg)") }
        let sessionInfo = try extractSessionKeyInfo(browserDetection: browserDetection, logger: log)
        let sessionKey = sessionInfo.key
        let organization = try? await fetchOrganizationInfo(sessionKey: sessionKey, logger: log)
        let expanded = endpoints.map { endpoint -> String in
            var url = endpoint
            if let orgId = organization?.id {
                url = url.replacingOccurrences(of: "{orgId}", with: orgId)
            }
            if url.hasPrefix("/") {
                url = "https://claude.ai\(url)"
            }
            return url
        }

        var results: [ProbeResult] = []
        results.reserveCapacity(expanded.count)

        for endpoint in expanded {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json, text/html;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
            request.httpMethod = "GET"
            request.timeoutInterval = 20

            do {
                let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)
                let http = response as? HTTPURLResponse
                let contentType = http?.allHeaderFields["Content-Type"] as? String
                let truncated = data.prefix(Self.maxProbeBytes)
                let body = String(data: truncated, encoding: .utf8) ?? ""

                let parsed = Self.parseProbeBody(data: data, fallbackText: body, contentType: contentType)
                let preview = includePreview ? parsed.preview : nil

                results.append(ProbeResult(
                    url: endpoint,
                    statusCode: http?.statusCode,
                    contentType: contentType,
                    topLevelKeys: parsed.keys,
                    emails: parsed.emails,
                    planHints: parsed.planHints,
                    notableFields: parsed.notableFields,
                    bodyPreview: preview))
            } catch {
                results.append(ProbeResult(
                    url: endpoint,
                    statusCode: nil,
                    contentType: nil,
                    topLevelKeys: [],
                    emails: [],
                    planHints: [],
                    notableFields: [],
                    bodyPreview: "Error: \(error.localizedDescription)"))
            }
        }

        return results
    }

    /// Checks if we can find a Claude session key in browser cookies without making API calls.
    public static func hasSessionKey(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        if let cached = CookieHeaderCache.load(provider: .claude),
           self.hasSessionKey(cookieHeader: cached.cookieHeader)
        {
            return true
        }
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
        if let sessionKey = self.findSessionKey(in: pairs) {
            return SessionKeyInfo(
                key: sessionKey,
                sourceLabel: "Manual",
                cookieCount: pairs.count)
        }
        throw FetchError.noSessionKeyFound
    }

    // MARK: - Session Key Extraction

    private static func extractSessionKeyInfo(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo
    {
        if let override = ClaudeWebSessionKeyImport.currentOverride { return override }
        let log: (String) -> Void = { msg in logger?(msg) }

        let cookieDomains = ["claude.ai"]

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = Self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources {
                    if let sessionKey = findSessionKey(in: source.records.map { record in
                        (name: record.name, value: record.value)
                    }) {
                        log("Found sessionKey in \(source.label)")
                        return SessionKeyInfo(
                            key: sessionKey,
                            sourceLabel: source.label,
                            cookieCount: source.records.count)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie load failed: \(error.localizedDescription)")
            }
        }

        throw FetchError.noSessionKeyFound
    }

    private static func findSessionKey(in cookies: [(name: String, value: String)]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate it looks like a Claude session key
            if value.hasPrefix("sk-ant-") {
                return value
            }
        }
        return nil
    }

    // MARK: - API Calls

    private static func fetchOrganizationInfo(
        sessionKey: String,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil,
        renewalTracker: ClaudeWebSessionKeyRenewalTracker? = nil) async throws -> OrganizationInfo
    {
        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        renewalTracker?.observe(response: httpResponse)

        logger?("Organizations API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            return try self.parseOrganizationResponse(data, targetOrganizationID: targetOrganizationID)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func fetchUsageData(
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil,
        renewalTracker: ClaudeWebSessionKeyRenewalTracker? = nil) async throws -> WebUsageData
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        renewalTracker?.observe(response: httpResponse)

        logger?("Usage API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            return try self.parseUsageResponse(data, logger: logger)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func parseUsageResponse(_ data: Data, logger: ((String) -> Void)? = nil) throws -> WebUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }

        // Parse five_hour (session) usage
        var sessionPercent: Double?
        var sessionResets: Date?
        let fiveHour = json["five_hour"] as? [String: Any]
        if let fiveHour {
            sessionPercent = Self.percentValue(from: fiveHour["utilization"])
            if let resetsAt = fiveHour["resets_at"] as? String {
                sessionResets = self.parseISO8601Date(resetsAt)
            }
        }
        // Enterprise/credit-based accounts return null for five_hour; treat as 0% rather than an error.
        // Track the object's presence so a real 0% session (with or without a reset) is not mistaken for
        // the synthesized null-session placeholder downstream.
        let resolvedSessionPercent = sessionPercent ?? 0.0
        let hasLiveSessionWindow = fiveHour != nil

        // Parse seven_day (weekly) usage
        var weeklyPercent: Double?
        var weeklyResets: Date?
        if let sevenDay = json["seven_day"] as? [String: Any] {
            weeklyPercent = Self.percentValue(from: sevenDay["utilization"])
            if let resetsAt = sevenDay["resets_at"] as? String {
                weeklyResets = self.parseISO8601Date(resetsAt)
            }
        }

        // Parse seven_day_sonnet (preferred) / seven_day_opus usage
        var opusPercent: Double?
        if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
            opusPercent = Self.percentValue(from: sevenDaySonnet["utilization"])
        } else if let sevenDayOpus = json["seven_day_opus"] as? [String: Any] {
            opusPercent = Self.percentValue(from: sevenDayOpus["utilization"])
        }
        let extraRateParse = ClaudeWebExtraRateWindowParser.parse(from: json)
        if let sourceKey = extraRateParse.sourceKeys["claude-routines"] {
            logger?("Usage API extra window key matched: routines=\(sourceKey)")
        }
        let extraUsageCost = ClaudeWebExtraUsageCost.parse(from: json["extra_usage"])

        return WebUsageData(
            sessionPercentUsed: resolvedSessionPercent,
            sessionResetsAt: sessionResets,
            weeklyPercentUsed: weeklyPercent,
            weeklyResetsAt: weeklyResets,
            opusPercentUsed: opusPercent,
            extraRateWindows: extraRateParse.windows,
            extraUsageCost: extraUsageCost,
            accountOrganization: nil,
            accountEmail: nil,
            loginMethod: nil,
            hasLiveSessionWindow: hasLiveSessionWindow)
    }

    private static func percentValue(from value: Any?) -> Double? {
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        return nil
    }

    #if DEBUG

    // MARK: - Test hooks (DEBUG-only)

    public static func _parseUsageResponseForTesting(_ data: Data) throws -> WebUsageData {
        try self.parseUsageResponse(data)
    }

    public static func _parseOrganizationsResponseForTesting(
        _ data: Data,
        targetOrganizationID: String? = nil) throws -> OrganizationInfo
    {
        try self.parseOrganizationResponse(data, targetOrganizationID: targetOrganizationID)
    }

    public static func _parseOverageSpendLimitForTesting(_ data: Data) -> ProviderCostSnapshot? {
        ClaudeWebExtraUsageCost.parseOverageSpendLimit(data)
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

    private static func parseOrganizationResponse(
        _ data: Data,
        targetOrganizationID: String? = nil) throws -> OrganizationInfo
    {
        guard let organizations = try? JSONDecoder().decode([ClaudeWebOrganizationResponse].self, from: data) else {
            throw FetchError.invalidResponse
        }
        if let targetOrganizationID = targetOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetOrganizationID.isEmpty
        {
            guard let selected = organizations.first(where: { $0.uuid == targetOrganizationID }) else {
                throw FetchError.organizationNotFound(targetOrganizationID)
            }
            return self.organizationInfo(from: selected)
        }
        guard let selected = organizations.first(where: { $0.hasChatCapability })
            ?? organizations.first(where: { !$0.isApiOnly })
            ?? organizations.first
        else {
            throw FetchError.noOrganization
        }
        return self.organizationInfo(from: selected)
    }

    private static func organizationInfo(from selected: ClaudeWebOrganizationResponse) -> OrganizationInfo {
        let name = selected.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = (name?.isEmpty ?? true) ? nil : name
        return OrganizationInfo(id: selected.uuid, name: sanitized)
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
        logger: ((String) -> Void)? = nil,
        renewalTracker: ClaudeWebSessionKeyRenewalTracker? = nil) async -> WebAccountInfo?
    {
        let url = URL(string: "\(baseURL)/account")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            renewalTracker?.observe(response: httpResponse)
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
        let plan = ClaudePlan.webLoginMethod(
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

    private struct ProbeParseResult {
        let keys: [String]
        let emails: [String]
        let planHints: [String]
        let notableFields: [String]
        let preview: String?
    }

    private static func parseProbeBody(
        data: Data,
        fallbackText: String,
        contentType: String?) -> ProbeParseResult
    {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = (contentType?.lowercased().contains("application/json") ?? false) ||
            trimmed.hasPrefix("{") || trimmed.hasPrefix("[")

        var keys: [String] = []
        var notableFields: [String] = []
        if looksJSON, let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                keys = dict.keys.sorted()
            } else if let array = json as? [[String: Any]], let first = array.first {
                keys = first.keys.sorted()
            }
            notableFields = Self.extractNotableFields(from: json)
        }

        let emails = Self.extractEmails(from: trimmed)
        let planHints = Self.extractPlanHints(from: trimmed)
        let preview = trimmed.isEmpty ? nil : String(trimmed.prefix(500))
        return ProbeParseResult(
            keys: keys,
            emails: emails,
            planHints: planHints,
            notableFields: notableFields,
            preview: preview)
    }

    private static func extractEmails(from text: String) -> [String] {
        let pattern = #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 0), in: text) else { return }
            let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { results.append(value) }
        }
        return Array(Set(results)).sorted()
    }

    private static func extractPlanHints(from text: String) -> [String] {
        let pattern = #"(?i)\b(max|pro|team|ultra|enterprise)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { results.append(value) }
        }
        return Array(Set(results)).sorted()
    }

    private static func extractNotableFields(from json: Any) -> [String] {
        let pattern = #"(?i)(plan|tier|subscription|seat|billing|product)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        var results: [String] = []

        func keyMatches(_ key: String) -> Bool {
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            return regex.firstMatch(in: key, options: [], range: range) != nil
        }

        func appendValue(_ keyPath: String, value: Any) {
            if results.count >= 40 { return }
            let rendered: String
            switch value {
            case let str as String:
                rendered = str
            case let num as NSNumber:
                rendered = num.stringValue
            case let bool as Bool:
                rendered = bool ? "true" : "false"
            default:
                return
            }
            let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            results.append("\(keyPath)=\(trimmed)")
        }

        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for (key, nested) in dict {
                    let nextPath = path.isEmpty ? key : "\(path).\(key)"
                    if keyMatches(key) {
                        appendValue(nextPath, value: nested)
                    }
                    walk(nested, path: nextPath)
                }
            } else if let array = value as? [Any] {
                for (idx, nested) in array.enumerated() {
                    let nextPath = "\(path)[\(idx)]"
                    walk(nested, path: nextPath)
                }
            }
        }

        walk(json, path: "")
        return results
    }

    #else

    public static func fetchUsage(logger: ((String) -> Void)? = nil) async throws -> WebUsageData {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        browserDetection: BrowserDetection,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = browserDetection
        _ = targetOrganizationID
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        cookieHeader: String,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = cookieHeader
        _ = targetOrganizationID
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        targetOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = targetOrganizationID
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

extension ClaudeWebAPIFetcher {
    private static func persistSessionKeyIfNeeded(
        source: (initialSessionKey: String, label: String),
        renewedCookieHeader: String?,
        expectedCacheObservation: CookieHeaderCache.ConditionalMutationObservation,
        persistInitialSessionKey: Bool,
        logger: (String) -> Void)
    {
        let importedCookieHeader = persistInitialSessionKey ? "sessionKey=\(source.initialSessionKey)" : nil
        guard let cookieHeader = renewedCookieHeader ?? importedCookieHeader else { return }
        let stored = CookieHeaderCache.storeIfObservationCurrent(
            provider: .claude,
            expected: expectedCacheObservation,
            cookieHeader: cookieHeader,
            sourceLabel: source.label)
        if renewedCookieHeader != nil {
            logger(stored ? "Stored renewed Claude session key" : "Skipped renewal because the cache changed")
        }
    }
}

private final class ClaudeWebSessionKeyRenewalTracker: @unchecked Sendable {
    private let initialSessionKey: String
    private let lock = NSLock()
    private var currentSessionKey: String

    init(initialSessionKey: String) {
        self.initialSessionKey = initialSessionKey
        self.currentSessionKey = initialSessionKey
    }

    var sessionKey: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentSessionKey
    }

    var renewedCookieHeader: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.currentSessionKey != self.initialSessionKey else { return nil }
        return "sessionKey=\(self.currentSessionKey)"
    }

    func observe(response: HTTPURLResponse) {
        guard response.statusCode == 200,
              let sessionKey = Self.sessionKey(fromSetCookieHeaders: response.allHeaderFields)
        else {
            return
        }
        self.lock.lock()
        self.currentSessionKey = sessionKey
        self.lock.unlock()
    }

    private static func sessionKey(fromSetCookieHeaders fields: [AnyHashable: Any]) -> String? {
        guard let value = fields.first(where: {
            String(describing: $0.key).caseInsensitiveCompare("Set-Cookie") == .orderedSame
        })?.value else {
            return nil
        }
        var latestSessionKey: String?
        for header in self.setCookieHeaderValues(from: value) {
            latestSessionKey = self.sessionKey(fromSetCookieHeader: header) ?? latestSessionKey
        }
        return latestSessionKey
    }

    private static func setCookieHeaderValues(from value: Any) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return values.map { String(describing: $0) }
        }
        return [String(describing: value)]
    }

    private static func sessionKey(fromSetCookieHeader header: String) -> String? {
        let pattern = #"(?i)(?:^|[,\r\n])\s*sessionKey=([^;,\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        var latestSessionKey: String?
        for match in regex.matches(in: header, range: range) {
            guard match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: header)
            else {
                continue
            }
            let value = String(header[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("sk-ant-") {
                latestSessionKey = value
            }
        }
        return latestSessionKey
    }
}

private enum ClaudeWebExtraUsageCost {
    // MARK: - Extra usage cost (Claude "Extra")

    static func parse(from value: Any?) -> ProviderCostSnapshot? {
        guard let extraUsage = value as? [String: Any] else { return nil }
        guard let used = Self.doubleValue(extraUsage["used_credits"]),
              let limit = Self.doubleValue(extraUsage["monthly_limit"] ?? extraUsage["monthly_credit_limit"]),
              limit > 0 else { return nil }
        let currency = (extraUsage["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currencyCode = currency?.isEmpty == false ? currency ?? "USD" : "USD"
        return Self.makeExtraUsageCost(
            usedCredits: used,
            monthlyCreditLimit: limit,
            currencyCode: currencyCode)
    }

    struct OverageSpendLimitResponse: Decodable {
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
    static func fetch(
        baseURL: String,
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil,
        renewalTracker: ClaudeWebSessionKeyRenewalTracker? = nil) async -> ProviderCostSnapshot?
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            renewalTracker?.observe(response: httpResponse)
            logger?("Overage API status: \(httpResponse.statusCode)")
            guard httpResponse.statusCode == 200 else { return nil }
            return Self.parseOverageSpendLimit(data)
        } catch {
            return nil
        }
    }

    static func parseOverageSpendLimit(_ data: Data) -> ProviderCostSnapshot? {
        guard let decoded = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data) else { return nil }
        guard decoded.isEnabled == true else { return nil }
        guard let used = decoded.usedCredits,
              let limit = decoded.monthlyCreditLimit,
              let currency = decoded.currency,
              !currency.isEmpty else { return nil }

        return Self.makeExtraUsageCost(
            usedCredits: used,
            monthlyCreditLimit: limit,
            currencyCode: currency)
    }

    static func makeExtraUsageCost(
        usedCredits: Double,
        monthlyCreditLimit: Double,
        currencyCode: String) -> ProviderCostSnapshot
    {
        let usedAmount = usedCredits / 100.0
        let limitAmount = monthlyCreditLimit / 100.0

        return ProviderCostSnapshot(
            used: usedAmount,
            limit: limitAmount,
            currencyCode: currencyCode,
            period: "Monthly cap",
            resetsAt: nil,
            updatedAt: Date())
    }

    static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let int as Int:
            Double(int)
        case let double as Double:
            double
        case let string as String:
            Double(string)
        default:
            nil
        }
    }
}

#if os(macOS)
extension ClaudeWebAPIFetcher {
    fileprivate static func fetchUsageSerialized(
        browserDetection: BrowserDetection,
        targetOrganizationID: String?,
        logger: ((String) -> Void)?) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }
        var cacheObservation = CookieHeaderCache.observeForConditionalMutation(provider: .claude)

        if let cached = cacheObservation.entry,
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.fetchUsageAndRenewCache(
                    cachedEntry: cached,
                    targetOrganizationID: targetOrganizationID,
                    logger: log)
            } catch let error as FetchError {
                switch error {
                case .unauthorized, .noSessionKeyFound, .invalidSessionKey:
                    let cleared = CookieHeaderCache.clearIfCurrent(provider: .claude, expected: cached)
                    cacheObservation = .authoritative(cleared ? nil : cached)
                default:
                    throw error
                }
            } catch {
                throw error
            }
        }

        let sessionInfo = try extractSessionKeyInfo(browserDetection: browserDetection, logger: log)
        log("Found session key (\(sessionInfo.cookieCount) cookies)")

        return try await self.fetchUsage(
            using: sessionInfo,
            targetOrganizationID: targetOrganizationID,
            logger: log,
            cacheSourceLabel: sessionInfo.sourceLabel,
            expectedCacheObservation: cacheObservation,
            persistInitialSessionKey: true)
    }
}
#endif

private struct ClaudeWebOrganizationResponse: Decodable {
    let uuid: String
    let name: String?
    let capabilities: [String]?

    var normalizedCapabilities: Set<String> {
        Set((self.capabilities ?? []).map { $0.lowercased() })
    }

    var hasChatCapability: Bool {
        self.normalizedCapabilities.contains("chat")
    }

    var isApiOnly: Bool {
        let normalized = self.normalizedCapabilities
        return !normalized.isEmpty && normalized == ["api"]
    }
}

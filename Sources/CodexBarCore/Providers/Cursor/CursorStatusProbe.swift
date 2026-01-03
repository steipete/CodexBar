import Foundation
import SweetCookieKit

#if os(macOS)

private let cursorCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Cursor Cookie Importer

/// Imports Cursor session cookies from browser cookies.
public enum CursorCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// Attempts to import Cursor cookies using the standard browser import order.
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }

        let cookieDomains = ["cursor.com", "cursor.sh"]
        for browserSource in cursorCookieImportOrder {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) }) {
                        log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    } else {
                        log("\(source.label) cookies found, but no Cursor session cookie present")
                    }
                }
            } catch {
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    /// Check if Cursor session cookies are available
    public static func hasSession(logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Cursor API Models

public struct CursorUsageSummary: Codable, Sendable {
    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let membershipType: String?
    public let limitType: String?
    public let isUnlimited: Bool?
    public let autoModelSelectedDisplayMessage: String?
    public let namedModelSelectedDisplayMessage: String?
    public let individualUsage: CursorIndividualUsage?
    public let teamUsage: CursorTeamUsage?
}

public struct CursorIndividualUsage: Codable, Sendable {
    public let plan: CursorPlanUsage?
    public let onDemand: CursorOnDemandUsage?
}

public struct CursorPlanUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents (e.g., 2000 = $20.00)
    public let used: Int?
    /// Limit in cents (e.g., 2000 = $20.00)
    public let limit: Int?
    /// Remaining in cents
    public let remaining: Int?
    public let breakdown: CursorPlanBreakdown?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let totalPercentUsed: Double?
}

public struct CursorPlanBreakdown: Codable, Sendable {
    public let included: Int?
    public let bonus: Int?
    public let total: Int?
}

public struct CursorOnDemandUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents
    public let used: Int?
    /// Limit in cents (nil if unlimited)
    public let limit: Int?
    /// Remaining in cents (nil if unlimited)
    public let remaining: Int?
}

public struct CursorTeamUsage: Codable, Sendable {
    public let onDemand: CursorOnDemandUsage?
}

// MARK: - Cursor Usage API Models (Legacy Request-Based Plans)

/// Response from `/api/usage?user=ID` endpoint for legacy request-based plans.
public struct CursorUsageResponse: Codable, Sendable {
    public let gpt4: CursorModelUsage?
    public let startOfMonth: String?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
        case startOfMonth
    }
}

public struct CursorModelUsage: Codable, Sendable {
    public let numRequests: Int?
    public let numRequestsTotal: Int?
    public let numTokens: Int?
    public let maxRequestUsage: Int?
    public let maxTokenUsage: Int?
}

/// Request usage snapshot for legacy Cursor plans (request-based instead of token-based).
public struct CursorRequestUsage: Codable, Sendable {
    /// Requests used this billing cycle
    public let used: Int
    /// Request limit (e.g., 500 for legacy enterprise plans)
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var usedPercent: Double {
        guard self.limit > 0 else { return 0 }
        return (Double(self.used) / Double(self.limit)) * 100
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

public struct CursorUserInfo: Codable, Sendable {
    public let email: String?
    public let emailVerified: Bool?
    public let name: String?
    public let sub: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let picture: String?

    enum CodingKeys: String, CodingKey {
        case email
        case emailVerified = "email_verified"
        case name
        case sub
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case picture
    }
}

// MARK: - Cursor Status Snapshot

public struct CursorStatusSnapshot: Sendable {
    /// Percentage of included plan usage (0-100)
    public let planPercentUsed: Double
    /// Included plan usage in USD
    public let planUsedUSD: Double
    /// Included plan limit in USD
    public let planLimitUSD: Double
    /// On-demand usage in USD
    public let onDemandUsedUSD: Double
    /// On-demand limit in USD (nil if unlimited)
    public let onDemandLimitUSD: Double?
    /// Team on-demand usage in USD (for team plans)
    public let teamOnDemandUsedUSD: Double?
    /// Team on-demand limit in USD
    public let teamOnDemandLimitUSD: Double?
    /// Billing cycle reset date
    public let billingCycleEnd: Date?
    /// Membership type (e.g., "enterprise", "pro", "hobby")
    public let membershipType: String?
    /// User email
    public let accountEmail: String?
    /// User name
    public let accountName: String?
    /// Raw API response for debugging
    public let rawJSON: String?

    // MARK: - Legacy Plan (Request-Based) Fields

    /// Requests used this billing cycle (legacy plans only)
    public let requestsUsed: Int?
    /// Request limit (non-nil indicates legacy request-based plan)
    public let requestsLimit: Int?

    /// Whether this is a legacy request-based plan (vs token-based)
    public var isLegacyRequestPlan: Bool {
        self.requestsLimit != nil
    }

    public init(
        planPercentUsed: Double,
        planUsedUSD: Double,
        planLimitUSD: Double,
        onDemandUsedUSD: Double,
        onDemandLimitUSD: Double?,
        teamOnDemandUsedUSD: Double?,
        teamOnDemandLimitUSD: Double?,
        billingCycleEnd: Date?,
        membershipType: String?,
        accountEmail: String?,
        accountName: String?,
        rawJSON: String?,
        requestsUsed: Int? = nil,
        requestsLimit: Int? = nil)
    {
        self.planPercentUsed = planPercentUsed
        self.planUsedUSD = planUsedUSD
        self.planLimitUSD = planLimitUSD
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandLimitUSD = onDemandLimitUSD
        self.teamOnDemandUsedUSD = teamOnDemandUsedUSD
        self.teamOnDemandLimitUSD = teamOnDemandLimitUSD
        self.billingCycleEnd = billingCycleEnd
        self.membershipType = membershipType
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.rawJSON = rawJSON
        self.requestsUsed = requestsUsed
        self.requestsLimit = requestsLimit
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: For legacy request-based plans, use request usage; otherwise use plan percentage
        let primaryUsedPercent: Double = if self.isLegacyRequestPlan,
                                            let used = self.requestsUsed,
                                            let limit = self.requestsLimit,
                                            limit > 0
        {
            (Double(used) / Double(limit)) * 100
        } else {
            self.planPercentUsed
        }

        let primary = RateWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: nil,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })

        // Always use individual on-demand values (what users see in their Cursor dashboard).
        // Team values are aggregates across all members, not useful for individual tracking.
        let resolvedOnDemandUsed = self.onDemandUsedUSD
        let resolvedOnDemandLimit = self.onDemandLimitUSD

        // Secondary: On-demand usage as percentage of individual limit
        let secondary: RateWindow? = if let limit = resolvedOnDemandLimit,
                                        limit > 0
        {
            RateWindow(
                usedPercent: (resolvedOnDemandUsed / limit) * 100,
                windowMinutes: nil,
                resetsAt: self.billingCycleEnd,
                resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })
        } else {
            nil
        }

        // Provider cost snapshot for on-demand usage
        let providerCost: ProviderCostSnapshot? = if resolvedOnDemandUsed > 0 {
            ProviderCostSnapshot(
                used: resolvedOnDemandUsed,
                limit: resolvedOnDemandLimit ?? 0,
                currencyCode: "USD",
                period: "monthly",
                resetsAt: self.billingCycleEnd,
                updatedAt: Date())
        } else {
            nil
        }

        // Legacy plan request usage (when maxRequestUsage is set)
        let cursorRequests: CursorRequestUsage? = if let used = self.requestsUsed,
                                                     let limit = self.requestsLimit
        {
            CursorRequestUsage(used: used, limit: limit)
        } else {
            nil
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .cursor,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.membershipType.map { Self.formatMembershipType($0) })
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: providerCost,
            cursorRequests: cursorRequests,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }

    private static func formatMembershipType(_ type: String) -> String {
        switch type.lowercased() {
        case "enterprise":
            "Cursor Enterprise"
        case "pro":
            "Cursor Pro"
        case "hobby":
            "Cursor Hobby"
        case "team":
            "Cursor Team"
        default:
            "Cursor \(type.capitalized)"
        }
    }
}

// MARK: - Cursor Status Probe Error

public enum CursorStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Cursor. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Cursor usage: \(msg)"
        case .noSessionCookie:
            "No Cursor session found. Please log in to cursor.com in \(cursorCookieImportOrder.loginHint)."
        }
    }
}

// MARK: - Cursor Session Store

public actor CursorSessionStore {
    public static let shared = CursorSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cursor-session.json")

        // Load saved cookies on init
        Task { await self.loadFromDiskIfNeeded() }
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.hasLoadedFromDisk = true
        self.sessionCookies = cookies
        self.saveToDisk()
    }

    public func getCookies() -> [HTTPCookie] {
        self.loadFromDiskIfNeeded()
        return self.sessionCookies
    }

    public func clearCookies() {
        self.hasLoadedFromDisk = true
        self.sessionCookies = []
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public func hasValidSession() -> Bool {
        self.loadFromDiskIfNeeded()
        return !self.sessionCookies.isEmpty
    }

    #if DEBUG
    func resetForTesting(clearDisk: Bool = true) {
        self.hasLoadedFromDisk = false
        self.sessionCookies = []
        if clearDisk {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
    #endif

    private func loadFromDiskIfNeeded() {
        guard !self.hasLoadedFromDisk else { return }
        self.hasLoadedFromDisk = true
        self.loadFromDisk()
    }

    private func saveToDisk() {
        // Convert cookie properties to JSON-serializable format
        // Date values must be converted to TimeInterval (Double)
        let cookieData = self.sessionCookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var serializable: [String: Any] = [:]
            for (key, value) in props {
                let keyString = key.rawValue
                if let date = value as? Date {
                    // Convert Date to TimeInterval for JSON compatibility
                    serializable[keyString] = date.timeIntervalSince1970
                    serializable[keyString + "_isDate"] = true
                } else if let url = value as? URL {
                    serializable[keyString] = url.absoluteString
                    serializable[keyString + "_isURL"] = true
                } else if JSONSerialization.isValidJSONObject([value]) ||
                    value is String ||
                    value is Bool ||
                    value is NSNumber
                {
                    serializable[keyString] = value
                }
            }
            return serializable
        }
        guard !cookieData.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: cookieData, options: [.prettyPrinted])
        else {
            return
        }
        try? data.write(to: self.fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.fileURL),
              let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        self.sessionCookies = cookieArray.compactMap { props in
            // Convert back to HTTPCookiePropertyKey dictionary
            var cookieProps: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in props {
                // Skip marker keys
                if key.hasSuffix("_isDate") || key.hasSuffix("_isURL") { continue }

                let propKey = HTTPCookiePropertyKey(key)

                // Check if this was a Date
                if props[key + "_isDate"] as? Bool == true, let interval = value as? TimeInterval {
                    cookieProps[propKey] = Date(timeIntervalSince1970: interval)
                }
                // Check if this was a URL
                else if props[key + "_isURL"] as? Bool == true, let urlString = value as? String {
                    cookieProps[propKey] = URL(string: urlString)
                } else {
                    cookieProps[propKey] = value
                }
            }
            return HTTPCookie(properties: cookieProps)
        }
    }
}

// MARK: - Cursor Status Probe

public struct CursorStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0

    public init(baseURL: URL = URL(string: "https://cursor.com")!, timeout: TimeInterval = 15.0) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Fetch Cursor usage using browser cookies with fallback to stored session.
    public func fetch(cookieHeaderOverride: String? = nil, logger: ((String) -> Void)? = nil)
        async throws -> CursorStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        // Try importing cookies from the configured browser order first.
        do {
            let session = try CursorCookieImporter.importSession(logger: log)
            log("Using cookies from \(session.sourceLabel)")
            return try await self.fetchWithCookieHeader(session.cookieHeader)
        } catch {
            log("Browser cookie import failed: \(error.localizedDescription)")
        }

        // Fall back to stored session cookies (from "Add Account" login flow)
        let storedCookies = await CursorSessionStore.shared.getCookies()
        if !storedCookies.isEmpty {
            log("Using stored session cookies")
            let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            do {
                return try await self.fetchWithCookieHeader(cookieHeader)
            } catch {
                if case CursorStatusProbeError.notLoggedIn = error {
                    // Clear only when auth is invalid; keep for transient failures.
                    await CursorSessionStore.shared.clearCookies()
                    log("Stored session invalid, cleared")
                } else {
                    log("Stored session failed: \(error.localizedDescription)")
                }
            }
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        async let usageSummaryTask = self.fetchUsageSummary(cookieHeader: cookieHeader)
        async let userInfoTask = self.fetchUserInfo(cookieHeader: cookieHeader)

        let usageSummary = try await usageSummaryTask
        let userInfo = try? await userInfoTask

        // Fetch legacy request usage only if user has a sub ID.
        // Uses try? to avoid breaking the flow for users where this endpoint fails or returns unexpected data.
        let requestUsage: CursorUsageResponse?
        if let userId = userInfo?.sub {
            requestUsage = try? await self.fetchRequestUsage(userId: userId, cookieHeader: cookieHeader)
        } else {
            requestUsage = nil
        }

        return self.parseUsageSummary(usageSummary, userInfo: userInfo, requestUsage: requestUsage)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws -> CursorUsageSummary {
        let url = self.baseURL.appendingPathComponent("/api/usage-summary")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CursorStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CursorUsageSummary.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CursorStatusProbeError
                .parseFailed("JSON decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = self.baseURL.appendingPathComponent("/api/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch user info")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CursorUserInfo.self, from: data)
    }

    private func fetchRequestUsage(userId: String, cookieHeader: String) async throws -> CursorUsageResponse {
        let url = self.baseURL.appendingPathComponent("/api/usage")
            .appending(queryItems: [URLQueryItem(name: "user", value: userId)])
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch request usage")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CursorUsageResponse.self, from: data)
    }

    func parseUsageSummary(
        _ summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        requestUsage: CursorUsageResponse? = nil
    ) -> CursorStatusSnapshot {
        // Parse billing cycle end date
        let billingCycleEnd: Date? = summary.billingCycleEnd.flatMap { dateString in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }

        // Convert cents to USD (plan percent derives from raw values to avoid percent unit mismatches).
        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.limit ?? 0)
        let planUsed = planUsedRaw / 100.0
        let planLimit = planLimitRaw / 100.0
        let planPercentUsed: Double = if planLimitRaw > 0 {
            (planUsedRaw / planLimitRaw) * 100
        } else if let totalPercentUsed = summary.individualUsage?.plan?.totalPercentUsed {
            totalPercentUsed <= 1 ? totalPercentUsed * 100 : totalPercentUsed
        } else {
            0
        }

        let onDemandUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimit: Double? = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let teamOnDemandUsed: Double? = summary.teamUsage?.onDemand?.used.map { Double($0) / 100.0 }
        let teamOnDemandLimit: Double? = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        // Legacy request-based plan: maxRequestUsage being non-nil indicates a request-based plan
        let requestsUsed: Int? = requestUsage?.gpt4?.numRequests
        let requestsLimit: Int? = requestUsage?.gpt4?.maxRequestUsage

        return CursorStatusSnapshot(
            planPercentUsed: planPercentUsed,
            planUsedUSD: planUsed,
            planLimitUSD: planLimit,
            onDemandUsedUSD: onDemandUsed,
            onDemandLimitUSD: onDemandLimit,
            teamOnDemandUsedUSD: teamOnDemandUsed,
            teamOnDemandLimitUSD: teamOnDemandLimit,
            billingCycleEnd: billingCycleEnd,
            membershipType: summary.membershipType,
            accountEmail: userInfo?.email,
            accountName: userInfo?.name,
            rawJSON: nil,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit)
    }
}

#else

// MARK: - Cursor (Unsupported)

public enum CursorStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Cursor is only supported on macOS."
    }
}

public struct CursorStatusSnapshot: Sendable {
    public init() {}

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: nil)
    }
}

public struct CursorStatusProbe: Sendable {
    public init(baseURL: URL = URL(string: "https://cursor.com")!, timeout: TimeInterval = 15.0) {
        _ = baseURL
        _ = timeout
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot {
        _ = logger
        throw CursorStatusProbeError.notSupported
    }
}

#endif

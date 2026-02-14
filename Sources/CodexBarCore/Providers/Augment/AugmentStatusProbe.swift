import Foundation
import SweetCookieKit

#if os(macOS)

private let augmentCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.augment]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Augment Cookie Importer

/// Imports Augment session cookies from browser cookies.
public enum AugmentCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    /// Auth0 session cookies used by Augment
    /// NOTE: This list may not be exhaustive. If authentication fails with cookies present,
    /// check debug logs for cookie names and report them.
    private static let sessionCookieNames: Set<String> = [
        "_session", // Legacy session cookie
        "auth0", // Auth0 session
        "auth0.is.authenticated", // Auth0 authentication flag
        "a0.spajs.txs", // Auth0 SPA transaction state
        "__Secure-next-auth.session-token", // NextAuth secure session
        "next-auth.session-token", // NextAuth session
        "__Host-authjs.csrf-token", // AuthJS CSRF token
        "authjs.session-token", // AuthJS session
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

        /// Returns cookie header filtered for a specific target URL
        public func cookieHeader(for url: URL) -> String {
            guard let host = url.host else { return "" }

            let matchingCookies = self.cookies.filter { cookie in
                let domain = cookie.domain

                // Handle wildcard domains (e.g., ".augmentcode.com")
                if domain.hasPrefix(".") {
                    let baseDomain = String(domain.dropFirst())
                    return host == baseDomain || host.hasSuffix(".\(baseDomain)")
                }

                // Exact match or subdomain match
                return host == domain || host.hasSuffix(".\(domain)")
            }

            return matchingCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// Attempts to import Augment cookies using the standard browser import order.
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let log: (String) -> Void = { msg in logger?("[augment-cookie] \(msg)") }

        let cookieDomains = ["augmentcode.com", "app.augmentcode.com"]
        for browserSource in augmentCookieImportOrder {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)

                    // Log all cookies found for debugging
                    let cookieNames = httpCookies.map(\.name).joined(separator: ", ")
                    log("Found \(httpCookies.count) cookies in \(source.label): \(cookieNames)")

                    // Check if we have any session cookies
                    let matchingCookies = httpCookies.filter { Self.sessionCookieNames.contains($0.name) }
                    if !matchingCookies.isEmpty {
                        let matchingCookieNames = matchingCookies.map(\.name).joined(separator: ", ")
                        log("✓ Found Augment session cookies in \(source.label): \(matchingCookieNames)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    } else if !httpCookies.isEmpty {
                        // Log unrecognized cookies to help discover missing session cookie names
                        log(
                            "⚠️ \(source.label) has \(httpCookies.count) cookies but none match known session cookies")
                        log("   Cookie names found: \(cookieNames)")
                        log("   If you're logged into Augment, please report these cookie names")
                        log("   to help improve detection")
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AugmentStatusProbeError.noSessionCookie
    }

    /// Check if Augment session cookies are available
    public static func hasSession(logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Augment API Models

public struct AugmentCreditsResponse: Codable, Sendable {
    public let usageUnitsRemaining: Double?
    public let usageUnitsConsumedThisBillingCycle: Double?
    public let usageUnitsAvailable: Double?
    public let usageBalanceStatus: String?

    /// Computed properties for compatibility with existing code
    public var credits: Double? {
        self.usageUnitsRemaining
    }

    public var creditsUsed: Double? {
        self.usageUnitsConsumedThisBillingCycle
    }

    public var creditsLimit: Double? {
        guard let remaining = self.usageUnitsRemaining,
              let consumed = self.usageUnitsConsumedThisBillingCycle
        else {
            return nil
        }
        return remaining + consumed
    }

    private enum CodingKeys: String, CodingKey {
        case usageUnitsRemaining
        case usageUnitsConsumedThisBillingCycle
        case usageUnitsAvailable
        case usageBalanceStatus
    }
}

public struct AugmentSubscriptionResponse: Codable, Sendable {
    public let planName: String?
    public let billingPeriodEnd: String?
    public let email: String?
    public let organization: String?

    private enum CodingKeys: String, CodingKey {
        case planName
        case billingPeriodEnd
        case email
        case organization
    }
}

// MARK: - Augment Status Snapshot

public struct AugmentStatusSnapshot: Sendable {
    public let creditsRemaining: Double?
    public let creditsUsed: Double?
    public let creditsLimit: Double?
    public let billingCycleEnd: Date?
    public let accountEmail: String?
    public let accountPlan: String?
    public let rawJSON: String?

    public init(
        creditsRemaining: Double?,
        creditsUsed: Double?,
        creditsLimit: Double?,
        billingCycleEnd: Date?,
        accountEmail: String?,
        accountPlan: String?,
        rawJSON: String?)
    {
        self.creditsRemaining = creditsRemaining
        self.creditsUsed = creditsUsed
        self.creditsLimit = creditsLimit
        self.billingCycleEnd = billingCycleEnd
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
        self.rawJSON = rawJSON
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let percentUsed: Double = if let used = self.creditsUsed, let limit = self.creditsLimit, limit > 0 {
            (used / limit) * 100.0
        } else if let remaining = self.creditsRemaining, let limit = self.creditsLimit, limit > 0 {
            ((limit - remaining) / limit) * 100.0
        } else {
            0
        }

        let primary = RateWindow(
            usedPercent: percentUsed,
            windowMinutes: nil,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { "Resets \(Self.formatResetDate($0))" })

        let identity = ProviderIdentitySnapshot(
            providerID: .augment,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Augment Status Probe Error

public enum AugmentStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Augment. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Augment API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Augment usage: \(msg)"
        case .noSessionCookie:
            "No Augment session found. Please log in to app.augmentcode.com in \(augmentCookieImportOrder.loginHint)."
        case .sessionExpired:
            "Augment session expired. Please log in again."
        }
    }
}

// MARK: - Augment Session Store

public actor AugmentSessionStore {
    public static let shared = AugmentSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("augment-session.json")

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

// MARK: - Augment Status Probe

public struct AugmentStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0

    public init(baseURL: URL = URL(string: "https://app.augmentcode.com")!, timeout: TimeInterval = 15.0) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Fetch Augment usage with manual cookie header (for debugging).
    public func fetchWithManualCookies(_ cookieHeader: String) async throws -> AugmentStatusSnapshot {
        try await self.fetchWithCookieHeader(cookieHeader)
    }

    /// Fetch Augment usage using browser cookies with fallback to stored session.
    public func fetch(cookieHeaderOverride: String? = nil, logger: ((String) -> Void)? = nil)
        async throws -> AugmentStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[augment] \(msg)") }

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        if let cached = CookieHeaderCache.load(provider: .augment),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.fetchWithCookieHeader(cached.cookieHeader)
            } catch let error as AugmentStatusProbeError {
                switch error {
                case .notLoggedIn, .sessionExpired:
                    CookieHeaderCache.clear(provider: .augment)
                default:
                    throw error
                }
            } catch {
                throw error
            }
        }

        // Try importing cookies from the configured browser order first.
        do {
            let session = try AugmentCookieImporter.importSession(logger: log)
            log("Using cookies from \(session.sourceLabel)")
            let snapshot = try await self.fetchWithCookieHeader(session.cookieHeader)

            // SUCCESS: Save cookies to fallback store for future use
            await AugmentSessionStore.shared.setCookies(session.cookies)
            log("Saved session cookies to fallback store")
            CookieHeaderCache.store(
                provider: .augment,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)

            return snapshot
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("Browser cookie import failed: \(error.localizedDescription)")
        }

        // Fall back to stored session cookies (from previous successful fetch or "Add Account" login flow)
        let storedCookies = await AugmentSessionStore.shared.getCookies()
        if !storedCookies.isEmpty {
            log("Using stored session cookies")
            let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            do {
                return try await self.fetchWithCookieHeader(cookieHeader)
            } catch {
                if case AugmentStatusProbeError.notLoggedIn = error {
                    // Clear only when auth is invalid; keep for transient failures.
                    await AugmentSessionStore.shared.clearCookies()
                    log("Stored session invalid, cleared")
                } else if case AugmentStatusProbeError.sessionExpired = error {
                    await AugmentSessionStore.shared.clearCookies()
                    log("Stored session expired, cleared")
                } else {
                    log("Stored session failed: \(error.localizedDescription)")
                }
            }
        }

        throw AugmentStatusProbeError.noSessionCookie
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> AugmentStatusSnapshot {
        // Fetch credits (required)
        let (creditsResponse, creditsJSON) = try await self.fetchCredits(cookieHeader: cookieHeader)

        // Fetch subscription (optional - provides plan name and billing cycle)
        let subscriptionResult: (AugmentSubscriptionResponse?, String?) = await {
            do {
                let (response, json) = try await self.fetchSubscription(cookieHeader: cookieHeader)
                return (response, json)
            } catch {
                // Subscription API is optional - don't fail the whole fetch if it's unavailable
                return (nil, nil)
            }
        }()

        return self.parseResponse(
            credits: creditsResponse,
            subscription: subscriptionResult.0,
            creditsJSON: creditsJSON,
            subscriptionJSON: subscriptionResult.1)
    }

    private func fetchCredits(cookieHeader: String) async throws -> (AugmentCreditsResponse, String) {
        let url = self.baseURL.appendingPathComponent("/api/credits")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            // Session expired - trigger automatic recovery
            throw AugmentStatusProbeError.sessionExpired
        }

        if httpResponse.statusCode == 403 {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw AugmentStatusProbeError.networkError("HTTP \(httpResponse.statusCode): \(responseBody)")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw AugmentStatusProbeError.networkError("HTTP \(httpResponse.statusCode): \(responseBody)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(AugmentCreditsResponse.self, from: data)
            return (response, rawJSON)
        } catch {
            throw AugmentStatusProbeError.parseFailed("Credits response: \(error.localizedDescription)")
        }
    }

    private func fetchSubscription(cookieHeader: String) async throws -> (AugmentSubscriptionResponse, String) {
        let url = self.baseURL.appendingPathComponent("/api/subscription")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            // Session expired - trigger automatic recovery
            throw AugmentStatusProbeError.sessionExpired
        }

        if httpResponse.statusCode == 403 {
            throw AugmentStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw AugmentStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(AugmentSubscriptionResponse.self, from: data)
            return (response, rawJSON)
        } catch {
            throw AugmentStatusProbeError.parseFailed("Subscription response: \(error.localizedDescription)")
        }
    }

    private func parseResponse(
        credits: AugmentCreditsResponse,
        subscription: AugmentSubscriptionResponse?,
        creditsJSON: String,
        subscriptionJSON: String?) -> AugmentStatusSnapshot
    {
        // Combine both API responses for debugging
        var combinedJSON = "Credits API:\n\(creditsJSON)"
        if let subJSON = subscriptionJSON {
            combinedJSON += "\n\nSubscription API:\n\(subJSON)"
        }

        // Parse billing period end date from ISO8601 string
        let billingCycleEnd: Date? = {
            guard let dateString = subscription?.billingPeriodEnd else { return nil }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: dateString)
        }()

        return AugmentStatusSnapshot(
            creditsRemaining: credits.credits,
            creditsUsed: credits.creditsUsed,
            creditsLimit: credits.creditsLimit,
            billingCycleEnd: billingCycleEnd,
            accountEmail: subscription?.email,
            accountPlan: subscription?.planName,
            rawJSON: combinedJSON)
    }

    /// Debug probe that returns raw API responses
    public func debugRawProbe() async -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== Augment Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let snapshot = try await self.fetch(logger: { msg in lines.append("[log] \(msg)") })
            lines.append("")
            lines.append("Probe Success")
            lines.append("")
            lines.append("Credits Balance:")
            lines.append("  Remaining: \(snapshot.creditsRemaining?.description ?? "nil")")
            lines.append("  Used: \(snapshot.creditsUsed?.description ?? "nil")")
            lines.append("  Limit: \(snapshot.creditsLimit?.description ?? "nil")")
            lines.append("")
            lines.append("Billing Cycle End: \(snapshot.billingCycleEnd?.description ?? "nil")")
            lines.append("Account Email: \(snapshot.accountEmail ?? "nil")")
            lines.append("Account Plan: \(snapshot.accountPlan ?? "nil")")

            if let rawJSON = snapshot.rawJSON {
                lines.append("")
                lines.append("Raw API Response:")
                lines.append(rawJSON)
            }

            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        }
    }

    // MARK: - Dump storage (in-memory ring buffer)

    @MainActor private static var recentDumps: [String] = []

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 { self.recentDumps.removeFirst() }
        self.recentDumps.append(text)
    }

    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Augment probe dumps captured yet." : result
        }
    }
}

#else

// MARK: - Augment (Unsupported)

public enum AugmentStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Augment is only supported on macOS."
    }
}

public struct AugmentStatusSnapshot: Sendable {
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

public struct AugmentStatusProbe: Sendable {
    public init(baseURL: URL = URL(string: "https://app.augmentcode.com")!, timeout: TimeInterval = 15.0) {
        _ = baseURL
        _ = timeout
    }

    public func fetch(cookieHeaderOverride: String? = nil, logger: ((String) -> Void)? = nil)
        async throws -> AugmentStatusSnapshot
    {
        _ = cookieHeaderOverride
        _ = logger
        throw AugmentStatusProbeError.notSupported
    }
}

#endif

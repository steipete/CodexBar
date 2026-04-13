import Foundation

#if os(macOS)
import SweetCookieKit

private let abacusCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.abacus]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Abacus Cookie Importer

public enum AbacusCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["abacus.ai", "apps.abacus.ai"]

    /// Exact cookie names known to carry Abacus session state.
    /// CSRF tokens are deliberately excluded — they are present in anonymous
    /// jars and do not indicate an authenticated session.
    private static let knownSessionCookieNames: Set<String> = [
        "sessionid", "session_id", "session_token",
        "auth_token", "access_token",
    ]

    /// Substrings that indicate a session or auth cookie (applied only when
    /// no exact-name match is found). Deliberately excludes overly broad
    /// patterns like "id" that match analytics/tracking cookies.
    private static let sessionCookieSubstrings = ["session", "auth", "token", "sid", "jwt"]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let log: (String) -> Void = { msg in logger?("[abacus-cookie] \(msg)") }

        for browserSource in abacusCookieImportOrder {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !httpCookies.isEmpty else { continue }

                    // Only accept cookie sets that contain at least one session/auth cookie
                    guard Self.containsSessionCookie(httpCookies) else {
                        let cookieNames = httpCookies.map(\.name).joined(separator: ", ")
                        log("Skipping \(source.label): no session cookie found among [\(cookieNames)]")
                        continue
                    }

                    let cookieNames = httpCookies.map(\.name).joined(separator: ", ")
                    log("Found \(httpCookies.count) cookies in \(source.label): \(cookieNames)")
                    return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AbacusUsageError.noSessionCookie
    }

    /// Returns `true` if the cookie set contains at least one cookie whose name
    /// indicates session or authentication state.  Checks exact known names
    /// first, then falls back to conservative substring matching.
    private static func containsSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let lower = cookie.name.lowercased()
            if self.knownSessionCookieNames.contains(lower) { return true }
            return self.sessionCookieSubstrings.contains { lower.contains($0) }
        }
    }
}

// MARK: - Abacus Usage Snapshot

public struct AbacusUsageSnapshot: Sendable {
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let resetsAt: Date?
    public let planName: String?

    public func toUsageSnapshot() -> UsageSnapshot {
        let percentUsed: Double = if let used = self.creditsUsed, let total = self.creditsTotal, total > 0 {
            (used / total) * 100.0
        } else {
            0
        }

        let resetDesc: String? = if let used = self.creditsUsed, let total = self.creditsTotal {
            "\(Self.formatCredits(used)) / \(Self.formatCredits(total)) credits"
        } else {
            nil
        }

        // Use windowMinutes matching the monthly billing cycle so pace calculation works.
        // Approximate 1 month as 30 days.
        let windowMinutes = 30 * 24 * 60

        let primary = RateWindow(
            usedPercent: percentUsed,
            windowMinutes: windowMinutes,
            resetsAt: self.resetsAt,
            resetDescription: resetDesc)

        let identity = ProviderIdentitySnapshot(
            providerID: .abacus,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}

// MARK: - Abacus Usage Error

public enum AbacusUsageError: LocalizedError, Sendable {
    case noSessionCookie
    case sessionExpired
    case networkError(String)
    case parseFailed(String)
    case unauthorized

    var isAuthRelated: Bool {
        switch self {
        case .unauthorized, .sessionExpired: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Abacus AI session found. Please log in to apps.abacus.ai in \(abacusCookieImportOrder.loginHint)."
        case .sessionExpired:
            "Abacus AI session expired. Please log in again."
        case let .networkError(msg):
            "Abacus AI API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Abacus AI usage: \(msg)"
        case .unauthorized:
            "Unauthorized. Please log in to Abacus AI."
        }
    }
}

// MARK: - Abacus Usage Fetcher

public enum AbacusUsageFetcher {
    private static let computePointsURL =
        URL(string: "https://apps.abacus.ai/api/_getOrganizationComputePoints")!
    private static let billingInfoURL =
        URL(string: "https://apps.abacus.ai/api/_getBillingInfo")!

    public static func fetchUsage(
        cookieHeaderOverride: String? = nil,
        timeout: TimeInterval = 15.0,
        logger: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[abacus] \(msg)") }

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await Self.fetchWithCookieHeader(override, timeout: timeout)
        }

        if let cached = CookieHeaderCache.load(provider: .abacus),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await Self.fetchWithCookieHeader(cached.cookieHeader, timeout: timeout)
            } catch let error as AbacusUsageError {
                switch error {
                case .unauthorized, .sessionExpired:
                    CookieHeaderCache.clear(provider: .abacus)
                default:
                    throw error
                }
            }
        }

        let session: AbacusCookieImporter.SessionInfo
        do {
            session = try AbacusCookieImporter.importSession(logger: log)
            log("Using cookies from \(session.sourceLabel)")
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("Browser cookie import failed: \(error.localizedDescription)")
            throw AbacusUsageError.noSessionCookie
        }

        // API errors after a successful cookie import must propagate directly
        let snapshot = try await Self.fetchWithCookieHeader(session.cookieHeader, timeout: timeout)
        CookieHeaderCache.store(
            provider: .abacus,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return snapshot
    }

    private static func fetchWithCookieHeader(
        _ cookieHeader: String,
        timeout: TimeInterval) async throws -> AbacusUsageSnapshot
    {
        // Fetch compute points (GET) and billing info (POST) concurrently
        async let computePoints = Self.fetchJSON(
            url: self.computePointsURL, method: "GET", cookieHeader: cookieHeader, timeout: timeout)
        async let billingInfo = Self.fetchJSON(
            url: self.billingInfoURL, method: "POST", cookieHeader: cookieHeader, timeout: timeout)

        let cpResult = try await computePoints
        let biResult: [String: Any]
        do {
            biResult = try await billingInfo
        } catch let error as AbacusUsageError where error.isAuthRelated {
            throw error
        } catch {
            biResult = [:]
        }

        return Self.parseResults(computePoints: cpResult, billingInfo: biResult)
    }

    private static func fetchJSON(
        url: URL, method: String, cookieHeader: String, timeout: TimeInterval) async throws -> [String: Any]
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if method == "POST" {
            request.httpBody = "{}".data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AbacusUsageError.networkError("Invalid response from \(url.lastPathComponent)")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AbacusUsageError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AbacusUsageError.networkError("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AbacusUsageError.parseFailed("Invalid JSON from \(url.lastPathComponent)")
        }

        guard root["success"] as? Bool == true,
              let result = root["result"] as? [String: Any]
        else {
            let errorMsg = (root["error"] as? String ?? "Unknown error").lowercased()
            if errorMsg.contains("expired") || errorMsg.contains("session")
                || errorMsg.contains("login") || errorMsg.contains("authenticate")
            {
                throw AbacusUsageError.sessionExpired
            }
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): \(errorMsg)")
        }

        return result
    }

    // MARK: - Parsing

    private static func parseResults(
        computePoints: [String: Any], billingInfo: [String: Any]) -> AbacusUsageSnapshot
    {
        // _getOrganizationComputePoints returns values already in credits (no division needed)
        let totalCredits = Self.double(from: computePoints["totalComputePoints"])
        let creditsLeft = Self.double(from: computePoints["computePointsLeft"])
        let creditsUsed: Double? = if let total = totalCredits, let left = creditsLeft {
            total - left
        } else {
            nil
        }

        // _getBillingInfo returns the exact next billing date and plan tier
        let nextBillingDate = billingInfo["nextBillingDate"] as? String
        let currentTier = billingInfo["currentTier"] as? String

        let resetsAt = Self.parseDate(nextBillingDate)

        return AbacusUsageSnapshot(
            creditsUsed: creditsUsed,
            creditsTotal: totalCredits,
            resetsAt: resetsAt,
            planName: currentTier)
    }

    private static func double(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}

#else

// MARK: - Abacus (Unsupported)

public enum AbacusUsageError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Abacus AI is only supported on macOS."
    }
}

public struct AbacusUsageSnapshot: Sendable {
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

public enum AbacusUsageFetcher {
    public static func fetchUsage(
        cookieHeaderOverride _: String? = nil,
        timeout _: TimeInterval = 15.0,
        logger _: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        throw AbacusUsageError.notSupported
    }
}

#endif

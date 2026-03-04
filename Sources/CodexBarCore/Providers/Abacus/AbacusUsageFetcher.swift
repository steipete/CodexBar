import Foundation

#if os(macOS)
import SweetCookieKit

private let abacusCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.abacus]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Abacus Cookie Importer

public enum AbacusCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["abacus.ai", "apps.abacus.ai"]

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
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if !httpCookies.isEmpty {
                        let cookieNames = httpCookies.map(\.name).joined(separator: ", ")
                        log("Found \(httpCookies.count) cookies in \(source.label): \(cookieNames)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AbacusUsageError.noSessionCookie
    }
}

// MARK: - Abacus Usage Snapshot

public struct AbacusUsageSnapshot: Sendable {
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let last24HoursUsage: Double?
    public let last7DaysUsage: Double?
    public let resetsAt: Date?
    public let planName: String?
    public let accountEmail: String?
    public let accountOrganization: String?

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
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
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
    private static let apiURL = URL(string: "https://apps.abacus.ai/api/v0/describeUser")!

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

        do {
            let session = try AbacusCookieImporter.importSession(logger: log)
            log("Using cookies from \(session.sourceLabel)")
            let snapshot = try await Self.fetchWithCookieHeader(session.cookieHeader, timeout: timeout)
            CookieHeaderCache.store(
                provider: .abacus,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return snapshot
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("Browser cookie import failed: \(error.localizedDescription)")
        }

        throw AbacusUsageError.noSessionCookie
    }

    private static func fetchWithCookieHeader(
        _ cookieHeader: String,
        timeout: TimeInterval) async throws -> AbacusUsageSnapshot
    {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AbacusUsageError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AbacusUsageError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AbacusUsageError.networkError("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try Self.parseResponse(data)
    }

    // MARK: - Manual JSON Parsing (resilient, no Codable)

    private static func parseResponse(_ data: Data) throws -> AbacusUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AbacusUsageError.parseFailed("Invalid JSON")
        }

        guard root["success"] as? Bool == true else {
            let errorMsg = root["error"] as? String ?? "Unknown error"
            throw AbacusUsageError.parseFailed("API returned error: \(errorMsg)")
        }

        guard let result = root["result"] as? [String: Any] else {
            throw AbacusUsageError.parseFailed("Missing 'result' object")
        }

        let email = result["email"] as? String
        let organization = (result["organization"] as? [String: Any])
        let orgName = organization?["name"] as? String
        let subscriptionTier = organization?["subscriptionTier"] as? String
        let lastBilledAt = organization?["lastBilledAt"] as? String

        let computePointInfo = organization?["computePointInfo"] as? [String: Any]
        let currMonthAvailPoints = Self.double(from: computePointInfo?["currMonthAvailPoints"])
        let currMonthUsage = Self.double(from: computePointInfo?["currMonthUsage"])
        let last24HoursUsage = Self.double(from: computePointInfo?["last24HoursUsage"])
        let last7DaysUsage = Self.double(from: computePointInfo?["last7DaysUsage"])

        // Divide all point values by 100 (centi-credits)
        let creditsUsed = currMonthUsage.map { $0 / 100.0 }
        let creditsTotal = currMonthAvailPoints.map { $0 / 100.0 }
        let daily = last24HoursUsage.map { $0 / 100.0 }
        let weekly = last7DaysUsage.map { $0 / 100.0 }

        // Compute reset date: lastBilledAt + 1 calendar month
        let resetsAt: Date? = Self.computeResetDate(from: lastBilledAt)

        return AbacusUsageSnapshot(
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            last24HoursUsage: daily,
            last7DaysUsage: weekly,
            resetsAt: resetsAt,
            planName: subscriptionTier,
            accountEmail: email,
            accountOrganization: orgName)
    }

    private static func double(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func computeResetDate(from isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoString)
        }
        guard let billedAt = date else { return nil }
        return Calendar.current.date(byAdding: .month, value: 1, to: billedAt)
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

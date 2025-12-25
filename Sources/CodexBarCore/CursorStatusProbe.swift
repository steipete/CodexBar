import Foundation
import os.log

// MARK: - Cursor Cookie Importer

/// Imports Cursor session cookies from Safari/Chrome browsers
public enum CursorCookieImporter {
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

    /// Attempts to import Cursor cookies from Safari first, then Chrome
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }

        // Try Safari first
        do {
            let safariRecords = try SafariCookieImporter.loadCookies(
                matchingDomains: ["cursor.com"],
                logger: log)
            if !safariRecords.isEmpty {
                let httpCookies = SafariCookieImporter.makeHTTPCookies(safariRecords)
                log("Found \(httpCookies.count) Cursor cookies in Safari")
                return SessionInfo(cookies: httpCookies, sourceLabel: "Safari")
            }
        } catch {
            log("Safari cookie import failed: \(error.localizedDescription)")
        }

        // Try Chrome
        do {
            let chromeSources = try ChromeCookieImporter.loadCookiesFromAllProfiles(
                matchingDomains: ["cursor.com"])
            for source in chromeSources {
                if !source.records.isEmpty {
                    let httpCookies = source.records.compactMap { record -> HTTPCookie? in
                        // Chrome uses hostKey instead of domain
                        let domain = record.hostKey.hasPrefix(".") ? String(record.hostKey.dropFirst()) : record.hostKey
                        var props: [HTTPCookiePropertyKey: Any] = [
                            .domain: domain,
                            .path: record.path,
                            .name: record.name,
                            .value: record.value,
                            .secure: record.isSecure,
                        ]
                        if record.isHTTPOnly {
                            props[.init("HttpOnly")] = "TRUE"
                        }
                        // Chrome expiresUTC is in microseconds since 1601-01-01
                        if record.expiresUTC > 0 {
                            // Convert Chrome timestamp to Unix timestamp
                            let unixTimestamp = Double(record.expiresUTC - 11_644_473_600_000_000) / 1_000_000
                            props[.expires] = Date(timeIntervalSince1970: unixTimestamp)
                        }
                        return HTTPCookie(properties: props)
                    }
                    log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                    return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                }
            }
        } catch {
            log("Chrome cookie import failed: \(error.localizedDescription)")
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
        rawJSON: String?)
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
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: Plan usage percentage
        let primary = RateWindow(
            usedPercent: self.planPercentUsed,
            windowMinutes: nil,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })

        // Secondary: On-demand usage as percentage of team limit (if applicable)
        let secondary: RateWindow? = if let teamLimit = self.teamOnDemandLimitUSD,
                                         teamLimit > 0,
                                         let teamUsed = self.teamOnDemandUsedUSD
        {
            RateWindow(
                usedPercent: (teamUsed / teamLimit) * 100,
                windowMinutes: nil,
                resetsAt: self.billingCycleEnd,
                resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })
        } else {
            nil
        }

        // Provider cost snapshot for on-demand usage
        let providerCost: ProviderCostSnapshot? = if self.onDemandUsedUSD > 0 || (self.teamOnDemandUsedUSD ?? 0) > 0 {
            ProviderCostSnapshot(
                used: self.onDemandUsedUSD,
                limit: self.onDemandLimitUSD ?? self.teamOnDemandLimitUSD ?? 0,
                currencyCode: "USD",
                period: "monthly",
                resetsAt: self.billingCycleEnd,
                updatedAt: Date())
        } else {
            nil
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: providerCost,
            updatedAt: Date(),
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.membershipType.map { Self.formatMembershipType($0) })
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
            "No Cursor session found. Please log in to cursor.com in Safari or Chrome."
        }
    }
}

// MARK: - Cursor Session Store

public actor CursorSessionStore {
    public static let shared = CursorSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cursor-session.json")

        // Load saved cookies on init
        Task { await self.loadFromDisk() }
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.sessionCookies = cookies
        self.saveToDisk()
    }

    public func getCookies() -> [HTTPCookie] {
        self.sessionCookies
    }

    public func clearCookies() {
        self.sessionCookies = []
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public func hasValidSession() -> Bool {
        !self.sessionCookies.isEmpty
    }

    private func saveToDisk() {
        let cookieData = self.sessionCookies.compactMap { cookie -> [String: Any]? in
            cookie.properties as? [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cookieData, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: self.fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.fileURL),
              let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        self.sessionCookies = cookieArray.compactMap { props in
            HTTPCookie(properties: props.compactMapValues { value -> Any? in
                // Convert string keys to HTTPCookiePropertyKey
                value
            } as? [HTTPCookiePropertyKey: Any] ?? [:])
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

    /// Fetch Cursor usage using browser cookies (Safari/Chrome) with fallback to stored session
    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }

        // Try importing cookies from Safari/Chrome first
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
                // Clear invalid stored cookies
                await CursorSessionStore.shared.clearCookies()
                log("Stored session invalid, cleared")
            }
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        async let usageSummaryTask = self.fetchUsageSummary(cookieHeader: cookieHeader)
        async let userInfoTask = self.fetchUserInfo(cookieHeader: cookieHeader)

        let usageSummary = try await usageSummaryTask
        let userInfo = try? await userInfoTask

        return self.parseUsageSummary(usageSummary, userInfo: userInfo)
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
            throw CursorStatusProbeError.parseFailed("JSON decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
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

    private func parseUsageSummary(_ summary: CursorUsageSummary, userInfo: CursorUserInfo?) -> CursorStatusSnapshot {
        // Parse billing cycle end date
        let billingCycleEnd: Date? = summary.billingCycleEnd.flatMap { dateString in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }

        // Convert cents to USD
        let planUsed = Double(summary.individualUsage?.plan?.used ?? 0) / 100.0
        let planLimit = Double(summary.individualUsage?.plan?.limit ?? 0) / 100.0
        let planPercentUsed = summary.individualUsage?.plan?.totalPercentUsed
            ?? (planLimit > 0 ? (planUsed / planLimit) * 100 : 0)

        let onDemandUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimit: Double? = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let teamOnDemandUsed: Double? = summary.teamUsage?.onDemand?.used.map { Double($0) / 100.0 }
        let teamOnDemandLimit: Double? = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100.0 }

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
            rawJSON: nil)
    }
}


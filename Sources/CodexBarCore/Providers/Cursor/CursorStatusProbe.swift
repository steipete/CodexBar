import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SweetCookieKit
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if os(macOS) || os(Linux)

#if os(macOS)
private let cursorCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder
#endif

#if os(macOS)

// MARK: - Cursor Cookie Importer

/// Imports Cursor session cookies from browser cookies.
public enum CursorCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        // WorkOS AuthKit (common default; configurable server-side)
        "wos-session",
        "__Secure-wos-session",
        // Auth.js v5
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    /// Hosts whose cookies may authenticate Cursor web/API requests.
    private static let cookieDomains = [
        "cursor.com",
        "www.cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
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

    /// Reads Cursor session cookies from one browser if present (no fallback to other browsers).
    static func importSessionIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        self.importSessionsIfPresent(
            browser: browser,
            browserDetection: browserDetection,
            logger: logger).first
    }

    /// Reads all Cursor session-cookie candidates from one browser source order.
    static func importSessionsIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        self.importCookiesFromBrowser(
            browser: browser,
            browserDetection: browserDetection,
            requireKnownSessionName: true,
            logger: logger)
    }

    /// Like ``importSessionIfPresent`` but accepts any non-empty cookie set for Cursor domains so the API can validate
    /// (used after the strict name pass fails — e.g. new cookie names or host-only cookies).
    static func importDomainCookiesIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        self.importDomainCookieSessionsIfPresent(
            browser: browser,
            browserDetection: browserDetection,
            logger: logger).first
    }

    /// Reads fallback cookie candidates whose names are not already covered by the strict session-cookie pass.
    static func importDomainCookieSessionsIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        self.importCookiesFromBrowser(
            browser: browser,
            browserDetection: browserDetection,
            requireKnownSessionName: false,
            logger: logger)
    }

    private static func importCookiesFromBrowser(
        browser: Browser,
        browserDetection: BrowserDetection,
        requireKnownSessionName: Bool,
        logger: ((String) -> Void)?) -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        guard browserDetection.isCookieSourceAvailable(browser) else { return [] }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }

        do {
            let query = BrowserCookieQuery(domains: Self.cookieDomains)
            let sources = try Self.cookieClient.codexBarRecords(
                matching: query,
                in: browser,
                logger: log)
            var sessions: [SessionInfo] = []
            for source in sources where !source.records.isEmpty {
                let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let hasNamedSession = httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) })
                if hasNamedSession {
                    log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                    if requireKnownSessionName {
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    }
                    continue
                }
                if !requireKnownSessionName, !httpCookies.isEmpty {
                    log(
                        "Found \(httpCookies.count) Cursor domain cookies in \(source.label) "
                            + "(no known session name); will validate via API")
                    sessions.append(SessionInfo(
                        cookies: httpCookies,
                        sourceLabel: "\(source.label) (domain cookies)"))
                    continue
                }
                log("\(source.label) cookies found, but no Cursor session cookie present")
            }
            return sessions
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
        }
        return []
    }

    /// Attempts to import Cursor cookies using the standard browser import order.
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let installedBrowsers = cursorCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
            if let session = Self.importSessionsIfPresent(
                browser: browserSource,
                browserDetection: browserDetection,
                logger: logger).first
            {
                return session
            }
        }
        for browserSource in installedBrowsers {
            if let session = Self.importDomainCookieSessionsIfPresent(
                browser: browserSource,
                browserDetection: browserDetection,
                logger: logger).first
            {
                return session
            }
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    /// Check if Cursor session cookies are available
    public static func hasSession(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(browserDetection: browserDetection, logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}
#endif

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
    /// Enterprise / team-member personal cap. Reported by Cursor when the account is part of a team or
    /// enterprise plan with an individual quota. Values follow the same cents-based units as `plan`.
    public let overall: CursorOverallUsage?

    public init(
        plan: CursorPlanUsage? = nil,
        onDemand: CursorOnDemandUsage? = nil,
        overall: CursorOverallUsage? = nil)
    {
        self.plan = plan
        self.onDemand = onDemand
        self.overall = overall
    }
}

/// Personal cap reported under `individualUsage.overall` for Enterprise/Team members.
/// Mirrors the shape of `CursorOnDemandUsage`; values are in cents.
public struct CursorOverallUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents (e.g., 7384 = $73.84)
    public let used: Int?
    /// Limit in cents (e.g., 10000 = $100.00). `nil` indicates the API omitted a numeric cap.
    public let limit: Int?
    /// Remaining in cents.
    public let remaining: Int?

    public init(enabled: Bool? = nil, used: Int? = nil, limit: Int? = nil, remaining: Int? = nil) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }
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
    /// Shared team/enterprise pool counted across all members. Same cents-based units as the other usage blocks.
    public let pooled: CursorPooledUsage?

    public init(onDemand: CursorOnDemandUsage? = nil, pooled: CursorPooledUsage? = nil) {
        self.onDemand = onDemand
        self.pooled = pooled
    }
}

/// Shared team/enterprise pool reported under `teamUsage.pooled`. Values are in cents.
public struct CursorPooledUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Pool usage in cents.
    public let used: Int?
    /// Pool limit in cents. `nil` indicates an unlimited or unreported pool.
    public let limit: Int?
    /// Pool remaining in cents.
    public let remaining: Int?

    public init(enabled: Bool? = nil, used: Int? = nil, limit: Int? = nil, remaining: Int? = nil) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }
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

// MARK: - Cursor Dashboard Usage Events (Cloud Agent Attribution)

/// Response from `POST /api/dashboard/get-filtered-usage-events`.
public struct CursorFilteredUsageEventsResponse: Codable, Sendable {
    public let totalUsageEventsCount: Int?
    public let usageEventsDisplay: [CursorUsageEvent]?
}

/// One usage event from the Cursor dashboard usage list.
/// Cloud agent runs are tagged with `cloudAgentId` and/or `isHeadless == true`.
public struct CursorUsageEvent: Codable, Sendable {
    public let timestamp: String?
    public let model: String?
    public let kind: String?
    public let chargedCents: Double?
    public let isChargeable: Bool?
    public let isHeadless: Bool?
    public let cloudAgentId: String?
    public let tokenUsage: CursorUsageEventTokenUsage?
}

public struct CursorUsageEventTokenUsage: Codable, Sendable {
    public let totalCents: Double?
}

enum CursorCloudAgentUsageAggregator {
    static func aggregate(events: [CursorUsageEvent]) -> CursorCloudAgentUsage {
        var cloudCents = 0.0
        var totalCents = 0.0
        var cloudEvents = 0
        for event in events {
            if event.isChargeable == false {
                continue
            }
            // Skip non-charged error/abort events so the share matches dashboard billable spend.
            if let kind = event.kind, Self.nonChargedKinds.contains(kind) {
                continue
            }
            let cents = event.chargedCents
                ?? event.tokenUsage?.totalCents
                ?? 0
            guard cents > 0 else { continue }
            totalCents += cents
            if Self.isCloudAgentEvent(event) {
                cloudCents += cents
                cloudEvents += 1
            }
        }
        return CursorCloudAgentUsage(
            usedUSD: cloudCents / 100.0,
            totalSpendUSD: totalCents / 100.0,
            eventCount: cloudEvents)
    }

    static func isCloudAgentEvent(_ event: CursorUsageEvent) -> Bool {
        if let id = event.cloudAgentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return true
        }
        return event.isHeadless == true
    }

    private static let nonChargedKinds: Set<String> = [
        "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED",
        "USAGE_EVENT_KIND_ABORTED_NOT_CHARGED",
    ]
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

// MARK: - Cursor App Auth

struct CursorAppAuthSession: Equatable {
    let accessToken: String

    var isUsable: Bool {
        guard !self.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? self.userID()) != nil,
              let expiresAt = try? self.expiresAt()
        else {
            return false
        }
        return expiresAt.timeIntervalSinceNow > 60
    }

    func cookieHeader() throws -> String {
        try "WorkosCursorSessionToken=\(self.userID())%3A%3A\(self.accessToken)"
    }

    func userID() throws -> String {
        let json = try self.payload()
        guard let subject = json["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is missing a user ID")
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token has an invalid user ID")
        }

        return userID
    }

    private func expiresAt() throws -> Date {
        let json = try self.payload()
        guard let expiration = json["exp"] as? NSNumber else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is missing an expiration")
        }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }

    private func payload() throws -> [String: Any] {
        let parts = self.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is not a JWT")
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token has an invalid payload")
        }

        return json
    }
}

protocol CursorAppAuthSessionProviding: Sendable {
    func loadSession() throws -> CursorAppAuthSession?
}

struct CursorAppAuthStore: CursorAppAuthSessionProviding {
    private static let defaultDBPath: String = Self.resolveDefaultDBPath()

    private let dbPath: String

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? Self.defaultDBPath
    }

    static func resolveDefaultDBPath(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> String
    {
        #if os(macOS)
        _ = environment
        _ = fileManager
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        #elseif os(Linux)
        let configHome = environment[CodexBarConfigStore.xdgConfigHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedConfigHome = configHome.map { ($0 as NSString).expandingTildeInPath }
        let base: String = if let expandedConfigHome,
                              !expandedConfigHome.isEmpty,
                              (expandedConfigHome as NSString).isAbsolutePath
        {
            expandedConfigHome
        } else {
            "\(home)/.config"
        }
        return "\(base)/Cursor/User/globalStorage/state.vscdb"
        #else
        _ = home
        _ = environment
        _ = fileManager
        return ""
        #endif
    }

    func loadSession() throws -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: self.dbPath) else { return nil }

        guard let accessToken = try self.value(for: "cursorAuth/accessToken"),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return CursorAppAuthSession(accessToken: accessToken)
    }

    private func value(for key: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CursorStatusProbeError.networkError("SQLite error reading Cursor app auth: \(message)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw CursorStatusProbeError.networkError("SQLite error preparing Cursor app auth read: \(message)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_ROW else {
            if stepResult == SQLITE_DONE { return nil }
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw CursorStatusProbeError.networkError("SQLite error reading Cursor app auth: \(message)")
        }

        return Self.decodeSQLiteValue(stmt: stmt, index: 0)
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Cursor Status Snapshot

public struct CursorStatusSnapshot: Sendable {
    /// Percentage of included plan usage (0-100) — the "Total" headline number from Cursor's UI
    public let planPercentUsed: Double
    /// Auto + Composer usage percent (0-100), nil when not available
    public let autoPercentUsed: Double?
    /// API (named model) usage percent (0-100), nil when not available
    public let apiPercentUsed: Double?
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
    /// Billing cycle start date
    public let billingCycleStart: Date?
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
    /// Cloud agent spend attribution for the current billing cycle (nil when unavailable).
    public let cloudAgentUsage: CursorCloudAgentUsage?

    /// Whether this is a legacy request-based plan (vs token-based)
    public var isLegacyRequestPlan: Bool {
        self.requestsLimit != nil
    }

    public init(
        planPercentUsed: Double,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        planUsedUSD: Double,
        planLimitUSD: Double,
        onDemandUsedUSD: Double,
        onDemandLimitUSD: Double?,
        teamOnDemandUsedUSD: Double?,
        teamOnDemandLimitUSD: Double?,
        billingCycleStart: Date? = nil,
        billingCycleEnd: Date?,
        membershipType: String?,
        accountEmail: String?,
        accountName: String?,
        rawJSON: String?,
        requestsUsed: Int? = nil,
        requestsLimit: Int? = nil,
        cloudAgentUsage: CursorCloudAgentUsage? = nil)
    {
        self.planPercentUsed = planPercentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.planUsedUSD = planUsedUSD
        self.planLimitUSD = planLimitUSD
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandLimitUSD = onDemandLimitUSD
        self.teamOnDemandUsedUSD = teamOnDemandUsedUSD
        self.teamOnDemandLimitUSD = teamOnDemandLimitUSD
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.membershipType = membershipType
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.rawJSON = rawJSON
        self.requestsUsed = requestsUsed
        self.requestsLimit = requestsLimit
        self.cloudAgentUsage = cloudAgentUsage
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        let cursorRequests: CursorRequestUsage? = if let used = self.requestsUsed,
                                                     let limit = self.requestsLimit,
                                                     limit > 0
        {
            CursorRequestUsage(used: used, limit: limit)
        } else {
            nil
        }

        // Primary: For usable legacy request quotas, use request usage; otherwise preserve plan percentage.
        let primaryUsedPercent = cursorRequests?.usedPercent ?? self.planPercentUsed

        let billingCycleWindowMinutes = Self.billingCycleWindowMinutes(
            start: self.billingCycleStart,
            end: self.billingCycleEnd)

        let primary = RateWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: billingCycleWindowMinutes,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })

        // Secondary: Auto + Composer usage (shown as its own bar below Total).
        // Legacy request-based plans don't have the token-based Auto/API breakdown — those percentages
        // come from the new usage-based pricing and are meaningless next to a request quota, so hide them.
        let secondary: RateWindow? = cursorRequests != nil ? nil : self.autoPercentUsed.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: billingCycleWindowMinutes,
                resetsAt: self.billingCycleEnd,
                resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })
        }

        // Tertiary: API (named model) usage — hidden for legacy request-based plans (see above).
        let tertiary: RateWindow? = cursorRequests != nil ? nil : self.apiPercentUsed.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: billingCycleWindowMinutes,
                resetsAt: self.billingCycleEnd,
                resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })
        }

        // Prefer a personal cap. Team accounts with no user cap expose only the shared on-demand budget.
        let resolvedOnDemandUsed: Double
        let resolvedOnDemandLimit: Double?
        if (self.onDemandLimitUSD ?? 0) > 0 {
            resolvedOnDemandUsed = self.onDemandUsedUSD
            resolvedOnDemandLimit = self.onDemandLimitUSD
        } else if (self.teamOnDemandLimitUSD ?? 0) > 0 {
            resolvedOnDemandUsed = self.teamOnDemandUsedUSD ?? 0
            resolvedOnDemandLimit = self.teamOnDemandLimitUSD
        } else {
            resolvedOnDemandUsed = self.onDemandUsedUSD
            resolvedOnDemandLimit = self.onDemandLimitUSD
        }

        // Your own on-demand spend to surface alongside a shared team pool (nil when the budget is personal).
        let personalOnDemandUsed: Double? = if (self.onDemandLimitUSD ?? 0) > 0 {
            nil
        } else if (self.teamOnDemandLimitUSD ?? 0) > 0 {
            self.onDemandUsedUSD > 0 ? self.onDemandUsedUSD : nil
        } else {
            nil
        }

        // Provider cost snapshot for on-demand usage (include budget before first spend)
        let providerCost: ProviderCostSnapshot? = if resolvedOnDemandUsed > 0
            || (resolvedOnDemandLimit ?? 0) > 0
        {
            ProviderCostSnapshot(
                used: resolvedOnDemandUsed,
                limit: resolvedOnDemandLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: self.billingCycleEnd,
                personalUsed: personalOnDemandUsed,
                updatedAt: Date())
        } else {
            nil
        }

        // Cloud agents draw from the same plan/API/on-demand pools as local usage. Surface them as an
        // attribution bar (share of this cycle's spend) when the dashboard reports any cloud spend.
        let extraRateWindows: [NamedRateWindow]? = {
            guard let cloud = self.cloudAgentUsage, cloud.usedUSD > 0, cloud.totalSpendUSD > 0 else {
                return nil
            }
            return [
                NamedRateWindow(
                    id: CursorCloudAgentUsage.windowID,
                    title: CursorCloudAgentUsage.windowTitle,
                    window: RateWindow(
                        usedPercent: cloud.usedPercent,
                        windowMinutes: billingCycleWindowMinutes,
                        resetsAt: self.billingCycleEnd,
                        resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })),
            ]
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .cursor,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.membershipType.map { Self.formatMembershipType($0) })
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            cursorRequests: cursorRequests,
            cursorCloudAgentUsage: self.cloudAgentUsage,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }

    private static func billingCycleWindowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start,
              let end
        else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
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

    static let safariFullDiskAccessHint =
        "If you use Safari, grant CodexBar Full Disk Access in System Settings ▸ Privacy & Security."

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            #if os(macOS)
            "Not logged in to Cursor. Please log in via the CodexBar menu."
            #else
            "Not logged in to Cursor. Sign in to the Cursor app on this machine or paste a Cookie header copied "
                + "from cursor.com into ~/.config/codexbar/config.json (legacy: ~/.codexbar/config.json)."
            #endif
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Cursor usage: \(msg)"
        case .noSessionCookie:
            #if os(macOS)
            "No Cursor session found. \(Self.safariFullDiskAccessHint) "
                + "Please log in to cursor.com in \(cursorCookieImportOrder.loginHint). "
                + "You can also sign in to Cursor from the CodexBar menu (Add / switch account)."
            #else
            "No Cursor session found. Sign in to the Cursor app on this machine or paste a Cookie header copied "
                + "from cursor.com into ~/.config/codexbar/config.json (legacy: ~/.codexbar/config.json)."
            #endif
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
    private let browserDetection: BrowserDetection
    private let browserCookieImportOrder: BrowserCookieImportOrder
    private let urlSession: any ProviderHTTPTransport
    private let appAuthStore: any CursorAppAuthSessionProviding

    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.init(
            baseURL: baseURL,
            timeout: timeout,
            browserDetection: browserDetection,
            browserCookieImportOrder: Self.defaultBrowserCookieImportOrder,
            urlSession: urlSession,
            appAuthStore: CursorAppAuthStore())
    }

    init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        browserCookieImportOrder: BrowserCookieImportOrder = Self.defaultBrowserCookieImportOrder,
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        appAuthStore: any CursorAppAuthSessionProviding)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
        self.browserCookieImportOrder = browserCookieImportOrder
        self.urlSession = urlSession
        self.appAuthStore = appAuthStore
    }

    /// Fetch Cursor usage using a first-party web session derived from Cursor.app's access token.
    func fetchWithAppAuthSession(_ session: CursorAppAuthSession) async throws -> CursorStatusSnapshot {
        try await self.fetchWithCookieHeader(
            session.cookieHeader(),
            requestUsageUserIDFallback: session.userID())
    }

    /// Fetch Cursor usage with manual cookie header (for debugging).
    public func fetchWithManualCookies(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        try await self.fetchWithCookieHeader(cookieHeader)
    }

    /// Fetch Cursor usage using browser cookies with fallback to stored session.
    public func fetch(
        cookieHeaderOverride: String? = nil,
        allowCachedSessions: Bool = true,
        allowAppAuthFallback: Bool = true,
        logger: ((String) -> Void)? = nil)
        async throws -> CursorStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var firstRecoverableError: CursorStatusProbeError?

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(provider: .cursor),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.fetchWithCookieHeader(cached.cookieHeader)
            } catch let error as CursorStatusProbeError {
                if case .notLoggedIn = error {
                    CookieHeaderCache.clear(provider: .cursor)
                } else {
                    throw error
                }
            } catch {
                throw error
            }
        }

        #if os(macOS)
        // Try each browser in order. The first browser that *has* session cookie names is not always valid
        // (e.g. stale Chrome tokens); keep trying until the API accepts a session or we run out of browsers.
        let browserCandidates = self.browserCookieImportOrder.cookieImportCandidates(using: self.browserDetection)
        switch await self.scanBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                await self.fetchIfSessionAccepted(session, log: log)
            })
        {
        case let .succeeded(snapshot):
            return snapshot
        case let .exhausted(error):
            firstRecoverableError = error ?? firstRecoverableError
        }

        switch await self.scanBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importDomainCookieSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                await self.fetchIfSessionAccepted(session, log: log)
            })
        {
        case let .succeeded(snapshot):
            return snapshot
        case let .exhausted(error):
            firstRecoverableError = error ?? firstRecoverableError
        }
        #endif

        // Fall back to stored session cookies (from "Add Account" login flow)
        if allowCachedSessions {
            let storedCookies = await CursorSessionStore.shared.getCookies()
            if !storedCookies.isEmpty {
                log("Using stored session cookies")
                let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                do {
                    return try await self.fetchWithCookieHeader(cookieHeader)
                } catch let error as CursorStatusProbeError {
                    if case .notLoggedIn = error {
                        // Clear only when auth is invalid; keep for transient failures.
                        await CursorSessionStore.shared.clearCookies()
                        log("Stored session invalid, cleared")
                    } else {
                        log("Stored session failed: \(error.localizedDescription)")
                        firstRecoverableError = firstRecoverableError ?? error
                    }
                } catch {
                    log("Stored session failed: \(error.localizedDescription)")
                    firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
                }
            }
        }

        // A transient failure for an explicitly selected session must not switch to Cursor.app's account.
        if let firstRecoverableError {
            throw firstRecoverableError
        }

        // Last fallback: derive Cursor's first-party web session from the app token in its global state DB.
        // Reusing the web flow preserves modern billing, legacy request quotas, and account-scoped identity.
        if allowAppAuthFallback,
           let appSession = try? self.appAuthStore.loadSession(),
           appSession.isUsable
        {
            log("Using Cursor.app local auth fallback")
            do {
                return try await self.fetchWithAppAuthSession(appSession)
            } catch let error as CursorStatusProbeError {
                if case .notLoggedIn = error {
                    log("Cursor.app local auth was rejected")
                } else {
                    firstRecoverableError = firstRecoverableError ?? error
                }
            } catch {
                firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    #if os(macOS)
    enum ImportedSessionFetchOutcome {
        case succeeded(CursorStatusSnapshot)
        case tryNextBrowser
        case failed(CursorStatusProbeError)
    }

    enum ImportedSessionScanResult {
        case succeeded(CursorStatusSnapshot)
        case exhausted(CursorStatusProbeError?)
    }

    func scanBrowsers(
        _ browsers: [Browser],
        importSessions: (Browser) -> [CursorCookieImporter.SessionInfo],
        attemptFetch: (CursorCookieImporter.SessionInfo) async -> ImportedSessionFetchOutcome) async
        -> ImportedSessionScanResult
    {
        var firstFailure: CursorStatusProbeError?

        for browser in browsers {
            let sessions = importSessions(browser)
            guard !sessions.isEmpty else { continue }
            for session in sessions {
                switch await attemptFetch(session) {
                case let .succeeded(snapshot):
                    return .succeeded(snapshot)
                case .tryNextBrowser:
                    continue
                case let .failed(error):
                    firstFailure = firstFailure ?? error
                }
            }
        }

        return .exhausted(firstFailure)
    }

    func scanImportedSessions(
        _ sessions: [CursorCookieImporter.SessionInfo],
        attemptFetch: (CursorCookieImporter.SessionInfo) async -> ImportedSessionFetchOutcome) async
        -> ImportedSessionScanResult
    {
        var firstFailure: CursorStatusProbeError?

        for session in sessions {
            switch await attemptFetch(session) {
            case let .succeeded(snapshot):
                return .succeeded(snapshot)
            case .tryNextBrowser:
                continue
            case let .failed(error):
                firstFailure = firstFailure ?? error
            }
        }

        return .exhausted(firstFailure)
    }

    private func fetchIfSessionAccepted(
        _ session: CursorCookieImporter.SessionInfo,
        log: @escaping (String) -> Void) async -> ImportedSessionFetchOutcome
    {
        log("Trying Cursor session from \(session.sourceLabel)")
        do {
            let snapshot = try await self.fetchWithCookieHeader(session.cookieHeader)
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return .succeeded(snapshot)
        } catch let error as CursorStatusProbeError {
            if case .notLoggedIn = error {
                log("Cursor API rejected cookies from \(session.sourceLabel); trying next browser if any")
                return .tryNextBrowser
            }
            log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
            return .failed(error)
        } catch {
            log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
            return .failed(.networkError(error.localizedDescription))
        }
    }
    #endif

    private func fetchWithCookieHeader(
        _ cookieHeader: String,
        requestUsageUserIDFallback: String? = nil) async throws -> CursorStatusSnapshot
    {
        enum FetchPart: Sendable {
            case usageSummary((CursorUsageSummary, String))
            case userInfo(Result<CursorUserInfo, Error>)
        }

        var usageSummaryResult: (CursorUsageSummary, String)?
        var userInfo: CursorUserInfo?

        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask {
                try await .usageSummary(self.fetchUsageSummary(cookieHeader: cookieHeader))
            }
            group.addTask {
                do {
                    return try await .userInfo(.success(self.fetchUserInfo(cookieHeader: cookieHeader)))
                } catch {
                    return .userInfo(.failure(error))
                }
            }

            while let result = try await group.next() {
                switch result {
                case let .usageSummary(value):
                    usageSummaryResult = value
                case let .userInfo(value):
                    userInfo = try? value.get()
                }
            }
        }

        guard let usageSummaryResult else {
            throw CursorStatusProbeError.networkError("Cursor usage summary fetch did not complete")
        }

        let (usageSummary, rawJSON) = usageSummaryResult

        // Fetch legacy request usage only if user has a sub ID.
        // Uses try? to avoid breaking the flow for users where this endpoint fails or returns unexpected data.
        var requestUsage: CursorUsageResponse?
        var requestUsageRawJSON: String?
        if let userId = userInfo?.sub ?? requestUsageUserIDFallback {
            do {
                let (usage, usageRawJSON) = try await self.fetchRequestUsage(userId: userId, cookieHeader: cookieHeader)
                requestUsage = usage
                requestUsageRawJSON = usageRawJSON
            } catch {
                // Silently ignore - not all plans have this endpoint
            }
        }

        // Cloud agent spend attribution is optional: never fail the primary usage-summary path when
        // the dashboard events endpoint is unavailable or returns unexpected data.
        var cloudAgentUsage: CursorCloudAgentUsage?
        var cloudAgentRawJSON: String?
        do {
            let (cloud, cloudJSON) = try await self.fetchCloudAgentUsage(
                cookieHeader: cookieHeader,
                billingCycleStart: usageSummary.billingCycleStart,
                billingCycleEnd: usageSummary.billingCycleEnd)
            cloudAgentUsage = cloud
            cloudAgentRawJSON = cloudJSON
        } catch {
            // Best-effort only.
        }

        // Combine raw JSON for debugging
        var combinedRawJSON: String? = rawJSON
        if let usageJSON = requestUsageRawJSON {
            combinedRawJSON = (combinedRawJSON ?? "") + "\n\n--- /api/usage response ---\n" + usageJSON
        }
        if let cloudJSON = cloudAgentRawJSON {
            combinedRawJSON = (combinedRawJSON ?? "") + "\n\n--- cloud agent usage ---\n" + cloudJSON
        }

        return self.parseUsageSummary(
            usageSummary,
            userInfo: userInfo,
            rawJSON: combinedRawJSON,
            requestUsage: requestUsage,
            cloudAgentUsage: cloudAgentUsage)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws -> (CursorUsageSummary, String) {
        let url = self.baseURL.appendingPathComponent("/api/usage-summary")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CursorStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"

        do {
            let decoder = JSONDecoder()
            let summary = try decoder.decode(CursorUsageSummary.self, from: data)
            return (summary, rawJSON)
        } catch {
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

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch user info")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CursorUserInfo.self, from: data)
    }

    private func fetchRequestUsage(
        userId: String,
        cookieHeader: String) async throws -> (CursorUsageResponse, String)
    {
        let url = self.baseURL.appendingPathComponent("/api/usage")
            .appending(queryItems: [URLQueryItem(name: "user", value: userId)])
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch request usage")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CursorUsageResponse.self, from: data)
        return (usage, rawJSON)
    }

    /// Fetches dashboard usage events for the billing cycle and aggregates Cloud Agent spend.
    /// Uses POST with a browser-like Origin so Cursor accepts the state-changing dashboard route.
    private func fetchCloudAgentUsage(
        cookieHeader: String,
        billingCycleStart: String?,
        billingCycleEnd: String?) async throws -> (CursorCloudAgentUsage, String)
    {
        let events = try await self.fetchFilteredUsageEvents(
            cookieHeader: cookieHeader,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd)
        let usage = CursorCloudAgentUsageAggregator.aggregate(events: events)
        let summaryJSON = [
            #""cloudAgentUsedUSD":\#(usage.usedUSD)"#,
            #""totalSpendUSD":\#(usage.totalSpendUSD)"#,
            #""eventCount":\#(usage.eventCount)"#,
        ].joined(separator: ",")
        return (usage, "{\(summaryJSON)}")
    }

    private func fetchFilteredUsageEvents(
        cookieHeader: String,
        billingCycleStart: String?,
        billingCycleEnd: String?) async throws -> [CursorUsageEvent]
    {
        let url = self.baseURL.appendingPathComponent("/api/dashboard/get-filtered-usage-events")
        var allEvents: [CursorUsageEvent] = []
        var page = 1
        let pageSize = 500
        var totalCount: Int?

        let startMs = Self.billingCycleMillisecondsString(billingCycleStart)
        let endMs = Self.billingCycleMillisecondsString(billingCycleEnd)

        let maximumPages = 20
        while page <= maximumPages {
            var body: [String: Any] = [
                // Cursor's dashboard uses teamId 0 for the signed-in user's individual usage.
                // Omitting it can return team-scoped rows for team/business accounts.
                "teamId": 0,
                "pageSize": pageSize,
                "page": page,
            ]
            if let startMs {
                body["startDate"] = startMs
            }
            if let endMs {
                body["endDate"] = endMs
            }

            let payload = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.timeoutInterval = self.timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            // Cursor rejects dashboard POSTs without a first-party Origin.
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")

            let (data, response) = try await self.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CursorStatusProbeError.networkError("Invalid response")
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CursorStatusProbeError.notLoggedIn
            }
            guard httpResponse.statusCode == 200 else {
                throw CursorStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
            }

            let decoded = try JSONDecoder().decode(CursorFilteredUsageEventsResponse.self, from: data)
            let pageEvents = decoded.usageEventsDisplay ?? []
            if totalCount == nil {
                totalCount = decoded.totalUsageEventsCount
            }
            if pageEvents.isEmpty {
                break
            }
            allEvents.append(contentsOf: pageEvents)
            if let totalCount, allEvents.count >= totalCount {
                break
            }
            if totalCount == nil, pageEvents.count < pageSize {
                break
            }
            page += 1
        }

        if let totalCount, allEvents.count < totalCount {
            throw CursorStatusProbeError.networkError(
                "Cursor usage event history exceeds the supported \(maximumPages * pageSize)-event limit")
        }

        return allEvents
    }

    /// Converts an ISO-8601 billing-cycle timestamp into the millisecond epoch string Cursor's
    /// dashboard event filter expects (e.g. `"1781921226000"`).
    static func billingCycleMillisecondsString(_ iso8601: String?) -> String? {
        guard let iso8601 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso8601) ?? {
            let plain = ISO8601DateFormatter()
            return plain.date(from: iso8601)
        }()
        guard let date else { return nil }
        return String(Int((date.timeIntervalSince1970 * 1000).rounded()))
    }

    func parseUsageSummary(
        _ summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        rawJSON: String?,
        requestUsage: CursorUsageResponse? = nil,
        cloudAgentUsage: CursorCloudAgentUsage? = nil) -> CursorStatusSnapshot
    {
        func parseBillingCycleDate(_ dateString: String?) -> Date? {
            guard let dateString else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }
        let billingCycleStart = parseBillingCycleDate(summary.billingCycleStart)
        let billingCycleEnd = parseBillingCycleDate(summary.billingCycleEnd)

        // Convert cents to USD (plan percent derives from raw values to avoid percent unit mismatches).
        // Use plan.limit directly - breakdown.total represents total *used* credits, not the limit.
        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.limit ?? 0)
        func normPct(_ value: Double?) -> Double? {
            guard let v = value else { return nil }
            if v < 0 { return 0 }
            if v > 100 { return 100 }
            return v
        }

        func normalizeTotalPercent(_ v: Double) -> Double {
            max(0, min(100, v))
        }

        // Cursor's usage-summary percent fields are already in percentage units, even when they are fractional
        // values below 1.0 (for example 0.36 means 0.36%, which the dashboard rounds to 0%).
        let autoPercent = normPct(summary.individualUsage?.plan?.autoPercentUsed)
        let apiPercent = normPct(summary.individualUsage?.plan?.apiPercentUsed)

        // Enterprise / team-member personal cap (cents). Reported under `individualUsage.overall` for accounts
        // that don't get a `plan` block. Falls through to existing logic when absent so non-enterprise paths
        // are untouched.
        let overallUsedRaw = (summary.individualUsage?.overall?.used).map(Double.init)
        let overallLimitRaw = (summary.individualUsage?.overall?.limit).map(Double.init)

        // Shared team/enterprise pool (cents). Last-resort fallback when no individual data is available.
        let pooledUsedRaw = (summary.teamUsage?.pooled?.used).map(Double.init)
        let pooledLimitRaw = (summary.teamUsage?.pooled?.limit).map(Double.init)

        // Headline "Total" precedence:
        //   1. `individualUsage.plan.totalPercentUsed` (existing behavior for Pro/Hobby/etc.)
        //   2. averaged `auto` + `api` lane percents (existing behavior)
        //   3. either lane alone (existing behavior)
        //   4. `individualUsage.plan` ratio (existing behavior)
        //   5. NEW: `individualUsage.overall` ratio (Enterprise/Team personal cap)
        //   6. NEW: `teamUsage.pooled` ratio (last resort when no individual data is reported)
        let planPercentUsed: Double = if let totalPercentUsed = summary.individualUsage?.plan?.totalPercentUsed {
            normalizeTotalPercent(totalPercentUsed)
        } else if let autoUsed = autoPercent, let apiUsed = apiPercent {
            max(0, min(100, (autoUsed + apiUsed) / 2))
        } else if let apiUsed = apiPercent {
            max(0, min(100, apiUsed))
        } else if let autoUsed = autoPercent {
            max(0, min(100, autoUsed))
        } else if planLimitRaw > 0 {
            (planUsedRaw / planLimitRaw) * 100
        } else if let used = overallUsedRaw, let limit = overallLimitRaw, limit > 0 {
            normalizeTotalPercent((used / limit) * 100)
        } else if let used = pooledUsedRaw, let limit = pooledLimitRaw, limit > 0 {
            normalizeTotalPercent((used / limit) * 100)
        } else {
            0
        }

        // USD figures: prefer the source the headline ultimately came from. When `plan` is missing but
        // `overall` or `pooled` carry the cents, surface those so the on-demand display and downstream
        // consumers see real dollar amounts instead of zeros.
        let planUsed: Double
        let planLimit: Double
        if planLimitRaw > 0 || planUsedRaw > 0 {
            planUsed = planUsedRaw / 100.0
            planLimit = planLimitRaw / 100.0
        } else if let usedCents = overallUsedRaw, let limitCents = overallLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else if let usedCents = pooledUsedRaw, let limitCents = pooledLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else {
            planUsed = 0
            planLimit = 0
        }

        let onDemandUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimit: Double? = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let teamOnDemandUsed: Double? = summary.teamUsage?.onDemand?.used.map { Double($0) / 100.0 }
        let teamOnDemandLimit: Double? = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        // Legacy request-based plan: maxRequestUsage being non-nil indicates a request-based plan
        let requestsUsed: Int? = requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests
        let requestsLimit: Int? = requestUsage?.gpt4?.maxRequestUsage

        return CursorStatusSnapshot(
            planPercentUsed: planPercentUsed,
            autoPercentUsed: autoPercent,
            apiPercentUsed: apiPercent,
            planUsedUSD: planUsed,
            planLimitUSD: planLimit,
            onDemandUsedUSD: onDemandUsed,
            onDemandLimitUSD: onDemandLimit,
            teamOnDemandUsedUSD: teamOnDemandUsed,
            teamOnDemandLimitUSD: teamOnDemandLimit,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd,
            membershipType: summary.membershipType,
            accountEmail: userInfo?.email,
            accountName: userInfo?.name,
            rawJSON: rawJSON,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit,
            cloudAgentUsage: cloudAgentUsage)
    }

    #if os(macOS)
    private static let defaultBrowserCookieImportOrder: BrowserCookieImportOrder = cursorCookieImportOrder
    #else
    private static let defaultBrowserCookieImportOrder: BrowserCookieImportOrder = []
    #endif
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
    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        _ = baseURL
        _ = timeout
        _ = browserDetection
        _ = urlSession
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot {
        _ = logger
        throw CursorStatusProbeError.notSupported
    }

    public func fetch(
        cookieHeaderOverride _: String? = nil,
        allowCachedSessions _: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot
    {
        try await self.fetch(logger: logger)
    }
}

#endif

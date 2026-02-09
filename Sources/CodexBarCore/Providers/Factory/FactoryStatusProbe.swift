import Foundation
import SweetCookieKit

#if os(macOS)

private let factoryCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.factory]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Factory Cookie Importer

/// Imports Factory session cookies from browser cookies.
public enum FactoryCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "__Host-authjs.csrf-token",
        "authjs.session-token",
        "session",
        "access-token",
    ]

    private static let authSessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
    ]
    private static let appBaseURL = URL(string: "https://app.factory.ai")!
    private static let authBaseURL = URL(string: "https://auth.factory.ai")!
    private static let apiBaseURL = URL(string: "https://api.factory.ai")!

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

    /// Returns all Factory sessions across supported browsers.
    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[factory-cookie] \(msg)") }
        var sessions: [SessionInfo] = []

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = factoryCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
            do {
                let perSource = try self.importSessions(from: browserSource, logger: logger)
                sessions.append(contentsOf: perSource)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        guard !sessions.isEmpty else {
            throw FactoryStatusProbeError.noSessionCookie
        }
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[factory-cookie] \(msg)") }
        let cookieDomains = ["factory.ai", "app.factory.ai", "auth.factory.ai"]
        let query = BrowserCookieQuery(domains: cookieDomains)
        let sources = try Self.cookieClient.records(
            matching: query,
            in: browserSource,
            logger: log)

        var sessions: [SessionInfo] = []
        for source in sources where !source.records.isEmpty {
            let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
            if httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) }) {
                log("Found \(httpCookies.count) Factory cookies in \(source.label)")
                log("\(source.label) cookie names: \(self.cookieNames(from: httpCookies))")
                if let token = httpCookies.first(where: { $0.name == "access-token" })?.value {
                    let hint = token.contains(".") ? "jwt" : "opaque"
                    log("\(source.label) access-token cookie: \(token.count) chars (\(hint))")
                }
                if let token = httpCookies.first(where: { self.authSessionCookieNames.contains($0.name) })?.value {
                    let hint = token.contains(".") ? "jwt" : "opaque"
                    log("\(source.label) session cookie: \(token.count) chars (\(hint))")
                }
                sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
            } else {
                log("\(source.label) cookies found, but no Factory session cookie present")
            }
        }
        return sessions
    }

    /// Attempts to import Factory cookies using the standard browser import order.
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
            throw FactoryStatusProbeError.noSessionCookie
        }
        return first
    }

    /// Check if Factory session cookies are available
    public static func hasSession(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        do {
            return try !(self.importSessions(browserDetection: browserDetection, logger: logger)).isEmpty
        } catch {
            return false
        }
    }

    private static func cookieNames(from cookies: [HTTPCookie]) -> String {
        let names = Set(cookies.map { "\($0.name)@\($0.domain)" }).sorted()
        return names.joined(separator: ", ")
    }
}

// MARK: - Factory API Models

public struct FactoryAuthResponse: Codable, Sendable {
    public let featureFlags: FactoryFeatureFlags?
    public let organization: FactoryOrganization?
}

public struct FactoryFeatureFlags: Codable, Sendable {
    public let flags: [String: Bool]?
    public let configs: [String: AnyCodable]?
}

public struct FactoryOrganization: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let subscription: FactorySubscription?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case subscription
    }
}

public struct FactorySubscription: Codable, Sendable {
    public let factoryTier: String?
    public let orbSubscription: FactoryOrbSubscription?
}

public struct FactoryOrbSubscription: Codable, Sendable {
    public let plan: FactoryPlan?
    public let status: String?
}

public struct FactoryPlan: Codable, Sendable {
    public let name: String?
    public let id: String?
}

public struct FactoryUsageResponse: Codable, Sendable {
    public let usage: FactoryUsageData?
    public let source: String?
    public let userId: String?
}

public struct FactoryUsageData: Codable, Sendable {
    public let startDate: Int64?
    public let endDate: Int64?
    public let standard: FactoryTokenUsage?
    public let premium: FactoryTokenUsage?
}

public struct FactoryTokenUsage: Codable, Sendable {
    public let userTokens: Int64?
    public let orgTotalTokensUsed: Int64?
    public let totalAllowance: Int64?
    public let usedRatio: Double?
    public let orgOverageUsed: Int64?
    public let basicAllowance: Int64?
    public let orgOverageLimit: Int64?
}

/// Helper for encoding arbitrary JSON
public struct AnyCodable: Codable, Sendable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            return
        }
        _ = try? container.decode([String: AnyCodable].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// MARK: - Factory Status Snapshot

public struct FactoryStatusSnapshot: Sendable {
    /// Standard token usage (user)
    public let standardUserTokens: Int64
    /// Standard token usage (org total)
    public let standardOrgTokens: Int64
    /// Standard token allowance
    public let standardAllowance: Int64
    /// Standard usage ratio from API (0.0-1.0), preferred over manual calculation
    /// Falls back to percent-scale (0.0-100.0) when allowance is unavailable.
    public let standardUsedRatio: Double?
    /// Premium token usage (user)
    public let premiumUserTokens: Int64
    /// Premium token usage (org total)
    public let premiumOrgTokens: Int64
    /// Premium token allowance
    public let premiumAllowance: Int64
    /// Premium usage ratio from API (0.0-1.0), preferred over manual calculation
    /// Falls back to percent-scale (0.0-100.0) when allowance is unavailable.
    public let premiumUsedRatio: Double?
    /// Billing period start
    public let periodStart: Date?
    /// Billing period end
    public let periodEnd: Date?
    /// Plan name
    public let planName: String?
    /// Factory tier (enterprise, team, etc.)
    public let tier: String?
    /// Organization name
    public let organizationName: String?
    /// User email
    public let accountEmail: String?
    /// User ID
    public let userId: String?
    /// Raw JSON for debugging
    public let rawJSON: String?

    public init(
        standardUserTokens: Int64,
        standardOrgTokens: Int64,
        standardAllowance: Int64,
        standardUsedRatio: Double? = nil,
        premiumUserTokens: Int64,
        premiumOrgTokens: Int64,
        premiumAllowance: Int64,
        premiumUsedRatio: Double? = nil,
        periodStart: Date?,
        periodEnd: Date?,
        planName: String?,
        tier: String?,
        organizationName: String?,
        accountEmail: String?,
        userId: String?,
        rawJSON: String?)
    {
        self.standardUserTokens = standardUserTokens
        self.standardOrgTokens = standardOrgTokens
        self.standardAllowance = standardAllowance
        self.standardUsedRatio = standardUsedRatio
        self.premiumUserTokens = premiumUserTokens
        self.premiumOrgTokens = premiumOrgTokens
        self.premiumAllowance = premiumAllowance
        self.premiumUsedRatio = premiumUsedRatio
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.planName = planName
        self.tier = tier
        self.organizationName = organizationName
        self.accountEmail = accountEmail
        self.userId = userId
        self.rawJSON = rawJSON
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: Standard tokens used (as percentage of allowance, capped reasonably)
        let standardPercent = self.calculateUsagePercent(
            used: self.standardUserTokens,
            allowance: self.standardAllowance,
            apiRatio: self.standardUsedRatio)

        let primary = RateWindow(
            usedPercent: standardPercent,
            windowMinutes: nil,
            resetsAt: self.periodEnd,
            resetDescription: self.periodEnd.map { Self.formatResetDate($0) })

        // Secondary: Premium tokens used
        let premiumPercent = self.calculateUsagePercent(
            used: self.premiumUserTokens,
            allowance: self.premiumAllowance,
            apiRatio: self.premiumUsedRatio)

        let secondary = RateWindow(
            usedPercent: premiumPercent,
            windowMinutes: nil,
            resetsAt: self.periodEnd,
            resetDescription: self.periodEnd.map { Self.formatResetDate($0) })

        // Format login method as tier + plan
        let loginMethod: String? = {
            var parts: [String] = []
            if let tier = self.tier, !tier.isEmpty {
                parts.append("Factory \(tier.capitalized)")
            }
            if let plan = self.planName, !plan.isEmpty, !plan.lowercased().contains("factory") {
                parts.append(plan)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " - ")
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .factory,
            accountEmail: self.accountEmail,
            accountOrganization: self.organizationName,
            loginMethod: loginMethod)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private func calculateUsagePercent(used: Int64, allowance: Int64, apiRatio: Double?) -> Double {
        // Prefer API-provided ratio when available and valid.
        // This handles plan-specific limits correctly on the server side,
        // avoiding issues with missing/sentinel values in totalAllowance.
        let unlimitedThreshold: Int64 = 1_000_000_000_000
        if let ratio = apiRatio,
           let percent = Self.percentFromAPIRatio(ratio, allowance: allowance, unlimitedThreshold: unlimitedThreshold)
        {
            return percent
        }

        // Fallback: calculate from used/allowance.
        // Treat very large allowances (> 1 trillion) as unlimited.
        if allowance > unlimitedThreshold {
            // For unlimited, show a token count-based pseudo-percentage (capped at 100%).
            // Use 100M tokens as a reference point for "100%".
            let referenceTokens: Double = 100_000_000
            return min(100, Double(used) / referenceTokens * 100)
        }
        guard allowance > 0 else { return 0 }
        return min(100, Double(used) / Double(allowance) * 100)
    }

    private static func percentFromAPIRatio(
        _ ratio: Double,
        allowance: Int64,
        unlimitedThreshold: Int64) -> Double?
    {
        guard ratio.isFinite else { return nil }

        // Primary: ratio scale (0.0 - 1.0). Clamp to account for rounding.
        if ratio >= -0.001, ratio <= 1.001 {
            return min(100, max(0, ratio * 100))
        }

        // TODO: Confirm usedRatio contract (0.0-1.0 vs 0.0-100.0) and tighten this fallback.
        // Secondary: percent scale (0.0 - 100.0), only when allowance is missing/unreliable.
        // This avoids misinterpreting slightly-over-1 ratios when we can calculate locally.
        let allowanceIsReliable = allowance > 0 && allowance <= unlimitedThreshold
        if !allowanceIsReliable, ratio >= -0.1, ratio <= 100.1 {
            return min(100, max(0, ratio))
        }

        return nil
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }
}

// MARK: - Factory Status Probe Error

public enum FactoryStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Factory. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Factory API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Factory usage: \(msg)"
        case .noSessionCookie:
            "No Factory session found. Please log in to app.factory.ai in \(factoryCookieImportOrder.loginHint)."
        }
    }
}

// MARK: - Factory Session Store

public actor FactorySessionStore {
    public static let shared = FactorySessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var bearerToken: String?
    private var refreshToken: String?
    private let fileURL: URL
    private var didLoadFromDisk = false

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("factory-session.json")
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.didLoadFromDisk = true
        self.sessionCookies = cookies
        self.saveToDisk()
    }

    public func getCookies() -> [HTTPCookie] {
        self.loadFromDiskIfNeeded()
        return self.sessionCookies
    }

    public func setBearerToken(_ token: String?) {
        self.didLoadFromDisk = true
        self.bearerToken = token
        self.saveToDisk()
    }

    public func getBearerToken() -> String? {
        self.loadFromDiskIfNeeded()
        return self.bearerToken
    }

    public func setRefreshToken(_ token: String?) {
        self.didLoadFromDisk = true
        self.refreshToken = token
        self.saveToDisk()
    }

    public func getRefreshToken() -> String? {
        self.loadFromDiskIfNeeded()
        return self.refreshToken
    }

    public func clearSession() {
        self.didLoadFromDisk = true
        self.sessionCookies = []
        self.bearerToken = nil
        self.refreshToken = nil
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public func hasValidSession() -> Bool {
        self.loadFromDiskIfNeeded()
        return !self.sessionCookies.isEmpty || self.bearerToken != nil || self.refreshToken != nil
    }

    private func saveToDisk() {
        let cookieData = self.sessionCookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var serializable: [String: Any] = [:]
            for (key, value) in props {
                let keyString = key.rawValue
                if let date = value as? Date {
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

        var payload: [String: Any] = [:]
        if !cookieData.isEmpty {
            payload["cookies"] = cookieData
        }
        if let bearerToken {
            payload["bearerToken"] = bearerToken
        }
        if let refreshToken {
            payload["refreshToken"] = refreshToken
        }

        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else {
            return
        }
        try? data.write(to: self.fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return }

        var cookieArray: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            if let stored = dict["cookies"] as? [[String: Any]] {
                cookieArray = stored
            }
            self.bearerToken = dict["bearerToken"] as? String
            self.refreshToken = dict["refreshToken"] as? String
        } else if let stored = json as? [[String: Any]] {
            cookieArray = stored
        }

        self.sessionCookies = cookieArray.compactMap { props in
            var cookieProps: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in props {
                if key.hasSuffix("_isDate") || key.hasSuffix("_isURL") { continue }

                let propKey = HTTPCookiePropertyKey(key)

                if props[key + "_isDate"] as? Bool == true, let interval = value as? TimeInterval {
                    cookieProps[propKey] = Date(timeIntervalSince1970: interval)
                } else if props[key + "_isURL"] as? Bool == true, let urlString = value as? String {
                    cookieProps[propKey] = URL(string: urlString)
                } else {
                    cookieProps[propKey] = value
                }
            }
            return HTTPCookie(properties: cookieProps)
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !self.didLoadFromDisk else { return }
        self.didLoadFromDisk = true
        self.loadFromDisk()
    }
}

// MARK: - Factory Status Probe

// swiftlint:disable:next type_body_length
public struct FactoryStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0
    private static let staleTokenCookieNames: Set<String> = [
        "access-token",
        "__recent_auth",
    ]
    private static let sessionCookieNames: Set<String> = [
        "session",
        "wos-session",
    ]
    private static let authSessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
    ]
    static let appBaseURL = URL(string: "https://app.factory.ai")!
    static let authBaseURL = URL(string: "https://auth.factory.ai")!
    static let apiBaseURL = URL(string: "https://api.factory.ai")!
    private static let workosClientIDs = [
        "client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7",
        "client_01HNM792M5G5G1A2THWPXKFMXB",
    ]

    private struct WorkOSAuthResponse: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let organization_id: String?
    }

    private let browserDetection: BrowserDetection

    private struct DebugConfig: Sendable {
        let forceBrowserCookieAuth: Bool
        let unsafeCookieAuth: Bool
        let chromeOnly: Bool
        let keepGoingAfterSuccess: Bool

        static func current(env: [String: String] = ProcessInfo.processInfo.environment) -> DebugConfig {
            DebugConfig(
                forceBrowserCookieAuth: self.isEnabled(env["CODEXBAR_FACTORY_FORCE_BROWSER_COOKIE_AUTH"]),
                unsafeCookieAuth: self.isEnabled(env["CODEXBAR_FACTORY_UNSAFE_COOKIE_AUTH"]),
                chromeOnly: self.isEnabled(env["CODEXBAR_FACTORY_CHROME_ONLY"]),
                keepGoingAfterSuccess: self.isEnabled(env["CODEXBAR_FACTORY_DEBUG_KEEP_GOING_AFTER_SUCCESS"]))
        }

        private static func isEnabled(_ raw: String?) -> Bool {
            guard let raw else { return false }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return v == "1" || v == "true" || v == "yes" || v == "on"
        }
    }

    public init(
        baseURL: URL = URL(string: "https://app.factory.ai")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
    }

    /// Fetch Factory usage using browser cookies with fallback to stored session.
    public func fetch(
        cookieHeaderOverride: String? = nil,
        allowLocalStorageRefreshTokenAuth: Bool = true,
        allowWorkOSCookieAuth: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[factory] \(msg)") }
        var lastError: Error?

        let debug = DebugConfig.current()
        if debug.forceBrowserCookieAuth {
            log("DEBUG: forcing browser cookie auth (may invalidate your browser session)")
            let sources: [Browser] = debug.chromeOnly ? [.chrome] : [.chrome, .firefox]
            switch await self.attemptBrowserCookies(
                logger: log,
                sources: sources,
                unsafeCookieAuth: debug.unsafeCookieAuth)
            {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                throw error
            case .skipped:
                throw FactoryStatusProbeError.noSessionCookie
            }
        }
        if debug.keepGoingAfterSuccess {
            log("DEBUG: keeping auth attempts running even after success (for repro)")
            log("DEBUG: this may invalidate your browser session")
        }

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            return try await self.fetchWithManualCookieHeaderOverride(override, logger: log)
        }

        let cachedCookieHeader = CookieHeaderCache.load(provider: .factory)
        var cachedCookieHeaderForAuth = cachedCookieHeader.flatMap { entry in
            Self.cookieHeaderForCookieAuth(fromHeader: entry.cookieHeader)
        }
        if cachedCookieHeader != nil,
           (cachedCookieHeaderForAuth ?? "")
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .isEmpty
        {
            // Legacy caches could contain only token-like cookies that we now drop for safety. If filtering empties the
            // header, clear the cache so UI and behavior remain aligned ("Cached" should mean "usable").
            log("Clearing cached cookie header: no safe cookies remain after filtering")
            CookieHeaderCache.clear(provider: .factory)
            cachedCookieHeaderForAuth = nil
        }

        // IMPORTANT: run attempts sequentially and stop after the first success.
        // Attempting multiple auth methods after a successful fetch can mutate/rotate server-side sessions,
        // which is user-visible in the browser (issue #323).

        // Filter to only installed browsers to avoid unnecessary keychain prompts
        let installedChromiumAndFirefox = [.chrome, .firefox].cookieImportCandidates(using: self.browserDetection)
        let browserCookieSources = debug.chromeOnly ? installedChromiumAndFirefox
            .filter { $0 == .chrome } : installedChromiumAndFirefox

        let attempts: [() async -> FetchAttemptResult] = [
            { await self.attemptStoredBearer(logger: log) },
            {
                guard allowLocalStorageRefreshTokenAuth else {
                    // Refresh token exchange can rotate/revoke the browser’s session state (issue #323).
                    // If we're in "safe" mode, skip this path and also clear any previously stored refresh token so we
                    // don't accidentally use it later.
                    if let refreshToken = await FactorySessionStore.shared.getRefreshToken(),
                       !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        log("Clearing stored WorkOS refresh token: refresh-token auth disabled")
                        await FactorySessionStore.shared.setRefreshToken(nil)
                    }
                    return .skipped
                }
                return await self.attemptStoredRefreshToken(logger: log)
            },
            {
                await self.attemptLocalStorageTokens(
                    logger: log,
                    allowRefreshTokenAuth: allowLocalStorageRefreshTokenAuth)
            },
            {
                guard let cachedCookieHeaderForAuth,
                      let cachedCookieHeader,
                      !cachedCookieHeaderForAuth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return .skipped
                }

                log("Using cached cookie header from \(cachedCookieHeader.sourceLabel)")
                do {
                    // Deliberately do not derive an Authorization header from cached cookies.
                    return try await .success(self.fetchWithCookieHeader(
                        cachedCookieHeaderForAuth,
                        bearerToken: nil,
                        baseURL: self.baseURL,
                        logger: log))
                } catch {
                    if case FactoryStatusProbeError.notLoggedIn = error {
                        CookieHeaderCache.clear(provider: .factory)
                    }
                    return .failure(error)
                }
            },
            { await self.attemptStoredCookies(logger: log) },
            {
                await self.attemptBrowserCookies(
                    logger: log,
                    sources: [.safari],
                    unsafeCookieAuth: debug.unsafeCookieAuth)
            },
            { allowWorkOSCookieAuth ? await self.attemptWorkOSCookies(logger: log, sources: [.safari]) : .skipped },
            { await self.attemptBrowserCookies(
                logger: log,
                sources: browserCookieSources,
                unsafeCookieAuth: debug.unsafeCookieAuth) },
            {
                allowWorkOSCookieAuth ? await self
                    .attemptWorkOSCookies(logger: log, sources: browserCookieSources) : .skipped },
        ]

        var firstSuccessSnapshot: FactoryStatusSnapshot?
        for attempt in attempts {
            let result = await attempt()
            switch result {
            case let .success(snapshot):
                if firstSuccessSnapshot == nil {
                    firstSuccessSnapshot = snapshot
                }
                if !debug.keepGoingAfterSuccess {
                    return snapshot
                }
            case let .failure(error):
                lastError = error
            case .skipped:
                continue
            }
        }

        if let firstSuccessSnapshot {
            return firstSuccessSnapshot
        }
        if let lastError { throw lastError }
        throw FactoryStatusProbeError.noSessionCookie
    }

    private func fetchWithManualCookieHeaderOverride(
        _ override: String,
        logger: @escaping (String) -> Void) async throws -> FactoryStatusSnapshot
    {
        logger("Using manual cookie header")

        let safeOverride = Self.cookieHeaderForCookieAuth(fromHeader: override) ?? override
        let bearer = Self.bearerToken(fromHeader: override)
        let candidates = [
            self.baseURL,
            Self.authBaseURL,
            Self.apiBaseURL,
        ]

        var lastError: Error?
        for baseURL in candidates {
            // Prefer cookie-only first to avoid replaying a token-like cookie as Authorization (can invalidate browser
            // sessions).
            do {
                return try await self.fetchWithCookieHeader(
                    safeOverride,
                    bearerToken: nil,
                    baseURL: baseURL,
                    logger: logger)
            } catch {
                lastError = error
            }

            // If the override contains an access token, fall back to Authorization for compatibility.
            // (Still uses a filtered cookie header when possible.)
            if let bearer {
                do {
                    return try await self.fetchWithCookieHeader(
                        safeOverride,
                        bearerToken: bearer,
                        baseURL: baseURL,
                        logger: logger)
                } catch {
                    lastError = error
                }
            }
        }

        if let lastError { throw lastError }
        throw FactoryStatusProbeError.noSessionCookie
    }

    private enum FetchAttemptResult: Sendable {
        case success(FactoryStatusSnapshot)
        case failure(Error)
        case skipped
    }

    private func attemptBrowserCookies(
        logger: @escaping (String) -> Void,
        sources: [Browser],
        unsafeCookieAuth: Bool = false) async -> FetchAttemptResult
    {
        do {
            var lastError: Error?
            for browserSource in sources {
                let sessions = try FactoryCookieImporter.importSessions(from: browserSource, logger: logger)
                for session in sessions {
                    logger("Using cookies from \(session.sourceLabel)")
                    do {
                        let snapshot = try await self.fetchWithCookies(
                            session.cookies,
                            logger: logger,
                            unsafeCookieAuth: unsafeCookieAuth)
                        await FactorySessionStore.shared.setCookies(session.cookies)
                        let safeCookieHeader = Self
                            .cookieHeader(from: Self.cookiesForCookieAuth(cookies: session.cookies))
                        if !safeCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            CookieHeaderCache.store(
                                provider: .factory,
                                cookieHeader: safeCookieHeader,
                                sourceLabel: session.sourceLabel)
                        }
                        return .success(snapshot)
                    } catch {
                        lastError = error
                        logger("Browser session fetch failed for \(session.sourceLabel): \(error.localizedDescription)")
                    }
                }
            }
            if let lastError { return .failure(lastError) }
            return .skipped
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            logger("Browser cookie import failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func attemptStoredCookies(logger: @escaping (String) -> Void) async -> FetchAttemptResult {
        let storedCookies = await FactorySessionStore.shared.getCookies()
        guard !storedCookies.isEmpty else { return .skipped }
        logger("Using stored session cookies")
        do {
            return try await .success(self.fetchWithCookies(storedCookies, logger: logger))
        } catch {
            if case FactoryStatusProbeError.notLoggedIn = error {
                await FactorySessionStore.shared.clearSession()
                logger("Stored session invalid, cleared")
            } else {
                logger("Stored session failed: \(error.localizedDescription)")
            }
            return .failure(error)
        }
    }

    private func attemptStoredBearer(logger: @escaping (String) -> Void) async -> FetchAttemptResult {
        guard let bearerToken = await FactorySessionStore.shared.getBearerToken() else { return .skipped }
        logger("Using stored Factory bearer token")
        do {
            return try await .success(self.fetchWithBearerToken(bearerToken, logger: logger))
        } catch {
            return .failure(error)
        }
    }

    private func attemptStoredRefreshToken(logger: @escaping (String) -> Void) async -> FetchAttemptResult {
        guard let refreshToken = await FactorySessionStore.shared.getRefreshToken(),
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .skipped
        }
        logger("Using stored WorkOS refresh token")
        do {
            return try await .success(self.fetchWithWorkOSRefreshToken(
                refreshToken,
                organizationID: nil,
                logger: logger))
        } catch {
            if self.isInvalidGrant(error) {
                await FactorySessionStore.shared.setRefreshToken(nil)
            } else if case FactoryStatusProbeError.noSessionCookie = error {
                await FactorySessionStore.shared.setRefreshToken(nil)
            }
            return .failure(error)
        }
    }

    private func attemptLocalStorageTokens(
        logger: @escaping (String) -> Void,
        allowRefreshTokenAuth: Bool) async -> FetchAttemptResult
    {
        let workosTokens = FactoryLocalStorageImporter.importWorkOSTokens(
            browserDetection: self.browserDetection,
            logger: logger)
        guard !workosTokens.isEmpty else { return .skipped }
        var lastError: Error?
        for token in workosTokens {
            guard !token.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            logger("Using WorkOS refresh token from \(token.sourceLabel)")
            if let accessToken = token.accessToken {
                do {
                    await FactorySessionStore.shared.setBearerToken(accessToken)
                    return try await .success(self.fetchWithBearerToken(accessToken, logger: logger))
                } catch {
                    lastError = error
                }
            }
            guard allowRefreshTokenAuth else {
                logger("Skipping WorkOS refresh token exchange (disabled)")
                continue
            }
            do {
                return try await .success(self.fetchWithWorkOSRefreshToken(
                    token.refreshToken,
                    organizationID: token.organizationID,
                    logger: logger))
            } catch {
                if self.isInvalidGrant(error) {
                    await FactorySessionStore.shared.setRefreshToken(nil)
                }
                lastError = error
            }
        }
        if let lastError { return .failure(lastError) }
        return .skipped
    }

    private func attemptWorkOSCookies(
        logger: @escaping (String) -> Void,
        sources: [Browser]) async -> FetchAttemptResult
    {
        let log: (String) -> Void = { msg in logger("[factory-workos] \(msg)") }
        var lastError: Error?

        for browserSource in sources {
            do {
                let query = BrowserCookieQuery(domains: ["workos.com"])
                let sources = try BrowserCookieClient().records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    log("Using WorkOS cookies from \(source.label)")
                    do {
                        let auth = try await self.fetchWorkOSAccessTokenWithCookies(
                            cookies: cookies,
                            logger: logger)
                        await FactorySessionStore.shared.setBearerToken(auth.access_token)
                        if let refreshToken = auth.refresh_token {
                            await FactorySessionStore.shared.setRefreshToken(refreshToken)
                        }
                        return try await .success(self.fetchWithBearerToken(auth.access_token, logger: logger))
                    } catch {
                        lastError = error
                        log("WorkOS cookie auth failed for \(source.label): \(error.localizedDescription)")
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) WorkOS cookie import failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        if let lastError { return .failure(lastError) }
        return .skipped
    }

    private func fetchWithWorkOSRefreshToken(
        _ refreshToken: String,
        organizationID: String?,
        logger: @escaping (String) -> Void) async throws -> FactoryStatusSnapshot
    {
        let auth = try await self.fetchWorkOSAccessToken(
            refreshToken: refreshToken,
            organizationID: organizationID)
        await FactorySessionStore.shared.setBearerToken(auth.access_token)
        if let newRefresh = auth.refresh_token {
            await FactorySessionStore.shared.setRefreshToken(newRefresh)
        }
        return try await self.fetchWithBearerToken(auth.access_token, logger: logger)
    }

    private func fetchWithCookies(
        _ cookies: [HTTPCookie],
        logger: @escaping (String) -> Void) async throws -> FactoryStatusSnapshot
    {
        try await self.fetchWithCookies(
            cookies,
            logger: logger,
            unsafeCookieAuth: false)
    }

    private func fetchWithCookies(
        _ cookies: [HTTPCookie],
        logger: @escaping (String) -> Void,
        unsafeCookieAuth: Bool) async throws -> FactoryStatusSnapshot
    {
        let candidates = Self.baseURLCandidates(default: self.baseURL, cookies: cookies)
        var lastError: Error?

        for baseURL in candidates {
            if baseURL != self.baseURL {
                logger("Trying Factory base URL: \(baseURL.host ?? baseURL.absoluteString)")
            }
            do {
                return try await self.fetchWithCookies(
                    cookies,
                    baseURL: baseURL,
                    logger: logger,
                    unsafeCookieAuth: unsafeCookieAuth)
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw FactoryStatusProbeError.noSessionCookie
    }

    private func fetchWithCookies(
        _ cookies: [HTTPCookie],
        baseURL: URL,
        logger: @escaping (String) -> Void,
        unsafeCookieAuth: Bool) async throws -> FactoryStatusSnapshot
    {
        let cookieAuthCookies = unsafeCookieAuth ? cookies : Self.cookiesForCookieAuth(cookies: cookies)
        let header = Self.cookieHeader(from: cookieAuthCookies)
        let bearerToken = unsafeCookieAuth ? Self.bearerToken(from: cookies) : nil
        if unsafeCookieAuth {
            logger("DEBUG: using unsafe cookie auth (includes Authorization and token-like cookies)")
        }
        do {
            return try await self.fetchWithCookieHeader(
                header,
                bearerToken: bearerToken,
                baseURL: baseURL,
                logger: logger)
        } catch let error as FactoryStatusProbeError {
            guard case let .networkError(message) = error,
                  message.contains("HTTP 409")
            else {
                throw error
            }

            var lastError: Error? = error
            let retryBaseCookies = unsafeCookieAuth ? cookies : cookieAuthCookies

            let retries: [(String, (HTTPCookie) -> Bool)] = [
                ("Retrying without access-token cookies", { !Self.staleTokenCookieNames.contains($0.name) }),
                ("Retrying without session cookies", { !Self.sessionCookieNames.contains($0.name) }),
                ("Retrying without access-token/session cookies", {
                    !Self.staleTokenCookieNames.contains($0.name) && !Self.sessionCookieNames.contains($0.name)
                }),
            ]

            for (label, predicate) in retries {
                let filtered = retryBaseCookies.filter(predicate)
                guard filtered.count < retryBaseCookies.count else { continue }
                logger(label)
                do {
                    return try await self.fetchWithCookieHeader(
                        Self.cookieHeader(from: filtered),
                        bearerToken: bearerToken,
                        baseURL: baseURL,
                        logger: logger)
                } catch let retryError as FactoryStatusProbeError {
                    switch retryError {
                    case let .networkError(retryMessage)
                        where retryMessage.contains("HTTP 409") &&
                        retryMessage.localizedCaseInsensitiveContains("stale token"):
                        lastError = retryError
                        continue
                    case .notLoggedIn:
                        lastError = retryError
                        continue
                    default:
                        throw retryError
                    }
                }
            }

            let authOnly = retryBaseCookies.filter {
                Self.authSessionCookieNames.contains($0.name) || $0.name == "__Host-authjs.csrf-token"
            }
            if !authOnly.isEmpty, authOnly.count < retryBaseCookies.count {
                logger("Retrying with auth session cookies only")
                do {
                    return try await self.fetchWithCookieHeader(
                        Self.cookieHeader(from: authOnly),
                        bearerToken: bearerToken,
                        baseURL: baseURL,
                        logger: logger)
                } catch let retryError as FactoryStatusProbeError {
                    lastError = retryError
                }
            }

            if let lastError { throw lastError }
            throw error
        } catch {
            throw error
        }
    }

    private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieHeaderForCookieAuth(fromHeader cookieHeader: String) -> String? {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        guard !pairs.isEmpty else { return nil }

        let filteredPairs = pairs.filter { pair in
            !self.staleTokenCookieNames.contains(pair.name)
        }
        if filteredPairs.isEmpty { return nil }
        return filteredPairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func bearerToken(fromHeader cookieHeader: String) -> String? {
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) where pair.name == "access-token" {
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    private static func bearerToken(from cookies: [HTTPCookie]) -> String? {
        let accessToken = cookies.first(where: { $0.name == "access-token" })?.value
        let sessionToken = cookies.first(where: { Self.authSessionCookieNames.contains($0.name) })?.value
        let legacySession = cookies.first(where: { $0.name == "session" })?.value

        if let accessToken, accessToken.contains(".") {
            return accessToken
        }
        if let sessionToken, sessionToken.contains(".") {
            return sessionToken
        }
        if let legacySession, legacySession.contains(".") {
            return legacySession
        }
        return accessToken ?? sessionToken
    }

    private func fetchWithCookieHeader(
        _ cookieHeader: String,
        bearerToken: String?,
        baseURL: URL,
        logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot
    {
        // First fetch auth info to get user ID and org info
        let authInfo = try await self.fetchAuthInfo(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            baseURL: baseURL,
            logger: logger)

        // Extract user ID from JWT in the auth response or use a default endpoint
        let userId = self.extractUserIdFromAuth(authInfo)

        // Fetch usage data
        let usageData = try await self.fetchUsage(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            userId: userId,
            baseURL: baseURL,
            logger: logger)

        return self.buildSnapshot(authInfo: authInfo, usageData: usageData, userId: userId)
    }

    private func fetchAuthInfo(
        cookieHeader: String,
        bearerToken: String?,
        baseURL: URL,
        logger: ((String) -> Void)? = nil) async throws -> FactoryAuthResponse
    {
        let url = baseURL.appendingPathComponent("/api/app/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid response")
        }
        self.logHTTP(request: request, response: httpResponse, logger: logger)

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw FactoryStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = body.isEmpty ? "" : ": \(body.prefix(200))"
            throw FactoryStatusProbeError.networkError("HTTP \(httpResponse.statusCode)\(snippet)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(FactoryAuthResponse.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw FactoryStatusProbeError
                .parseFailed("Auth decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchUsage(
        cookieHeader: String,
        bearerToken: String?,
        userId: String?,
        baseURL: URL,
        logger: ((String) -> Void)? = nil) async throws -> FactoryUsageResponse
    {
        let url = baseURL.appendingPathComponent("/api/organization/subscription/usage")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        // Build request body
        var body: [String: Any] = ["useCache": true]
        if let userId {
            body["userId"] = userId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid response")
        }
        self.logHTTP(request: request, response: httpResponse, logger: logger)

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw FactoryStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = body.isEmpty ? "" : ": \(body.prefix(200))"
            throw FactoryStatusProbeError.networkError("HTTP \(httpResponse.statusCode)\(snippet)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(FactoryUsageResponse.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw FactoryStatusProbeError
                .parseFailed("Usage decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private static func baseURLCandidates(default baseURL: URL, cookies: [HTTPCookie]) -> [URL] {
        let cookieDomains = Set(
            cookies.map {
                $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            })

        var candidates: [URL] = []
        if cookieDomains.contains("auth.factory.ai") {
            candidates.append(Self.authBaseURL)
        }
        candidates.append(Self.apiBaseURL)
        candidates.append(Self.appBaseURL)
        candidates.append(baseURL)

        var seen = Set<String>()
        return candidates.filter { url in
            let key = url.absoluteString
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func cookiesForCookieAuth(cookies: [HTTPCookie]) -> [HTTPCookie] {
        // Exclude token-like cookies that may cause server-side session rotation when replayed.
        cookies.filter { !self.staleTokenCookieNames.contains($0.name) }
    }

    private func fetchWithBearerToken(
        _ bearerToken: String,
        logger: @escaping (String) -> Void) async throws -> FactoryStatusSnapshot
    {
        let candidates = [Self.apiBaseURL, self.baseURL]
        var lastError: Error?
        for baseURL in candidates {
            if baseURL != Self.apiBaseURL {
                logger("Trying Factory bearer base URL: \(baseURL.host ?? baseURL.absoluteString)")
            }
            do {
                return try await self.fetchWithCookieHeader(
                    "",
                    bearerToken: bearerToken,
                    baseURL: baseURL,
                    logger: logger)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw FactoryStatusProbeError.notLoggedIn
    }

    private func fetchWorkOSAccessToken(
        refreshToken: String,
        organizationID: String?) async throws -> WorkOSAuthResponse
    {
        var lastError: Error?
        for clientID in Self.workosClientIDs {
            do {
                return try await self.fetchWorkOSAccessToken(
                    refreshToken: refreshToken,
                    organizationID: organizationID,
                    clientID: clientID)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw FactoryStatusProbeError.networkError("WorkOS auth failed")
    }

    private func fetchWorkOSAccessToken(
        refreshToken: String,
        organizationID: String?,
        clientID: String) async throws -> WorkOSAuthResponse
    {
        guard let url = URL(string: "https://api.workos.com/user_management/authenticate") else {
            throw FactoryStatusProbeError.networkError("WorkOS auth URL unavailable")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let organizationID {
            body["organization_id"] = organizationID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid WorkOS response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 400, Self.isMissingWorkOSRefreshToken(data) {
                throw FactoryStatusProbeError.noSessionCookie
            }
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = body.isEmpty ? "" : ": \(body.prefix(200))"
            throw FactoryStatusProbeError.networkError("WorkOS HTTP \(httpResponse.statusCode)\(snippet)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(WorkOSAuthResponse.self, from: data)
    }

    private func fetchWorkOSAccessTokenWithCookies(
        cookies: [HTTPCookie],
        logger: (String) -> Void) async throws -> WorkOSAuthResponse
    {
        let cookieHeader = Self.cookieHeader(from: cookies)
        guard !cookieHeader.isEmpty else {
            throw FactoryStatusProbeError.networkError("Missing WorkOS cookies")
        }

        var lastError: Error?
        for clientID in Self.workosClientIDs {
            do {
                return try await self.fetchWorkOSAccessTokenWithCookies(
                    cookieHeader: cookieHeader,
                    organizationID: nil,
                    clientID: clientID)
            } catch {
                lastError = error
                logger("WorkOS cookie auth failed for client \(clientID): \(error.localizedDescription)")
            }
        }
        if let lastError { throw lastError }
        throw FactoryStatusProbeError.networkError("WorkOS cookie auth failed")
    }

    private func fetchWorkOSAccessTokenWithCookies(
        cookieHeader: String,
        organizationID: String?,
        clientID: String) async throws -> WorkOSAuthResponse
    {
        guard let url = URL(string: "https://api.workos.com/user_management/authenticate") else {
            throw FactoryStatusProbeError.networkError("WorkOS auth URL unavailable")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        var body: [String: Any] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "useCookie": true,
        ]
        if let organizationID {
            body["organization_id"] = organizationID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid WorkOS response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 400, Self.isMissingWorkOSRefreshToken(data) {
                throw FactoryStatusProbeError.noSessionCookie
            }
            let bodyText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = bodyText.isEmpty ? "" : ": \(bodyText.prefix(200))"
            throw FactoryStatusProbeError.networkError("WorkOS HTTP \(httpResponse.statusCode)\(snippet)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(WorkOSAuthResponse.self, from: data)
    }

    private func isInvalidGrant(_ error: Error) -> Bool {
        guard case let FactoryStatusProbeError.networkError(message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("invalid_grant")
    }

    static func isMissingWorkOSRefreshToken(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return false
        }
        guard let description = json["error_description"] as? String else { return false }
        return description.localizedCaseInsensitiveContains("missing refresh token")
    }

    private func extractUserIdFromAuth(_ auth: FactoryAuthResponse) -> String? {
        // The user ID might be in the organization or we might need to parse JWT
        // For now, return nil and let the API handle it
        nil
    }

    private func buildSnapshot(
        authInfo: FactoryAuthResponse,
        usageData: FactoryUsageResponse,
        userId: String?) -> FactoryStatusSnapshot
    {
        let usage = usageData.usage

        let periodStart: Date? = usage?.startDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let periodEnd: Date? = usage?.endDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }

        return FactoryStatusSnapshot(
            standardUserTokens: usage?.standard?.userTokens ?? 0,
            standardOrgTokens: usage?.standard?.orgTotalTokensUsed ?? 0,
            standardAllowance: usage?.standard?.totalAllowance ?? 0,
            standardUsedRatio: usage?.standard?.usedRatio,
            premiumUserTokens: usage?.premium?.userTokens ?? 0,
            premiumOrgTokens: usage?.premium?.orgTotalTokensUsed ?? 0,
            premiumAllowance: usage?.premium?.totalAllowance ?? 0,
            premiumUsedRatio: usage?.premium?.usedRatio,
            periodStart: periodStart,
            periodEnd: periodEnd,
            planName: authInfo.organization?.subscription?.orbSubscription?.plan?.name,
            tier: authInfo.organization?.subscription?.factoryTier,
            organizationName: authInfo.organization?.name,
            accountEmail: nil, // Email is in JWT, not in auth response body
            userId: userId ?? usageData.userId,
            rawJSON: nil)
    }

    private func logHTTP(request: URLRequest, response: HTTPURLResponse, logger: ((String) -> Void)?) {
        guard let logger else { return }
        guard let url = request.url else { return }

        let method = request.httpMethod ?? "?"
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path

        let hasCookie = (request.value(forHTTPHeaderField: "Cookie")?.isEmpty == false)
        let hasAuth = (request.value(forHTTPHeaderField: "Authorization")?.isEmpty == false)
        let location = response.value(forHTTPHeaderField: "Location")

        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { partial, entry in
            guard let key = entry.key as? String else { return }
            if let value = entry.value as? String {
                partial[key] = value
            } else {
                partial[key] = String(describing: entry.value)
            }
        }
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        let setCookieNames = Set(setCookies.map(\.name)).sorted()

        var parts: [String] = []
        parts.append("\(method) \(host)\(path)")
        parts.append("status=\(response.statusCode)")
        parts.append("cookie=\(hasCookie ? "1" : "0")")
        parts.append("auth=\(hasAuth ? "1" : "0")")
        if let location, let safeLocation = Self.safeRedirectLocationForLog(location), !safeLocation.isEmpty {
            parts.append("location=\(safeLocation)")
        }
        if !setCookieNames.isEmpty {
            parts.append("setCookieNames=\(setCookieNames.joined(separator: ","))")
        }
        logger("[factory-http] " + parts.joined(separator: " "))
    }

    private static func safeRedirectLocationForLog(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Avoid logging query/fragment (may contain OAuth codes/state/redirect URIs).
        guard var components = URLComponents(string: trimmed) else { return nil }
        components.query = nil
        components.fragment = nil

        if let host = components.host, !host.isEmpty {
            let path = components.path.isEmpty ? "/" : components.path
            return "\(host)\(path)"
        }
        // If it's a relative URL (or no host), log path only.
        if !components.path.isEmpty {
            return components.path
        }
        return nil
    }
}

#if DEBUG
extension FactoryStatusProbe {
    static func _cookieNamesDroppedFromCookieAuthForTesting(cookies: [HTTPCookie]) -> [String] {
        let original = Set(cookies.map(\.name))
        let filtered = Set(Self.cookiesForCookieAuth(cookies: cookies).map(\.name))
        return Array(original.subtracting(filtered)).sorted()
    }
}
#endif

#else

// MARK: - Factory (Unsupported)

public enum FactoryStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Factory is only supported on macOS."
    }
}

public struct FactoryStatusSnapshot: Sendable {
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

public struct FactoryStatusProbe: Sendable {
    public init(
        baseURL: URL = URL(string: "https://app.factory.ai")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection)
    {
        _ = baseURL
        _ = timeout
        _ = browserDetection
    }

    public func fetch(
        cookieHeaderOverride _: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot
    {
        _ = logger
        throw FactoryStatusProbeError.notSupported
    }
}

#endif

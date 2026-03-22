import Foundation
import SweetCookieKit
#if os(macOS)
import CommonCrypto
import Security
import SQLite3
#endif

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
        "session",
        "__recent_auth",
        "__wuid",
        "workos_id",
        "__kduid",
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
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        var sawAccessDenied = false

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = cursorCookieImportOrder.cookieImportCandidates(using: browserDetection)
        let cookieDomains = ["cursor.com", "cursor.sh"]
        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                if Self.usesArcSpecificChromiumImport(browserSource) {
                    if let arcSession = try Self.importArcChromiumSession(
                        browser: browserSource,
                        query: query,
                        logger: log)
                    {
                        log("Found \(arcSession.cookies.count) Cursor cookies in \(arcSession.sourceLabel)")
                        return arcSession
                    }
                    continue
                }
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if Self.hasLikelySessionCookie(in: httpCookies) {
                        log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    } else {
                        log("\(source.label) cookies found, but no Cursor session cookie present")
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                if let browserCookieError = error as? BrowserCookieError,
                   case .accessDenied = browserCookieError
                {
                    sawAccessDenied = true
                }
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        if sawAccessDenied {
            throw CursorStatusProbeError.browserCookieAccessDenied
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

    static func hasLikelySessionCookie(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            self.sessionCookieNames.contains(cookie.name)
        }
    }

    private static func usesArcSpecificChromiumImport(_ browser: Browser) -> Bool {
        switch browser {
        case .arc, .arcBeta, .arcCanary:
            true
        default:
            false
        }
    }

    private static func importArcChromiumSession(
        browser: Browser,
        query: BrowserCookieQuery,
        logger: ((String) -> Void)?) throws -> SessionInfo?
    {
        let stores = Self.cookieClient
            .stores(for: browser)
            .filter { $0.browser == browser && $0.databaseURL != nil }

        guard !stores.isEmpty else { return nil }

        let key = try Self.arcSafeStorageKey(for: browser)
        for store in stores {
            guard let databaseURL = store.databaseURL else { continue }
            let records = try Self.readChromiumCookieRecords(
                from: databaseURL,
                browser: browser,
                query: query,
                key: key)
            guard !records.isEmpty else { continue }
            let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
            if Self.hasLikelySessionCookie(in: cookies) {
                return SessionInfo(cookies: cookies, sourceLabel: store.label)
            }
            logger?("\(store.label) cookies found, but no Cursor session cookie present")
        }
        return nil
    }

    private static func arcSafeStorageKey(for browser: Browser) throws -> Data {
        let labels = browser.safeStorageLabels
        for label in labels {
            if let password = Self.findGenericPassword(service: label.service, account: label.account),
               let key = Self.deriveChromiumKey(password: password)
            {
                return key
            }
        }

        throw BrowserCookieError.accessDenied(
            browser: browser,
            details: "\(browser.displayName) Safe Storage keychain item is not accessible.")
    }

    private static func findGenericPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deriveChromiumKey(password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return key
    }

    private static func readChromiumCookieRecords(
        from sourceDB: URL,
        browser: Browser,
        query: BrowserCookieQuery,
        key: Data) throws -> [BrowserCookieRecord]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cursor-arc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let copiedDB = tempDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: sourceDB, to: copiedDB)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceDB.path + suffix)
            guard FileManager.default.fileExists(atPath: sourceSidecar.path) else { continue }
            let copiedSidecar = URL(fileURLWithPath: copiedDB.path + suffix)
            try? FileManager.default.copyItem(at: sourceSidecar, to: copiedSidecar)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copiedDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw BrowserCookieError.loadFailed(
                browser: browser,
                details: "Failed to open \(browser.displayName) cookies database.")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE '%cursor.com%' OR host_key LIKE '%cursor.sh%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BrowserCookieError.loadFailed(
                browser: browser,
                details: "Failed to query \(browser.displayName) cookies database.")
        }
        defer { sqlite3_finalize(statement) }

        var records: [BrowserCookieRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let hostKey = Self.sqliteText(statement, index: 0) ?? ""
            guard Self.hostMatchesCursorDomains(hostKey, patterns: query.domains) else { continue }

            guard let name = Self.sqliteText(statement, index: 1),
                  let path = Self.sqliteText(statement, index: 2)
            else { continue }

            let expiresUTC = sqlite3_column_int64(statement, 3)
            let isSecure = sqlite3_column_int(statement, 4) != 0
            let isHTTPOnly = sqlite3_column_int(statement, 5) != 0
            let plainValue = Self.sqliteText(statement, index: 6)
            let encryptedValue = Self.sqliteBlob(statement, index: 7)

            let value: String
            if let plainValue, !plainValue.isEmpty {
                value = plainValue
            } else if let encryptedValue,
                      let decrypted = Self.decryptChromiumV10Value(
                          encryptedValue,
                          key: key,
                          hostKey: hostKey),
                      !decrypted.isEmpty
            {
                value = decrypted
            } else {
                continue
            }

            let expires = Self.chromiumExpiryDate(expiresUTC: expiresUTC)
            if !query.includeExpired, let expires, expires < query.referenceDate {
                continue
            }

            records.append(BrowserCookieRecord(
                domain: Self.normalizedDomain(hostKey),
                name: name,
                path: path,
                value: value,
                expires: expires,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly))
        }

        return records
    }

    private static func decryptChromiumV10Value(
        _ encryptedValue: Data,
        key: Data,
        hostKey: String) -> String?
    {
        guard encryptedValue.count > 3 else { return nil }
        guard String(data: encryptedValue.prefix(3), encoding: .utf8) == "v10" else { return nil }

        let payload = encryptedValue.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength: size_t = 0
        let outputCapacity = output.count

        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.count = outputLength

        if output.count > 32 {
            let digest = Self.sha256(Data(hostKey.utf8))
            if output.prefix(32) == digest {
                return String(data: output.dropFirst(32), encoding: .utf8)
            }
        }

        return String(data: output, encoding: .utf8)
    }

    private static func chromiumExpiryDate(expiresUTC: Int64) -> Date? {
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func hostMatchesCursorDomains(_ hostKey: String, patterns: [String]) -> Bool {
        let host = Self.normalizedDomain(hostKey).lowercased()
        let normalizedPatterns = patterns.map { Self.normalizedDomain($0).lowercased() }
        guard !normalizedPatterns.isEmpty else { return true }
        return normalizedPatterns.contains { pattern in
            host == pattern || host.hasSuffix("." + pattern)
        }
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func sqliteText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func sqliteBlob(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBytes in
            data.withUnsafeBytes { dataBytes in
                _ = CC_SHA256(
                    dataBytes.baseAddress,
                    CC_LONG(data.count),
                    digestBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return digest
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
    case browserCookieAccessDenied
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Cursor. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Cursor usage: \(msg)"
        case .browserCookieAccessDenied:
            "Could not access browser cookies. Allow Keychain access when prompted, then try again."
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
    private let browserDetection: BrowserDetection

    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
    }

    /// Fetch Cursor usage with manual cookie header (for debugging).
    public func fetchWithManualCookies(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        try await self.fetchWithCookieHeader(cookieHeader)
    }

    /// Fetch Cursor usage using browser cookies with fallback to stored session.
    public func fetch(cookieHeaderOverride: String? = nil, logger: ((String) -> Void)? = nil)
        async throws -> CursorStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var browserImportError: CursorStatusProbeError?

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        if let cached = CookieHeaderCache.load(provider: .cursor),
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

        // Try importing cookies from the configured browser order first.
        do {
            let session = try CursorCookieImporter.importSession(browserDetection: self.browserDetection, logger: log)
            log("Using cookies from \(session.sourceLabel)")
            let snapshot = try await self.fetchWithCookieHeader(session.cookieHeader)
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return snapshot
        } catch let error as CursorStatusProbeError {
            browserImportError = error
            log("Browser cookie import failed: \(error.localizedDescription)")
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

        if let browserImportError {
            throw browserImportError
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        async let usageSummaryTask = self.fetchUsageSummary(cookieHeader: cookieHeader)
        async let userInfoTask = self.fetchUserInfo(cookieHeader: cookieHeader)

        let (usageSummary, rawJSON) = try await usageSummaryTask
        let userInfo = try? await userInfoTask

        // Fetch legacy request usage only if user has a sub ID.
        // Uses try? to avoid breaking the flow for users where this endpoint fails or returns unexpected data.
        var requestUsage: CursorUsageResponse?
        var requestUsageRawJSON: String?
        if let userId = userInfo?.sub {
            do {
                let (usage, usageRawJSON) = try await self.fetchRequestUsage(userId: userId, cookieHeader: cookieHeader)
                requestUsage = usage
                requestUsageRawJSON = usageRawJSON
            } catch {
                // Silently ignore - not all plans have this endpoint
            }
        }

        // Combine raw JSON for debugging
        var combinedRawJSON: String? = rawJSON
        if let usageJSON = requestUsageRawJSON {
            combinedRawJSON = (combinedRawJSON ?? "") + "\n\n--- /api/usage response ---\n" + usageJSON
        }

        return self.parseUsageSummary(
            usageSummary,
            userInfo: userInfo,
            rawJSON: combinedRawJSON,
            requestUsage: requestUsage)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws -> (CursorUsageSummary, String) {
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

        let (data, response) = try await URLSession.shared.data(for: request)

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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch request usage")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CursorUsageResponse.self, from: data)
        return (usage, rawJSON)
    }

    func parseUsageSummary(
        _ summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        rawJSON: String?,
        requestUsage: CursorUsageResponse? = nil) -> CursorStatusSnapshot
    {
        // Parse billing cycle end date
        let billingCycleEnd: Date? = summary.billingCycleEnd.flatMap { dateString in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }

        // Convert cents to USD (plan percent derives from raw values to avoid percent unit mismatches).
        // Use plan.limit directly - breakdown.total represents total *used* credits, not the limit.
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
        let requestsUsed: Int? = requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests
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
            rawJSON: rawJSON,
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
    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection)
    {
        _ = baseURL
        _ = timeout
        _ = browserDetection
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot {
        _ = logger
        throw CursorStatusProbeError.notSupported
    }

    public func fetch(
        cookieHeaderOverride _: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot
    {
        try await self.fetch(logger: logger)
    }
}

#endif

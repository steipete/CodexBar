#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import SweetCookieKit

#if os(macOS) || os(Linux)

private let cursorCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? .safariChromeFirefox

enum CursorEnvironment {
    private static let cookieHeaderKeys = [
        "CURSOR_COOKIE_HEADER",
        "CURSOR_COOKIE",
    ]

    static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.cookieHeaderKeys {
            guard let raw = environment[key], let cleaned = self.cleaned(raw) else { continue }
            let stripped = self.stripCookiePrefix(cleaned)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return nil
    }

    private static func cleaned(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func stripCookiePrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("cookie:") else { return trimmed }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "cookie:".count)
        return trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(macOS)

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
    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        var sessions: [SessionInfo] = []
        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = cursorCookieImportOrder.cookieImportCandidates(using: browserDetection)
        let cookieDomains = ["cursor.com", "cursor.sh"]
        for browserSource in installedBrowsers {
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
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    } else {
                        log("\(source.label) cookies found, but no Cursor session cookie present")
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }
        if sessions.isEmpty {
            throw CursorStatusProbeError.noSessionCookie
        }
        return sessions
    }

    /// Attempts to import Cursor cookies using the standard browser import order.
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        if let first = sessions.first { return first }
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

#elseif os(Linux)

// MARK: - Cursor Cookie Importer (Linux)

/// Imports Cursor session cookies from Chrome using keyring-backed decryption.
public enum CursorCookieImporter {
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

    private struct LinuxCookieResponse: Decodable {
        let sessions: [LinuxCookieSession]
    }

    private struct LinuxCookieSession: Decodable {
        let label: String
        let cookies: [LinuxCookieRecord]
    }

    private struct LinuxCookieRecord: Decodable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Double?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    private enum ImportError: LocalizedError {
        case pythonMissing
        case scriptFailed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .pythonMissing:
                "python3 not found; unable to import Chrome cookies."
            case let .scriptFailed(details):
                "Chrome cookie import failed: \(details)"
            case .invalidOutput:
                "Chrome cookie import returned invalid data."
            }
        }
    }

    public static func importSessions(logger: ((String) -> Void)? = nil) throws -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        let sessions = try self.loadChromeSessions()
        if sessions.isEmpty {
            throw CursorStatusProbeError.noSessionCookie
        }
        for session in sessions {
            log("Found \(session.cookies.count) Cursor cookies in \(session.sourceLabel)")
        }
        return sessions
    }

    /// Attempts to import Cursor cookies from Chrome profiles.
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        try self.importSession(logger: logger)
    }

    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try self.importSessions(logger: logger)
        if let first = sessions.first { return first }
        throw CursorStatusProbeError.noSessionCookie
    }

    public static func hasSession(logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }

    private static func loadChromeSessions() throws -> [SessionInfo] {
        guard let python = self.pythonBinary() else { throw ImportError.pythonMissing }

        let output = try self.runPython(
            binary: python,
            script: self.cookieImportScript(),
            timeout: 8.0)
        guard let data = output.data(using: .utf8) else {
            throw ImportError.invalidOutput
        }
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(LinuxCookieResponse.self, from: data) else {
            throw ImportError.invalidOutput
        }
        return response.sessions.compactMap { session in
            let cookies = session.cookies.compactMap { self.makeHTTPCookie(from: $0) }
            guard !cookies.isEmpty else { return nil }
            let label = session.label.isEmpty ? "Chrome" : session.label
            return SessionInfo(cookies: cookies, sourceLabel: label)
        }
    }

    private static func makeHTTPCookie(from record: LinuxCookieRecord) -> HTTPCookie? {
        let domain = self.normalizeDomain(record.domain)
        guard !domain.isEmpty else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: record.path,
            .name: record.name,
            .value: record.value,
            .secure: record.isSecure,
        ]
        if let originURL = URL(string: "https://\(domain)") {
            props[.originURL] = originURL
        }
        if record.isHTTPOnly {
            props[.init("HttpOnly")] = "TRUE"
        }
        if let expires = record.expires {
            props[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: props)
    }

    private static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    private static func pythonBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PYTHON3_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/python3"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        let fallbacks = ["/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
        for candidate in fallbacks where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func runPython(
        binary: String,
        script: String,
        timeout: TimeInterval) throws -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ImportError.scriptFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw ImportError.scriptFailed("Timed out while reading Chrome cookies.")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.scriptFailed(trimmed.isEmpty ? "Exit code \(process.terminationStatus)." : trimmed)
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // swiftlint:disable:next function_body_length
    private static func cookieImportScript() -> String {
        """
        import json
        import os
        import sqlite3
        import tempfile
        import shutil

        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes, padding
        import secretstorage

        DOMAINS = ["cursor.com", "cursor.sh"]

        def chrome_secret():
            bus = secretstorage.dbus_init()
            collection = secretstorage.get_default_collection(bus)
            for attrs in ({"application": "chrome"}, {"application": "chromium"}, {"application": "brave"}):
                items = list(collection.search_items(attrs))
                for item in items:
                    label = item.get_label()
                    if "Safe Storage" in label:
                        return item.get_secret().decode("utf-8")
            return None

        def derive_key(secret):
            if secret is None or not secret:
                secret = "peanuts"
            kdf = PBKDF2HMAC(
                algorithm=hashes.SHA1(),
                length=16,
                salt=b"saltysalt",
                iterations=1,
            )
            return kdf.derive(secret.encode("utf-8"))

        def clean_value(data):
            for offset in (0, 32):
                if offset >= len(data):
                    continue
                try:
                    text = data[offset:].decode("utf-8")
                    return text.lstrip("".join(chr(i) for i in range(32)))
                except Exception:
                    pass
            idx = 0
            while idx < len(data) and data[idx] < 32:
                idx += 1
            try:
                return data[idx:].decode("utf-8")
            except Exception:
                return None

        def decrypt_value(enc, key):
            if enc is None:
                return None
            if isinstance(enc, memoryview):
                enc = enc.tobytes()
            if not enc:
                return None
            if enc[:3] in (b"v10", b"v11"):
                enc = enc[3:]
            iv = b" " * 16
            cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
            decryptor = cipher.decryptor()
            data = decryptor.update(enc) + decryptor.finalize()
            unpadder = padding.PKCS7(128).unpadder()
            try:
                plain = unpadder.update(data) + unpadder.finalize()
            except Exception:
                return None
            return clean_value(plain)

        def cookie_sources():
            home = os.path.expanduser("~")
            roots = [
                os.path.join(home, ".config", "google-chrome"),
                os.path.join(home, ".config", "google-chrome-beta"),
                os.path.join(home, ".config", "google-chrome-unstable"),
                os.path.join(home, ".config", "chromium"),
                os.path.join(home, ".config", "BraveSoftware", "Brave-Browser"),
            ]
            for root in roots:
                if not os.path.isdir(root):
                    continue
                entries = [os.path.join(root, entry) for entry in os.listdir(root)]
                profiles = []
                for entry in entries:
                    if not os.path.isdir(entry):
                        continue
                    name = os.path.basename(entry)
                    if name == "Default" or name.startswith("Profile ") or name.startswith("user-"):
                        profiles.append(entry)
                for profile in sorted(profiles):
                    label = os.path.basename(root) + " " + os.path.basename(profile)
                    yield label, os.path.join(profile, "Network", "Cookies")
                    yield label, os.path.join(profile, "Cookies")

        def read_db(db_path, key):
            if not os.path.exists(db_path):
                return []
            tmpdir = tempfile.mkdtemp(prefix="codexbar-chrome-cookies-")
            try:
                copied = os.path.join(tmpdir, "Cookies")
                shutil.copy2(db_path, copied)
                for suffix in ("-wal", "-shm"):
                    if os.path.exists(db_path + suffix):
                        shutil.copy2(db_path + suffix, copied + suffix)
                conn = sqlite3.connect(copied)
                cur = conn.cursor()
                clauses = " OR ".join(["host_key LIKE '%{}%'".format(d) for d in DOMAINS])
                cur.execute(\"\"\"
                    SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
                    FROM cookies
                    WHERE {}
                \"\"\".format(clauses))
                rows = cur.fetchall()
                conn.close()
            finally:
                shutil.rmtree(tmpdir, ignore_errors=True)
            out = []
            for host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value in rows:
                if value:
                    decrypted = value
                else:
                    decrypted = decrypt_value(encrypted_value, key)
                if not decrypted:
                    continue
                expires = None
                if expires_utc and expires_utc > 0:
                    expires = float(expires_utc) / 1000000.0 - 11644473600.0
                out.append({
                    "domain": host_key,
                    "name": name,
                    "path": path,
                    "value": decrypted,
                    "expires": expires,
                    "isSecure": bool(is_secure),
                    "isHTTPOnly": bool(is_httponly),
                })
            return out

        def main():
            secret = chrome_secret()
            key = derive_key(secret)
            sessions = []
            for label, db_path in cookie_sources():
                cookies = read_db(db_path, key)
                if not cookies:
                    continue
                names = {c["name"] for c in cookies}
                if "WorkosCursorSessionToken" in names or "__Secure-next-auth.session-token" in names or \
                   "next-auth.session-token" in names:
                    sessions.append({"label": label, "cookies": cookies})
            print(json.dumps({"sessions": sessions}))
            return 0

        if __name__ == "__main__":
            try:
                raise SystemExit(main())
            except Exception as exc:
                import sys
                sys.stderr.write(str(exc))
                raise
        """
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
        "Resets \(UsageFormatter.resetCountdownDescription(from: date))"
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
            #if os(macOS)
            "No Cursor session found. Please log in to cursor.com in \(cursorCookieImportOrder.loginHint)."
            #elseif os(Linux)
            "No Cursor session found. Sign in to cursor.com in Chrome or set CURSOR_COOKIE_HEADER."
            #else
            "No Cursor session found."
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
        #if os(Linux)
        var browserImportError: Error?
        #endif

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        if let envCookieHeader = CursorEnvironment.cookieHeader() {
            log("Using cookies from environment")
            do {
                return try await self.fetchWithCookieHeader(envCookieHeader)
            } catch {
                log("Environment cookies failed: \(error.localizedDescription)")
            }
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
        } catch {
            log("Browser cookie import failed: \(error.localizedDescription)")
            #if os(Linux)
            browserImportError = error
            #endif
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

        #if os(Linux)
        if let browserImportError {
            throw browserImportError
        }
        #endif

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
        // Use breakdown.total if available (includes bonus credits), otherwise fall back to limit.
        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.breakdown?.total ?? summary.individualUsage?.plan?
            .limit ?? 0)
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
        "Cursor is only supported on macOS or Linux."
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

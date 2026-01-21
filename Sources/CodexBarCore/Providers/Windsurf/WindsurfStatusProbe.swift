import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)

private let windsurfCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.windsurf]?.browserCookieOrder ?? .safariChromeFirefox

enum WindsurfEnvironment {
    private static let cookieHeaderKeys = [
        "WINDSURF_COOKIE_HEADER",
        "WINDSURF_COOKIE",
    ]

    private static let tokenKeys = [
        "WINDSURF_TOKEN",
        "WINDSURF_API_TOKEN",
        "WINDSURF_ACCESS_TOKEN",
    ]

    /// Returns a Bearer token if set via environment variable
    static func bearerToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.tokenKeys {
            guard let raw = environment[key], let cleaned = self.cleaned(raw) else { continue }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

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

// MARK: - Windsurf Cookie Importer

/// Imports Windsurf session cookies from browser cookies.
public enum WindsurfCookieImporter {
    // Common session cookie names - Windsurf/Codeium uses various authentication schemes
    private static let sessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "codeium_session",
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

    public static func importSessions(logger: ((String) -> Void)? = nil) throws -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[windsurf-cookie] \(msg)") }
        var sessions: [SessionInfo] = []
        let cookieDomains = ["windsurf.com", "codeium.com"]
        for browserSource in windsurfCookieImportOrder.sources {
            do {
                let sources = try BrowserCookieImporter.loadCookieSources(
                    from: browserSource,
                    matchingDomains: cookieDomains,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieImporter.makeHTTPCookies(source.records)
                    if httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) }) {
                        log("Found \(httpCookies.count) Windsurf cookies in \(source.label)")
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    } else {
                        log("\(source.label) cookies found, but no Windsurf session cookie present")
                    }
                }
            } catch {
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }
        if sessions.isEmpty {
            throw WindsurfStatusProbeError.noSessionCookie
        }
        return sessions
    }

    /// Attempts to import Windsurf cookies using the standard browser import order.
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try self.importSessions(logger: logger)
        if let first = sessions.first { return first }
        throw WindsurfStatusProbeError.noSessionCookie
    }

    /// Check if Windsurf session cookies are available
    public static func hasSession(logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}

#elseif os(Linux)

// MARK: - Windsurf Cookie Importer (Linux)

/// Imports Windsurf session cookies from Chrome using keyring-backed decryption.
public enum WindsurfCookieImporter {
    private static let sessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "codeium_session",
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
        let log: (String) -> Void = { msg in logger?("[windsurf-cookie] \(msg)") }
        let sessions = try self.loadChromeSessions()
        if sessions.isEmpty {
            throw WindsurfStatusProbeError.noSessionCookie
        }
        for session in sessions {
            log("Found \(session.cookies.count) Windsurf cookies in \(session.sourceLabel)")
        }
        return sessions
    }

    /// Attempts to import Windsurf cookies from Chrome profiles.
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try self.importSessions(logger: logger)
        if let first = sessions.first { return first }
        throw WindsurfStatusProbeError.noSessionCookie
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

        DOMAINS = ["windsurf.com", "codeium.com"]

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
            session_names = {
                "__Secure-next-auth.session-token",
                "next-auth.session-token",
                "__Secure-authjs.session-token",
                "authjs.session-token",
                "codeium_session",
            }
            for label, db_path in cookie_sources():
                cookies = read_db(db_path, key)
                if not cookies:
                    continue
                names = {c["name"] for c in cookies}
                if names & session_names:
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

// MARK: - Windsurf API Models

/// Plan status response from gRPC-web API
public struct WindsurfPlanStatus: Sendable {
    public let planName: String?
    public let userPromptCreditsUsed: Double
    public let userPromptCreditsTotal: Double
    public let billingCycleEnd: Date?
    public let email: String?
    public let displayName: String?
}

// MARK: - Windsurf Status Snapshot

public struct WindsurfStatusSnapshot: Sendable {
    /// Percentage of credits used (0-100)
    public let creditsPercentUsed: Double
    /// Credits used
    public let creditsUsed: Double
    /// Total credits available
    public let creditsTotal: Double
    /// Billing cycle reset date
    public let billingCycleEnd: Date?
    /// Plan name (e.g., "Pro", "Free", "Team")
    public let planName: String?
    /// User email
    public let accountEmail: String?
    /// User display name
    public let accountName: String?
    /// Raw response for debugging
    public let rawResponse: String?

    public init(
        creditsPercentUsed: Double,
        creditsUsed: Double,
        creditsTotal: Double,
        billingCycleEnd: Date?,
        planName: String?,
        accountEmail: String?,
        accountName: String?,
        rawResponse: String?)
    {
        self.creditsPercentUsed = creditsPercentUsed
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.billingCycleEnd = billingCycleEnd
        self.planName = planName
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.rawResponse = rawResponse
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = RateWindow(
            usedPercent: self.creditsPercentUsed,
            windowMinutes: nil,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) },
            usedCount: self.creditsUsed,
            totalCount: self.creditsTotal)

        let loginMethod: String? = {
            guard let plan = self.planName, !plan.isEmpty else { return nil }
            if plan.lowercased().contains("windsurf") {
                return plan
            }
            return "Windsurf \(plan)"
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .windsurf,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        "Resets \(UsageFormatter.resetCountdownDescription(from: date))"
    }
}

// MARK: - Windsurf Status Probe Error

public enum WindsurfStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Windsurf. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Windsurf API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Windsurf usage: \(msg)"
        case .noSessionCookie:
            #if os(macOS)
            "No Windsurf session found. Set WINDSURF_TOKEN with your Firebase access token, or log in to windsurf.com in \(windsurfCookieImportOrder.loginHint)."
            #elseif os(Linux)
            "No Windsurf session found. Set WINDSURF_TOKEN with your Firebase access token from your browser's IndexedDB."
            #else
            "No Windsurf session found. Set WINDSURF_TOKEN environment variable."
            #endif
        }
    }
}

// MARK: - Windsurf Session Store

public actor WindsurfSessionStore {
    public static let shared = WindsurfSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("windsurf-session.json")

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
}

// MARK: - Windsurf Status Probe

public struct WindsurfStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0

    public init(baseURL: URL = URL(string: "https://web-backend.windsurf.com")!, timeout: TimeInterval = 15.0) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Fetch Windsurf usage using environment/browser cookies with fallback to stored session.
    public func fetch(logger: ((String) -> Void)? = nil) async throws -> WindsurfStatusSnapshot {
        let log: (String) -> Void = { msg in logger?("[windsurf] \(msg)") }
        #if os(Linux)
        var browserImportError: Error?
        var browserAttemptError: Error?
        #endif

        // First, check for Bearer token (Firebase auth)
        if let bearerToken = WindsurfEnvironment.bearerToken() {
            log("Using Bearer token from environment")
            do {
                return try await self.fetchWithBearerToken(bearerToken)
            } catch {
                log("Bearer token failed: \(error.localizedDescription)")
            }
        }
        
        // Try automated extraction from browser IndexedDB (Linux/macOS)
        if let automatedToken = await Self.extractTokenFromBrowser() {
            log("Using automated token from browser IndexedDB")
            do {
                return try await self.fetchWithBearerToken(automatedToken)
            } catch {
                log("Automated token extraction failed: \(error.localizedDescription)")
            }
        }

        if let envCookieHeader = WindsurfEnvironment.cookieHeader() {
            log("Using cookies from environment")
            do {
                return try await self.fetchWithCookieHeader(envCookieHeader)
            } catch {
                log("Environment cookies failed: \(error.localizedDescription)")
            }
        }

        #if os(macOS) || os(Linux)
        // Try importing cookies from the configured browser order first.
        do {
            let sessions = try WindsurfCookieImporter.importSessions(logger: log)
            for session in sessions {
                do {
                    log("Using cookies from \(session.sourceLabel)")
                    return try await self.fetchWithCookieHeader(session.cookieHeader)
                } catch {
                    log("Cookies from \(session.sourceLabel) failed: \(error.localizedDescription)")
                    #if os(Linux)
                    browserAttemptError = error
                    #endif
                }
            }
        } catch {
            log("Browser cookie import failed: \(error.localizedDescription)")
            #if os(Linux)
            browserImportError = error
            #endif
        }
        #endif

        // Fall back to stored session cookies (from "Add Account" login flow)
        let storedCookies = await WindsurfSessionStore.shared.getCookies()
        if !storedCookies.isEmpty {
            log("Using stored session cookies")
            let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            do {
                return try await self.fetchWithCookieHeader(cookieHeader)
            } catch {
                if case WindsurfStatusProbeError.notLoggedIn = error {
                    await WindsurfSessionStore.shared.clearCookies()
                    log("Stored session invalid, cleared - will retry browser extraction")

                    // Retry: Try fresh browser extraction since stored session expired
                    // The user may have logged in again via browser
                    #if os(macOS) || os(Linux)
                    do {
                        let freshSessions = try WindsurfCookieImporter.importSessions(logger: log)
                        for session in freshSessions {
                            do {
                                log("Retry: Using fresh cookies from \(session.sourceLabel)")
                                let result = try await self.fetchWithCookieHeader(session.cookieHeader)
                                // Success! Store the working cookies for next time
                                let cookies = session.cookies
                                await WindsurfSessionStore.shared.setCookies(cookies)
                                log("Stored fresh session cookies for future use")
                                return result
                            } catch {
                                log("Retry: Fresh cookies from \(session.sourceLabel) failed: \(error.localizedDescription)")
                            }
                        }
                    } catch {
                        log("Retry: Browser cookie re-import failed: \(error.localizedDescription)")
                    }

                    // Also retry automated token extraction
                    if let freshToken = await Self.extractTokenFromBrowser() {
                        log("Retry: Using fresh token from browser IndexedDB")
                        do {
                            return try await self.fetchWithBearerToken(freshToken)
                        } catch {
                            log("Retry: Fresh token failed: \(error.localizedDescription)")
                        }
                    }
                    #endif
                } else {
                    log("Stored session failed: \(error.localizedDescription)")
                }
            }
        }

        #if os(Linux)
        if let browserAttemptError {
            throw browserAttemptError
        }
        if let browserImportError {
            throw browserImportError
        }
        #endif

        throw WindsurfStatusProbeError.noSessionCookie
    }

    private func fetchWithBearerToken(_ token: String) async throws -> WindsurfStatusSnapshot {
        try await self.fetchPlanStatus(authHeader: token, authType: .bearer(token: token))
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> WindsurfStatusSnapshot {
        try await self.fetchPlanStatus(authHeader: cookieHeader, authType: .cookie)
    }

    private enum AuthType {
        case bearer(token: String)
        case cookie
    }

    private func fetchPlanStatus(authHeader: String, authType: AuthType) async throws -> WindsurfStatusSnapshot {
        // Connect protocol endpoint for plan status (connectrpc.com)
        let url = self.baseURL.appendingPathComponent("exa.seat_management_pb.SeatManagementService/GetPlanStatus")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout

        // Use Connect protocol (not gRPC-web) with binary protobuf
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("https://windsurf.com", forHTTPHeaderField: "Origin")
        request.setValue("https://windsurf.com/subscription/usage", forHTTPHeaderField: "Referer")

        switch authType {
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // For Connect protocol, the auth_token is also sent in the request body
            request.httpBody = self.encodeGetPlanStatusRequest(authToken: token)
        case .cookie:
            request.setValue(authHeader, forHTTPHeaderField: "Cookie")
            // Empty request for cookie-based auth
            request.httpBody = Data()
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WindsurfStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WindsurfStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            let responseString = String(data: data, encoding: .utf8) ?? "<binary>"
            throw WindsurfStatusProbeError.networkError("HTTP \(httpResponse.statusCode): \(responseString.prefix(200))")
        }

        // Parse the Connect/Protobuf response (raw binary, not base64)
        return try self.parseConnectResponse(data)
    }

    /// Encodes a GetPlanStatusRequest protobuf message with auth_token (field 1)
    private func encodeGetPlanStatusRequest(authToken: String) -> Data {
        var data = Data()

        // Field 1: auth_token (string) - wire type 2 (length-delimited)
        let fieldTag: UInt8 = (1 << 3) | 2 // field number 1, wire type 2
        data.append(fieldTag)

        // Encode string length as varint
        let tokenBytes = Array(authToken.utf8)
        var length = tokenBytes.count
        while length > 0x7F {
            data.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        data.append(UInt8(length))

        // Append the string bytes
        data.append(contentsOf: tokenBytes)

        return data
    }

    private func parseConnectResponse(_ data: Data) throws -> WindsurfStatusSnapshot {
        // Connect responses are raw binary protobuf (not base64 encoded like gRPC-web-text)
        guard !data.isEmpty else {
            throw WindsurfStatusProbeError.parseFailed("Empty response")
        }

        // Debug: log the raw bytes
        // let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        // #if DEBUG
        // if hexString.count < 500 {
        //     print("[windsurf-debug] Raw response (\(data.count) bytes): \(hexString)")
        // } else {
        //     print("[windsurf-debug] Raw response (\(data.count) bytes, first 100): \(hexString.prefix(300))...")
        // }
        // #endif

        // Try parsing as raw protobuf
        return try self.parseProtobufData(data)
    }

    private func parseProtobufData(_ data: Data) throws -> WindsurfStatusSnapshot {
        // Connect protocol returns raw protobuf without gRPC framing
        guard !data.isEmpty else {
            throw WindsurfStatusProbeError.parseFailed("Response too short")
        }

        // Context to collect parsed values
        var context = ProtobufParseContext()

        // Parse the response recursively
        let bytes = [UInt8](data)
        self.parseProtobufMessage(bytes: bytes, startOffset: 0, endOffset: bytes.count, depth: 0, context: &context)

        #if DEBUG
        // print("[windsurf-debug] Parsed: planName=\(context.planName ?? "nil"), email=\(context.email ?? "nil")")
        // print("[windsurf-debug] Credits by type: \(context.creditsValuesByType)")
        #endif

        // Find the user prompt credits value
        // Usage is now primarily returned in Field 6 as cents (integer)
        var creditsUsed = context.creditsUsed

        if context.usageCents > 0 {
            creditsUsed = Double(context.usageCents) / 100.0
        } else if let userPromptCredits = context.creditsValuesByType[391] {
            creditsUsed = Double(userPromptCredits)
        } else if let altCredits = context.creditsValuesByType[400] {
             // Fallback to 400 if 391 missing
             creditsUsed = Double(altCredits)
        }

        // If still 0 and we have float values, try to find a reasonable one
        // The third float often appears to be the credits used (fallback)
        if creditsUsed == 0 && context.floatValues.count >= 3 {
            let thirdFloat = context.floatValues[2]
            if thirdFloat > 0 && thirdFloat < 500 {
                creditsUsed = Double(thirdFloat)
            }
        }

        // Calculate percentage
        let percentUsed = context.creditsTotal > 0 ? (creditsUsed / context.creditsTotal) * 100 : 0

        return WindsurfStatusSnapshot(
            creditsPercentUsed: percentUsed,
            creditsUsed: creditsUsed,
            creditsTotal: context.creditsTotal,
            billingCycleEnd: context.billingCycleEnd,
            planName: context.planName,
            accountEmail: context.email,
            accountName: context.displayName,
            rawResponse: nil)
    }

    private struct ProtobufParseContext {
        var creditsUsed: Double = 0
        var creditsTotal: Double = 500.0
        var planName: String?
        var email: String?
        var displayName: String?
        var billingCycleEnd: Date?
        var floatValues: [Float] = []
        var varintValues: [Int] = []
        var creditsValuesByType: [Int: Float] = [:] // Map credit type ID to value
        var lastVarintInNestedMessage: Int = 0 // Track last varint for credit type ID
        var usageCents: Int = 0 // Field 6 (usage in cents)
    }

    private func parseProtobufMessage(
        bytes: [UInt8],
        startOffset: Int,
        endOffset: Int,
        depth: Int,
        context: inout ProtobufParseContext)
    {
        var offset = startOffset

        while offset < endOffset {
            guard offset < bytes.count else { break }

            let fieldAndWireType = bytes[offset]
            offset += 1

            let fieldNumber = Int(fieldAndWireType >> 3)
            let wireType = fieldAndWireType & 0x07

            switch wireType {
            case 0: // Varint
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while offset < endOffset {
                    let byte = bytes[offset]
                    offset += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                }
                // Use truncating conversion to avoid overflow
                let intVal = value <= UInt64(Int.max) ? Int(value) : Int.max
                context.varintValues.append(intVal)

                // Track this varint for potential credit type ID
                if intVal > 0 && intVal < 1000 {
                    context.lastVarintInNestedMessage = intVal
                }

                // Field 6: Usage in cents (new format)
                if fieldNumber == 6 {
                    context.usageCents = intVal
                }

                // Look for credits total (usually 500 or 600 for pro)
                if fieldNumber == 8 {
                    if intVal >= 400 && intVal <= 1000 {
                        context.creditsTotal = Double(intVal)
                    } else if intVal >= 40000 && intVal <= 200000 {
                         // Scaled value (cents), e.g. 50000 -> 500.0
                         context.creditsTotal = Double(intVal) / 100.0
                    }
                }

                // Look for Unix timestamp (billing cycle end)
                // Valid timestamps for 2024-2027: ~1704067200 to ~1798761600
                if context.billingCycleEnd == nil && value >= 1704067200 && value <= 1798761600 {
                    // This is likely a future date (billing cycle end)
                    let date = Date(timeIntervalSince1970: TimeInterval(value))
                    if date > Date() && date < Date().addingTimeInterval(60 * 24 * 3600) {
                        // Within 60 days in the future - likely billing cycle
                        context.billingCycleEnd = date
                    }
                }

            case 1: // 64-bit (fixed64, sfixed64, double)
                guard offset + 8 <= endOffset else { break }
                let doubleBytes = Array(bytes[offset..<(offset + 8)])
                offset += 8
                let doubleValue = doubleBytes.withUnsafeBytes { $0.load(as: Double.self) }

                // Check if it's a reasonable credit value (could be credits used)
                if doubleValue >= 0 && doubleValue <= 10000 && !doubleValue.isNaN && !doubleValue.isInfinite {
                    // If we saw a varint ID recently, associate it with this double
                    if context.lastVarintInNestedMessage > 0 {
                        context.creditsValuesByType[context.lastVarintInNestedMessage] = Float(doubleValue)
                    }
                    context.lastVarintInNestedMessage = 0
                }

            case 2: // Length-delimited (string, bytes, embedded messages)
                var length: Int = 0
                var shift = 0
                while offset < endOffset {
                    let byte = bytes[offset]
                    offset += 1
                    length |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                }
                let contentEnd = min(offset + length, endOffset)
                guard contentEnd <= bytes.count else { break }
                let contentBytes = Array(bytes[offset..<contentEnd])

                // Try to decode as UTF-8 string
                if let str = String(bytes: contentBytes, encoding: .utf8), self.isValidString(str) {
                    // Identify by content
                    if str.contains("@") && str.contains(".") && str.count < 100 {
                        context.email = str
                    } else if str == "Pro" || str == "Free" || str == "Team" || str == "Enterprise" ||
                              str.lowercased().contains("free tier") || str.lowercased().contains("pro tier") {
                        context.planName = str
                    }
                } else if contentBytes.count > 2 && depth < 5 {
                    // Try to parse as nested message
                    self.parseProtobufMessage(
                        bytes: bytes,
                        startOffset: offset,
                        endOffset: contentEnd,
                        depth: depth + 1,
                        context: &context)
                }

                offset = contentEnd

            case 5: // 32-bit (fixed32, sfixed32, float)
                guard offset + 4 <= endOffset else { break }
                let floatBytes = Array(bytes[offset..<(offset + 4)])
                offset += 4
                let floatValue = floatBytes.withUnsafeBytes { $0.load(as: Float.self) }

                // Only consider reasonable float values
                if floatValue >= 0 && floatValue <= 10000 && !floatValue.isNaN && !floatValue.isInfinite {
                    context.floatValues.append(floatValue)

                    // If we saw a varint ID recently, associate it with this float
                    if context.lastVarintInNestedMessage > 0 {
                        context.creditsValuesByType[context.lastVarintInNestedMessage] = floatValue
                    }

                    // Reset the last varint after using it
                    context.lastVarintInNestedMessage = 0
                }

            default:
                // Skip unknown wire types
                break
            }
        }
    }

    private func isValidString(_ str: String) -> Bool {
        guard !str.isEmpty else { return false }
        // Check if string contains only printable ASCII characters
        for char in str.unicodeScalars {
            if char.value < 32 || char.value > 126 {
                if char.value != 9 && char.value != 10 && char.value != 13 { // Allow tab, newline, CR
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Automated Token Extraction

    private static func extractTokenFromBrowser() async -> String? {
        // Run python script to extract token from IndexedDB
        let script = self.linuxTokenScript
        
        var tempFile: URL?
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "windsurf_token_extract_\(UUID().uuidString).py"
            let fileURL = tempDir.appendingPathComponent(fileName)
            try script.write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)
            tempFile = fileURL
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", fileURL.path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty && output.count > 100 {
                return output
            }
        } catch {
             // Silently fail or log debug
             #if DEBUG
             print("[windsurf] Failed to run token extraction script: \(error)")
             #endif
        }
        
        if let tempFile {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        return nil
    }

    private static let linuxTokenScript = """
import os, glob, re, sys

# Common browser data paths
dirs = [
    os.path.expanduser("~/.config/google-chrome"),
    os.path.expanduser("~/.config/chromium"),
    os.path.expanduser("~/.config/BraveSoftware/Brave-Browser"),
    os.path.expanduser("~/.config/microsoft-edge-dev"),
    os.path.expanduser("~/Library/Application Support/Google/Chrome"),
    os.path.expanduser("~/Library/Application Support/BraveSoftware/Brave-Browser"),
    os.path.expanduser("~/Library/Application Support/Chromium"),
    os.path.expanduser("~/snap/chromium/common/chromium"), 
]

# Regex for JWT token (starts with eyJ, contains dots, alphanumeric)
token_re = re.compile(br'eyJ[a-zA-Z0-9_-]+[.][a-zA-Z0-9_-]+[.][a-zA-Z0-9_-]+')

candidates = []

for d in dirs:
    if not os.path.exists(d): continue
    
    patterns = [
        os.path.join(d, "*", "IndexedDB", "https_windsurf.com_0.indexeddb.leveldb", "*"),
        os.path.join(d, "Default", "IndexedDB", "https_windsurf.com_0.indexeddb.leveldb", "*"),
        os.path.join(d, "Profile *", "IndexedDB", "https_windsurf.com_0.indexeddb.leveldb", "*")
    ]
    
    files = []
    for p in patterns:
        files.extend(glob.glob(p))
    
    seen_files = set()
    for fpath in files:
        if fpath in seen_files: continue
        seen_files.add(fpath)
        if not os.path.isfile(fpath): continue

        try:
            with open(fpath, "rb") as f:
                content = f.read()
                matches = token_re.findall(content)
                for m in matches:
                    if len(m) > 800: # Filter short tokens
                        try:
                            s = m.decode('ascii')
                            candidates.append(s)
                        except:
                            pass
        except:
             pass

if candidates:
    # Return the longest one
    candidates.sort(key=len, reverse=True)
    print(candidates[0])
"""
}

#else

// MARK: - Windsurf (Unsupported)

public enum WindsurfStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Windsurf is only supported on macOS or Linux."
    }
}

public struct WindsurfStatusSnapshot: Sendable {
    public init() {}

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
    }
}

public struct WindsurfStatusProbe: Sendable {
    public init(baseURL: URL = URL(string: "https://web-backend.windsurf.com")!, timeout: TimeInterval = 15.0) {
        _ = baseURL
        _ = timeout
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> WindsurfStatusSnapshot {
        _ = logger
        throw WindsurfStatusProbeError.notSupported
    }
}

#endif

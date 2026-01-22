import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)

private let copilotCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.copilot]?.browserCookieOrder ?? .safariChromeFirefox

enum CopilotEnvironment {
    private static let cookieHeaderKeys = [
        "COPILOT_COOKIE_HEADER",
        "COPILOT_COOKIE",
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

// MARK: - Copilot Cookie Importer

public enum CopilotCookieImporter {
    private static let sessionCookieNames: Set<String> = [
        "user_session",
        "__Host-user_session",
        "_gh_sess",
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
        let log: (String) -> Void = { msg in logger?("[copilot-cookie] \(msg)") }
        var sessions: [SessionInfo] = []
        let cookieDomains = ["github.com"]
        for browserSource in copilotCookieImportOrder.sources {
            do {
                let sources = try BrowserCookieImporter.loadCookieSources(
                    from: browserSource,
                    matchingDomains: cookieDomains,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieImporter.makeHTTPCookies(source.records)
                    if httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) }) {
                        log("Found \(httpCookies.count) GitHub cookies in \(source.label)")
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    } else {
                        log("\(source.label) cookies found, but no GitHub session cookie present")
                    }
                }
            } catch {
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }
        if sessions.isEmpty {
            throw CopilotStatusProbeError.noSessionCookie
        }
        return sessions
    }

    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try self.importSessions(logger: logger)
        if let first = sessions.first { return first }
        throw CopilotStatusProbeError.noSessionCookie
    }

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

// MARK: - Copilot Cookie Importer (Linux)

public enum CopilotCookieImporter {
    private static let sessionCookieNames: Set<String> = [
        "user_session",
        "__Host-user_session",
        "_gh_sess",
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
        let log: (String) -> Void = { msg in logger?("[copilot-cookie] \(msg)") }
        let sessions = try self.loadChromeSessions()
        if sessions.isEmpty {
            throw CopilotStatusProbeError.noSessionCookie
        }
        for session in sessions {
            log("Found \(session.cookies.count) GitHub cookies in \(session.sourceLabel)")
        }
        return sessions
    }

    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try self.importSessions(logger: logger)
        if let first = sessions.first { return first }
        throw CopilotStatusProbeError.noSessionCookie
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

    private static func runPython(binary: String, script: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-c", script]
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

        DOMAINS = ["github.com"]

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
                if "user_session" in names or "__Host-user_session" in names or "_gh_sess" in names:
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

// MARK: - Copilot Status Models

public struct CopilotUsageEntry: Sendable, Equatable {
    public let label: String
    public let usedPercent: Double
    /// Optional raw used count (e.g., 45 out of 100 requests)
    public let usedCount: Double?
    /// Optional raw total count (e.g., 100 total requests)
    public let totalCount: Double?

    public init(label: String, usedPercent: Double, usedCount: Double? = nil, totalCount: Double? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.usedCount = usedCount
        self.totalCount = totalCount
    }
}

public struct CopilotStatusSnapshot: Sendable, Equatable {
    public let primary: CopilotUsageEntry
    public let secondary: CopilotUsageEntry?
    public let resetsAt: Date?
    public let accountLogin: String?
    public let plan: String?
    public let updatedAt: Date

    public init(
        primary: CopilotUsageEntry,
        secondary: CopilotUsageEntry?,
        resetsAt: Date?,
        accountLogin: String?,
        plan: String?,
        updatedAt: Date)
    {
        self.primary = primary
        self.secondary = secondary
        self.resetsAt = resetsAt
        self.accountLogin = accountLogin
        self.plan = plan
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let resetDesc = self.resetsAt.map { Self.formatResetDate($0) }
        let primaryWindow = RateWindow(
            usedPercent: self.primary.usedPercent,
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: resetDesc,
            usedCount: self.primary.usedCount,
            totalCount: self.primary.totalCount)
        let secondaryWindow = self.secondary.map { entry in
            RateWindow(
                usedPercent: entry.usedPercent,
                windowMinutes: nil,
                resetsAt: self.resetsAt,
                resetDescription: resetDesc,
                usedCount: entry.usedCount,
                totalCount: entry.totalCount)
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .copilot,
            accountEmail: self.accountLogin,
            accountOrganization: nil,
            loginMethod: self.plan)
        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        "Resets \(UsageFormatter.resetCountdownDescription(from: date))"
    }
}

// MARK: - Copilot Status Probe

public enum CopilotStatusProbeError: LocalizedError, Sendable, Equatable {
    case noSessionCookie
    case notLoggedIn
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "GitHub Copilot session cookie not found. Sign in to github.com and retry."
        case .notLoggedIn:
            "Not logged in to GitHub. Please log in to github.com."
        case let .parseFailed(message):
            "Could not parse Copilot usage: \(message)"
        case let .networkError(message):
            "Copilot request failed: \(message)"
        }
    }
}

public struct CopilotStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0

    public init(baseURL: URL = URL(string: "https://github.com")!, timeout: TimeInterval = 15.0) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CopilotStatusSnapshot {
        let log: (String) -> Void = { msg in logger?("[copilot] \(msg)") }
        #if os(Linux)
        var browserImportError: Error?
        var browserAttemptError: Error?
        #endif

        if let envCookieHeader = CopilotEnvironment.cookieHeader() {
            log("Using cookies from environment")
            do {
                return try await self.fetchWithCookieHeader(envCookieHeader)
            } catch {
                log("Environment cookies failed: \(error.localizedDescription)")
            }
        }

        do {
            let sessions = try CopilotCookieImporter.importSessions(logger: log)
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

        #if os(Linux)
        if let browserAttemptError {
            throw browserAttemptError
        }
        if let browserImportError {
            throw browserImportError
        }
        #endif

        throw CopilotStatusProbeError.noSessionCookie
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> CopilotStatusSnapshot {
        let html = try await self.fetchSettingsHTML(cookieHeader: cookieHeader)
        return try self.parseUsageHTML(html)
    }

    private func fetchSettingsHTML(cookieHeader: String) async throws -> String {
        let url = self.baseURL.appendingPathComponent("settings/copilot")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeout
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CopilotStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CopilotStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw CopilotStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw CopilotStatusProbeError.parseFailed("Response is not valid UTF-8")
        }

        if self.isLoginPage(html) {
            throw CopilotStatusProbeError.notLoggedIn
        }

        return html
    }

    func parseUsageHTML(_ html: String) throws -> CopilotStatusSnapshot {
        let usageSection = self.extractUsageSection(from: html) ?? html
        let entries = Self.parseUsageEntries(from: usageSection)
        guard !entries.isEmpty else {
            throw CopilotStatusProbeError.parseFailed("No usage entries found.")
        }

        let primaryEntry = entries.first(where: { $0.label.localizedCaseInsensitiveContains("premium") }) ?? entries[0]
        let secondaryEntry = entries.first(where: { $0.label != primaryEntry.label })
        let plan = Self.parsePlan(from: html)
        let login = Self.parseLogin(from: html)
        // Try to parse reset date from HTML, fall back to next month start
        let resetsAt = Self.parseResetDate(from: html) ?? Self.nextMonthStart(from: Date())

        return CopilotStatusSnapshot(
            primary: primaryEntry,
            secondary: secondaryEntry,
            resetsAt: resetsAt,
            accountLogin: login,
            plan: plan,
            updatedAt: Date())
    }

    private func extractUsageSection(from html: String) -> String? {
        guard let headerRange = html.range(
            of: #"<h3[^>]*>\s*Usage\s*</h3>"#,
            options: [.regularExpression, .caseInsensitive])
        else {
            return nil
        }
        let tail = html[headerRange.upperBound...]
        if let end = tail.range(of: "<copilot-user-settings", options: [.caseInsensitive]) {
            return String(tail[..<end.lowerBound])
        }
        return String(tail.prefix(12000))
    }

    private static func parseUsageEntries(from html: String) -> [CopilotUsageEntry] {
        // Pattern to match label with percentage and optional count info
        // Example: <span class="text-bold">Premium requests</span> <div>45%</div> ... 45 / 100
        let pattern =
            #"<span[^>]*text-bold[^>]*>\s*([^<]+?)\s*</span>\s*<div[^>]*>\s*([0-9]+(?:\.[0-9]+)?)%\s*</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        var entries: [CopilotUsageEntry] = []
        entries.reserveCapacity(matches.count)
        for match in matches where match.numberOfRanges >= 3 {
            guard let labelRange = Range(match.range(at: 1), in: html),
                  let percentRange = Range(match.range(at: 2), in: html) else { continue }
            let label = html[labelRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawPercent = html[percentRange].replacingOccurrences(of: ",", with: "")
            guard let percent = Double(rawPercent) else { continue }

            // Try to extract used/total counts from surrounding context
            // Look for patterns like "45 / 100", "45 of 100", "45/100" near this match
            let (usedCount, totalCount) = Self.extractCounts(
                from: html,
                nearMatch: match,
                percent: percent)

            entries.append(CopilotUsageEntry(
                label: label,
                usedPercent: percent,
                usedCount: usedCount,
                totalCount: totalCount))
        }
        return entries
    }

    /// Tries to extract used/total counts from HTML near the percentage match
    private static func extractCounts(
        from html: String,
        nearMatch match: NSTextCheckingResult,
        percent: Double) -> (usedCount: Double?, totalCount: Double?)
    {
        // Look in a window around the match for count patterns
        let searchStart = max(0, match.range.location - 200)
        let searchEnd = min(html.count, match.range.location + match.range.length + 500)

        guard let htmlStartIndex = html.index(html.startIndex, offsetBy: searchStart, limitedBy: html.endIndex),
              let htmlEndIndex = html.index(html.startIndex, offsetBy: searchEnd, limitedBy: html.endIndex)
        else { return (nil, nil) }

        let searchText = String(html[htmlStartIndex..<htmlEndIndex])

        // Pattern to match "X / Y" or "X of Y" or "X/Y" where X and Y are numbers
        // Also matches "used X of Y", "X out of Y"
        let countPatterns = [
            #"(\d+(?:,\d+)?)\s*/\s*(\d+(?:,\d+)?)"#, // "45 / 100" or "45/100"
            #"(\d+(?:,\d+)?)\s+(?:of|out of)\s+(\d+(?:,\d+)?)"#, // "45 of 100" or "45 out of 100"
            #"used\s+(\d+(?:,\d+)?)\s+(?:of|out of|/)\s*(\d+(?:,\d+)?)"#, // "used 45 of 100"
        ]

        for pattern in countPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let textRange = NSRange(searchText.startIndex..<searchText.endIndex, in: searchText)
            if let countMatch = regex.firstMatch(in: searchText, options: [], range: textRange),
               countMatch.numberOfRanges >= 3,
               let usedRange = Range(countMatch.range(at: 1), in: searchText),
               let totalRange = Range(countMatch.range(at: 2), in: searchText)
            {
                let usedStr = searchText[usedRange].replacingOccurrences(of: ",", with: "")
                let totalStr = searchText[totalRange].replacingOccurrences(of: ",", with: "")
                if let used = Double(usedStr), let total = Double(totalStr), total > 0 {
                    // Verify the counts roughly match the percentage (within 5%)
                    let calculatedPercent = (used / total) * 100
                    if abs(calculatedPercent - percent) < 5 {
                        return (used, total)
                    }
                }
            }
        }

        return (nil, nil)
    }

    private static func parsePlan(from html: String) -> String? {
        let pattern = #"GitHub\s+(Copilot[^<]+?)\s+is\s+active\s+for\s+your\s+account"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseLogin(from html: String) -> String? {
        let patterns = [
            #"name="user-login"\s+content="([^"]+)""#,
            #"data-login="([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let matchRange = Range(match.range(at: 1), in: html) else { continue }
            let login = String(html[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !login.isEmpty { return login }
        }
        return nil
    }

    private static func nextMonthStart(from date: Date) -> Date? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let startOfMonth = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: startOfMonth)
    }

    /// Parse reset date from HTML text like "Allowance resets January 1, 2026 at 8:00 AM"
    private static func parseResetDate(from html: String) -> Date? {
        // Pattern: "resets January 1, 2026 at 8:00 AM" or similar
        let pattern = #"(?:resets|refresh)[^<]*?(\w+\s+\d{1,2},?\s+\d{4})(?:\s+at\s+(\d{1,2}:\d{2}\s*(?:AM|PM)?))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let dateRange = Range(match.range(at: 1), in: html) else { return nil }

        let dateStr = String(html[dateRange])
        var timeStr: String?
        if match.numberOfRanges >= 3, let timeRange = Range(match.range(at: 2), in: html) {
            timeStr = String(html[timeRange])
        }

        // Parse the date
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Try with time first
        if let time = timeStr {
            let fullStr = "\(dateStr) \(time)"
            for format in ["MMMM d, yyyy h:mm a", "MMMM d yyyy h:mm a", "MMM d, yyyy h:mm a", "MMM d yyyy h:mm a"] {
                dateFormatter.dateFormat = format
                if let date = dateFormatter.date(from: fullStr) { return date }
            }
        }

        // Fall back to date only (midnight)
        for format in ["MMMM d, yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMM d yyyy"] {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: dateStr) { return date }
        }

        return nil
    }

    private func isLoginPage(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("sign in to github") || lower.contains("signin to github")
    }
}

#else

// MARK: - Copilot (Unsupported)

public enum CopilotStatusProbeError: LocalizedError, Sendable, Equatable {
    case notSupported

    public var errorDescription: String? {
        "GitHub Copilot is only supported on macOS or Linux."
    }
}

public struct CopilotStatusSnapshot: Sendable, Equatable {
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

public struct CopilotStatusProbe: Sendable {
    public init(baseURL: URL = URL(string: "https://github.com")!, timeout: TimeInterval = 15.0) {
        _ = baseURL
        _ = timeout
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CopilotStatusSnapshot {
        _ = logger
        throw CopilotStatusProbeError.notSupported
    }
}

#endif

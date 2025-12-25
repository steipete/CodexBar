#if os(macOS)
import CommonCrypto
import Foundation
import Security
import SQLite3

/// Reads ChatGPT/OpenAI cookies from a local Chromium cookie DB (Google Chrome by default).
///
/// Purpose: optional "no password" bootstrap for the OpenAI dashboard scrape by reusing the user's existing
/// signed-in Chrome session (similar to how `~/Projects/oracle` syncs cookies).
///
/// Notes:
/// - Chrome stores cookie values in an SQLite DB, and most values are encrypted (`encrypted_value` starts
///   with `v10` on macOS). Decryption uses the "Chrome Safe Storage" password from the macOS Keychain and
///   AES-CBC + PBKDF2. This is inherently brittle across Chrome encryption changes; keep it best-effort.
/// - We never persist the imported cookies ourselves. We only inject them into WebKit's `WKWebsiteDataStore`
///   cookie jar for the chosen CodexBar dashboard account.
enum ChromeCookieImporter {
    private static let chromeSafeStorageKeyLock = NSLock()
    private nonisolated(unsafe) static var cachedChromeSafeStorageKey: Data?

    enum ImportError: LocalizedError {
        case cookieDBNotFound(path: String)
        case keychainDenied
        case sqliteFailed(message: String)

        var errorDescription: String? {
            switch self {
            case let .cookieDBNotFound(path): "Chrome Cookies DB not found at \(path)."
            case .keychainDenied: "macOS Keychain denied access to Chrome Safe Storage."
            case let .sqliteFailed(message): "Failed to read Chrome cookies: \(message)"
            }
        }
    }

    struct CookieRecord: Sendable {
        let hostKey: String
        let name: String
        let path: String
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let value: String
    }

    struct CookieSource: Sendable {
        let label: String
        let records: [CookieRecord]
    }

    static func loadChatGPTCookiesFromAllProfiles() throws -> [CookieSource] {
        try self.loadCookiesFromAllProfiles(matchingDomains: ["chatgpt.com", "openai.com"])
    }

    /// Loads cookies from all Chrome profiles matching the given domains.
    /// - Parameter matchingDomains: Array of domain patterns to match (e.g., ["claude.ai"])
    /// - Returns: Array of cookie sources with matching records
    static func loadCookiesFromAllProfiles(matchingDomains domains: [String]) throws -> [CookieSource] {
        let roots = self.candidateHomes().map { home in
            home.appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("Google")
                .appendingPathComponent("Chrome")
        }

        var candidates: [ChromeProfileCandidate] = []
        for root in roots {
            candidates.append(contentsOf: Self.chromeProfileCookieDBs(root: root))
        }
        if candidates.isEmpty {
            let display = roots.map(\.path).joined(separator: " • ")
            throw ImportError.cookieDBNotFound(path: display)
        }

        let chromeKey = try Self.chromeSafeStorageKey()
        return try candidates.compactMap { candidate in
            guard FileManager.default.fileExists(atPath: candidate.cookiesDB.path) else { return nil }
            let records = try Self.readCookiesFromLockedChromeDB(
                sourceDB: candidate.cookiesDB,
                key: chromeKey,
                matchingDomains: domains)
            guard !records.isEmpty else { return nil }
            return CookieSource(label: candidate.label, records: records)
        }
    }

    // MARK: - DB copy helper

    private static func readCookiesFromLockedChromeDB(sourceDB: URL, key: Data) throws -> [CookieRecord] {
        try self.readCookiesFromLockedChromeDB(
            sourceDB: sourceDB,
            key: key,
            matchingDomains: ["chatgpt.com", "openai.com"])
    }

    private static func readCookiesFromLockedChromeDB(
        sourceDB: URL,
        key: Data,
        matchingDomains: [String]) throws -> [CookieRecord]
    {
        // Chrome keeps the DB locked; copy the DB (and wal/shm when present) to a temp folder before reading.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-chrome-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let copiedDB = tempDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: sourceDB, to: copiedDB)

        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: sourceDB.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = URL(fileURLWithPath: copiedDB.path + suffix)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        defer { try? FileManager.default.removeItem(at: tempDir) }

        return try Self.readCookies(fromDB: copiedDB.path, key: key, matchingDomains: matchingDomains)
    }

    // MARK: - SQLite read

    private static func readCookies(fromDB path: String, key: Data) throws -> [CookieRecord] {
        try self.readCookies(fromDB: path, key: key, matchingDomains: ["chatgpt.com", "openai.com"])
    }

    private static func readCookies(
        fromDB path: String,
        key: Data,
        matchingDomains: [String]) throws -> [CookieRecord]
    {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        // Build WHERE clause dynamically for the given domains
        let conditions = matchingDomains.map { "host_key LIKE '%\($0)%'" }.joined(separator: " OR ")
        let sql = """
        SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
        FROM cookies
        WHERE \(conditions)
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [CookieRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hostKey = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let path = String(cString: sqlite3_column_text(stmt, 2))
            let expires = sqlite3_column_int64(stmt, 3)
            let isSecure = sqlite3_column_int(stmt, 4) != 0
            let isHTTPOnly = sqlite3_column_int(stmt, 5) != 0

            let plain = Self.readTextColumn(stmt, index: 6)
            let enc = Self.readBlobColumn(stmt, index: 7)

            let value: String
            if let plain, !plain.isEmpty {
                value = plain
            } else if let enc, !enc.isEmpty, let decrypted = Self.decryptChromiumValue(enc, key: key) {
                value = decrypted
            } else {
                continue
            }

            out.append(CookieRecord(
                hostKey: hostKey,
                name: name,
                path: path,
                expiresUTC: expires,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly,
                value: value))
        }
        return out
    }

    private static func readTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func readBlobColumn(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    // MARK: - Keychain + crypto

    private static func chromeSafeStorageKey() throws -> Data {
        self.chromeSafeStorageKeyLock.lock()
        if let cached = self.cachedChromeSafeStorageKey {
            self.chromeSafeStorageKeyLock.unlock()
            return cached
        }
        self.chromeSafeStorageKeyLock.unlock()

        // Prefer the main Chrome label; fall back to common Chromium forks.
        let labels: [(service: String, account: String)] = [
            ("Chrome Safe Storage", "Chrome"),
            ("Chromium Safe Storage", "Chromium"),
            ("Brave Safe Storage", "Brave"),
            ("Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("Vivaldi Safe Storage", "Vivaldi"),
        ]

        var password: String?
        for label in labels {
            if let p = Self.findGenericPassword(service: label.service, account: label.account) {
                password = p
                break
            }
        }
        guard let password else { throw ImportError.keychainDenied }

        // Chromium macOS key derivation: PBKDF2-HMAC-SHA1 with salt "saltysalt", 1003 iterations, key length 16.
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
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
        guard result == kCCSuccess else {
            throw ImportError.keychainDenied
        }

        self.chromeSafeStorageKeyLock.lock()
        self.cachedChromeSafeStorageKey = key
        self.chromeSafeStorageKeyLock.unlock()
        return key
    }

    // Exposed for tests.
    static func decryptChromiumValue(_ encryptedValue: Data, key: Data) -> String? {
        // macOS Chrome cookies typically have `v10` prefix and AES-CBC payload.
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        let prefixString = String(data: prefix, encoding: .utf8)
        let payload = encryptedValue.dropFirst(3)

        if prefixString != "v10" {
            return nil
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128) // 16 spaces
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var outLength: size_t = 0
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength

        // Chromium's macOS cookie encryption prefixes 32 bytes of non-UTF8 data before the actual cookie value.
        // Other libraries strip this (see `chrome-cookies-secure` / `browser_cookie3`); we do the same so we can
        // build valid `HTTPCookie`s from decrypted values.
        let candidate = out.count > 32 ? out.dropFirst(32) : out[...]
        if let decoded = String(data: Data(candidate), encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        if let decoded = String(data: out, encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        return nil
    }

    private static func cleanValue(_ value: String) -> String {
        // Strip leading control chars (some decryptors still return values with a few leading bytes).
        var i = value.startIndex
        while i < value.endIndex, value[i].unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            i = value.index(after: i)
        }
        return String(value[i...])
    }

    private static func findGenericPassword(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Conversion

    static func makeHTTPCookies(_ records: [CookieRecord]) -> [HTTPCookie] {
        records.compactMap { record in
            let domain = Self.normalizeDomain(record.hostKey)
            guard !domain.isEmpty else { return nil }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: record.path,
                .name: record.name,
                .value: record.value,
                .secure: record.isSecure,
            ]
            props[.originURL] = Self.originURL(forDomain: domain)
            if record.isHTTPOnly {
                props[.init("HttpOnly")] = "TRUE"
            }
            if let expires = Self.cookieExpiryDate(expiresUTC: record.expiresUTC) {
                props[.expires] = expires
            }
            return HTTPCookie(properties: props)
        }
    }

    private static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    private static func originURL(forDomain domain: String) -> URL {
        let d = domain.lowercased()
        if d.contains("openai.com") {
            return URL(string: "https://openai.com")!
        }
        return URL(string: "https://chatgpt.com")!
    }

    private static func cookieExpiryDate(expiresUTC: Int64) -> Date? {
        // Chromium stores microseconds since Windows epoch (1601-01-01).
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Profile discovery

    private struct ChromeProfileCandidate: Sendable {
        let label: String
        let cookiesDB: URL
    }

    private static func chromeProfileCookieDBs(root: URL) -> [ChromeProfileCandidate] {
        // Common profile directories: "Default", "Profile 1", ..., plus possible custom profile dirs.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.map { dir in
            ChromeProfileCandidate(
                label: "Chrome \(dir.lastPathComponent)",
                cookiesDB: dir.appendingPathComponent("Cookies"))
        }
    }

    private static func candidateHomes() -> [URL] {
        var homes: [URL] = []
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            homes.append(URL(fileURLWithPath: userHome))
        }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            homes.append(URL(fileURLWithPath: envHome))
        }
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
#endif

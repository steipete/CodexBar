import Foundation

#if os(macOS)
import CommonCrypto
import Security
import SQLite3
import SweetCookieKit

private let alibabaCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.alibaba]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum AlibabaCodingPlanCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "bailian-singapore-cs.alibabacloud.com",
        "bailian-beijing-cs.aliyuncs.com",
        "modelstudio.console.alibabacloud.com",
        "bailian.console.aliyun.com",
        "free.aliyun.com",
        "account.aliyun.com",
        "signin.aliyun.com",
        "passport.alibabacloud.com",
        "console.alibabacloud.com",
        "console.aliyun.com",
        "alibabacloud.com",
        "aliyun.com",
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

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[alibaba-cookie] \(msg)") }
        var accessDeniedHints: [String] = []
        var failureDetails: [String] = []
        var installedBrowsers = alibabaCookieImportOrder.cookieImportCandidates(using: browserDetection)
        if let safariIndex = installedBrowsers.firstIndex(of: .safari) {
            installedBrowsers.remove(at: safariIndex)
        }
        installedBrowsers.insert(.safari, at: 0)
        log("Cookie import candidates: \(installedBrowsers.map { $0.displayName }.joined(separator: ", "))")

        for browserSource in installedBrowsers {
            do {
                log("Checking \(browserSource.displayName)")
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                if sources.isEmpty {
                    log("No matching cookie records in \(browserSource.displayName)")
                    if let fallbackSession = try Self.importChromiumFallbackSession(browser: browserSource, logger: log) {
                        return fallbackSession
                    }
                }
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if self.isAuthenticatedSession(cookies: httpCookies) {
                        log("Found \(httpCookies.count) Alibaba cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                    let cookieNames = Set(httpCookies.map(\.name))
                    let hasTicket = cookieNames.contains("login_aliyunid_ticket")
                    let hasAccount =
                        cookieNames.contains("login_aliyunid_pk") ||
                        cookieNames.contains("login_current_pk") ||
                        cookieNames.contains("login_aliyunid")
                    log("Skipping \(source.label): missing auth cookies (ticket=\(hasTicket), account=\(hasAccount))")
                }
                if let fallbackSession = try Self.importChromiumFallbackSession(browser: browserSource, logger: log) {
                    return fallbackSession
                }
            } catch let error as BrowserCookieError {
                BrowserCookieAccessGate.recordIfNeeded(error)
                if let hint = error.accessDeniedHint {
                    accessDeniedHints.append(hint)
                }
                failureDetails.append("\(browserSource.displayName): \(error.localizedDescription)")
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            } catch {
                failureDetails.append("\(browserSource.displayName): \(error.localizedDescription)")
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        let details = (Array(Set(accessDeniedHints)).sorted() + Array(Set(failureDetails)).sorted())
            .joined(separator: " ")
        throw AlibabaCodingPlanSettingsError.missingCookie(details: details.isEmpty ? nil : details)
    }

    private static func isAuthenticatedSession(cookies: [HTTPCookie]) -> Bool {
        guard !cookies.isEmpty else { return false }
        let names = Set(cookies.map(\.name))
        let hasTicket = names.contains("login_aliyunid_ticket")
        let hasAccount =
            names.contains("login_aliyunid_pk") ||
            names.contains("login_current_pk") ||
            names.contains("login_aliyunid")
        return hasTicket && hasAccount
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }

    private static func importChromiumFallbackSession(
        browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo?
    {
        guard browser.usesChromiumProfileStore else { return nil }
        return try AlibabaChromiumCookieFallbackImporter.importSession(
            browser: browser,
            domains: self.cookieDomains,
            logger: logger)
    }
}

private enum AlibabaChromiumCookieFallbackImporter {
    private struct ChromiumCookieRecord {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Date?
        let isSecure: Bool
    }

    enum ImportError: LocalizedError {
        case keyUnavailable(browser: Browser)
        case keychainDenied(browser: Browser)
        case sqliteFailed(label: String, details: String)

        var errorDescription: String? {
            switch self {
            case let .keyUnavailable(browser):
                "\(browser.displayName) Safe Storage key not found."
            case let .keychainDenied(browser):
                "macOS Keychain denied access to \(browser.displayName) Safe Storage."
            case let .sqliteFailed(label, details):
                "\(label) cookie fallback failed: \(details)"
            }
        }
    }

    static func importSession(
        browser: Browser,
        domains: [String],
        logger: ((String) -> Void)? = nil) throws -> AlibabaCodingPlanCookieImporter.SessionInfo?
    {
        let stores = BrowserCookieClient().stores(for: browser).filter { $0.databaseURL != nil }
        guard !stores.isEmpty else { return nil }

        logger?("[alibaba-cookie] Trying \(browser.displayName) Chromium fallback")
        let keys = try self.derivedKeys(for: browser)
        for store in stores {
            let cookies = try self.loadCookies(from: store, domains: domains, keys: keys)
            guard !cookies.isEmpty else { continue }
            if self.isAuthenticatedSession(cookies) {
                logger?("[alibaba-cookie] Found \(cookies.count) Alibaba cookies via \(store.label) fallback")
                return AlibabaCodingPlanCookieImporter.SessionInfo(cookies: cookies, sourceLabel: store.label)
            }
        }
        return nil
    }

    private static func isAuthenticatedSession(_ cookies: [HTTPCookie]) -> Bool {
        let names = Set(cookies.map(\.name))
        let hasTicket = names.contains("login_aliyunid_ticket")
        let hasAccount =
            names.contains("login_aliyunid_pk") ||
            names.contains("login_current_pk") ||
            names.contains("login_aliyunid")
        return hasTicket && hasAccount
    }

    private static func loadCookies(
        from store: BrowserCookieStore,
        domains: [String],
        keys: [Data]) throws -> [HTTPCookie]
    {
        guard let sourceDB = store.databaseURL else { return [] }
        let records = try self.readCookiesFromLockedDB(sourceDB: sourceDB, domains: domains, keys: keys, label: store.label)
        return records.compactMap(self.makeCookie)
    }

    private static func readCookiesFromLockedDB(
        sourceDB: URL,
        domains: [String],
        keys: [Data],
        label: String) throws -> [ChromiumCookieRecord]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-chromium-cookies-\(UUID().uuidString)", isDirectory: true)
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

        return try self.readCookies(fromDB: copiedDB.path, domains: domains, keys: keys, label: label)
    }

    private static func readCookies(
        fromDB path: String,
        domains: [String],
        keys: [Data],
        label: String) throws -> [ChromiumCookieRecord]
    {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.sqliteFailed(label: label, details: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT host_key, name, path, expires_utc, is_secure, value, encrypted_value FROM cookies"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.sqliteFailed(label: label, details: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var records: [ChromiumCookieRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostKey = self.readText(stmt, index: 0), self.matches(domain: hostKey, patterns: domains) else {
                continue
            }
            guard let name = self.readText(stmt, index: 1), let path = self.readText(stmt, index: 2) else {
                continue
            }

            let value: String?
            if let plain = self.readText(stmt, index: 5), !plain.isEmpty {
                value = plain
            } else if let encrypted = self.readBlob(stmt, index: 6) {
                value = self.decrypt(encrypted, usingAnyOf: keys)
            } else {
                value = nil
            }
            guard let value, !value.isEmpty else { continue }

            records.append(ChromiumCookieRecord(
                domain: self.normalizeDomain(hostKey),
                name: name,
                path: path,
                value: value,
                expires: self.chromiumExpiry(sqlite3_column_int64(stmt, 3)),
                isSecure: sqlite3_column_int(stmt, 4) != 0))
        }

        return records.filter { record in
            guard let expires = record.expires else { return true }
            return expires >= Date()
        }
    }

    private static func derivedKeys(for browser: Browser) throws -> [Data] {
        var keys: [Data] = []
        var sawDenied = false

        for label in browser.safeStorageLabels {
            switch KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account) {
            case .interactionRequired:
                sawDenied = true
                continue
            case .allowed, .notFound, .failure:
                break
            }

            if let password = self.safeStoragePassword(service: label.service, account: label.account) {
                keys.append(self.deriveKey(from: password))
            }
        }

        if !keys.isEmpty {
            return keys
        }
        if sawDenied {
            throw ImportError.keychainDenied(browser: browser)
        }
        throw ImportError.keyUnavailable(browser: browser)
    }

    private static func safeStoragePassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
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
        return key
    }

    private static func decrypt(_ encryptedValue: Data, usingAnyOf keys: [Data]) -> String? {
        for key in keys {
            if let value = self.decrypt(encryptedValue, key: key) {
                return value
            }
        }
        return nil
    }

    private static func decrypt(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = String(data: encryptedValue.prefix(3), encoding: .utf8)
        guard prefix == "v10" else { return nil }

        let payload = Data(encryptedValue.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outLength = 0
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
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

        if let value = String(data: out, encoding: .utf8), !value.isEmpty {
            return value
        }
        if out.count > 32 {
            let trimmed = out.dropFirst(32)
            if let value = String(data: trimmed, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func makeCookie(from record: ChromiumCookieRecord) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.domain,
            .path: record.path,
            .name: record.name,
            .value: record.value,
        ]
        if record.isSecure {
            properties[.secure] = true
        }
        if let expires = record.expires {
            properties[.expires] = expires
        }
        return HTTPCookie(properties: properties)
    }

    private static func readText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let value = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: value)
    }

    private static func readBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index)
        else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func normalizeDomain(_ domain: String) -> String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }

    private static func matches(domain: String, patterns: [String]) -> Bool {
        let normalized = self.normalizeDomain(domain)
        return patterns.contains { normalized.contains(self.normalizeDomain($0)) }
    }

    private static func chromiumExpiry(_ expiresUTC: Int64) -> Date? {
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif

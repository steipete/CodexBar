import Foundation

#if os(macOS)
import CommonCrypto
import Security
import SQLite3
import SweetCookieKit

enum AliyunOneConsoleChromiumCookieFallbackImporter {
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
        isAuthenticatedSession: ([HTTPCookie]) -> Bool,
        sessionLabel: String,
        cookieClient: BrowserCookieClient = BrowserCookieClient(),
        logger: ((String) -> Void)? = nil) throws -> AliyunOneConsoleCookieImporter.SessionInfo?
    {
        let stores = try cookieClient.codexBarStores(for: browser).filter { $0.databaseURL != nil }
        guard !stores.isEmpty else { return nil }

        logger?("Trying \(browser.displayName) Chromium fallback")
        let keys = try self.derivedKeys(for: browser)
        for store in stores {
            let cookies = try self.loadCookies(from: store, domains: domains, keys: keys)
            guard !cookies.isEmpty else { continue }
            if isAuthenticatedSession(cookies) {
                logger?("Found \(cookies.count) \(sessionLabel) cookies via \(store.label) fallback")
                return AliyunOneConsoleCookieImporter.SessionInfo(cookies: cookies, sourceLabel: store.label)
            }
        }
        return nil
    }

    private static func loadCookies(
        from store: BrowserCookieStore,
        domains: [String],
        keys: [Data]) throws -> [HTTPCookie]
    {
        guard let sourceDB = store.databaseURL else { return [] }
        let records = try self.readCookiesFromLockedDB(
            sourceDB: sourceDB,
            domains: domains,
            keys: keys,
            label: store.label)
        return records.compactMap(self.makeCookie)
    }

    private static func readCookiesFromLockedDB(
        sourceDB: URL,
        domains: [String],
        keys: [Data],
        label: String) throws -> [ChromiumCookieRecord]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aliyun-oneconsole-chromium-cookies-\(UUID().uuidString)", isDirectory: true)
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

            let value: String? = if let plain = self.readText(stmt, index: 5), !plain.isEmpty {
                plain
            } else if let encrypted = self.readBlob(stmt, index: 6) {
                self.decrypt(encrypted, usingAnyOf: keys)
            } else {
                nil
            }
            guard let value, !value.isEmpty else { continue }

            records.append(ChromiumCookieRecord(
                domain: AliyunOneConsoleCookieImporter.normalizeCookieDomain(hostKey),
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
            case .interactionRequired, .temporarilyUnavailable:
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
        // The preflight classifies prompt-requiring items as .interactionRequired, but its
        // .notFound (gate disabled) and .failure outcomes still reach this read. Honor the
        // access gate and keep the read strictly non-interactive so it can never prompt.
        guard !KeychainAccessGate.isDisabled else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
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

    private static func matches(domain: String, patterns: [String]) -> Bool {
        AliyunOneConsoleCookieImporter.matchesCookieDomain(domain, patterns: patterns)
    }

    private static func chromiumExpiry(_ expiresUTC: Int64) -> Date? {
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif

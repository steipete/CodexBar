import Foundation

#if os(macOS)
import SQLite3
import SweetCookieKit

enum AliyunOneConsoleChromiumCookieFallbackImporter {
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
        guard !stores.isEmpty, BrowserCookieAccessGate.shouldAttempt(browser) else { return nil }

        logger?("Trying \(browser.displayName) Chromium fallback")
        // Request keys only after a matching encrypted row, then reuse them across stores.
        var cachedKeys: [Data]?
        func keys() throws -> [Data] {
            if let cachedKeys { return cachedKeys }
            let derived = try self.derivedKeys(for: browser)
            cachedKeys = derived
            return derived
        }
        for store in stores {
            guard let sourceDB = store.databaseURL else { continue }
            let cookies = try self.readCookiesFromLockedDB(
                sourceDB: sourceDB, domains: domains, keys: keys, label: store.label).compactMap(self.makeCookie)
            guard !cookies.isEmpty else { continue }
            if isAuthenticatedSession(cookies) {
                logger?("Found \(cookies.count) \(sessionLabel) cookies via \(store.label) fallback")
                return AliyunOneConsoleCookieImporter.SessionInfo(cookies: cookies, sourceLabel: store.label)
            }
        }
        return nil
    }

    private static func readCookiesFromLockedDB(
        sourceDB: URL,
        domains: [String],
        keys: () throws -> [Data],
        label: String) throws -> [BrowserCookieRecord]
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
        keys: () throws -> [Data],
        label: String) throws -> [BrowserCookieRecord]
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

        var records: [BrowserCookieRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostKey = self.readText(stmt, index: 0), AliyunOneConsoleCookieImporter.matchesCookieDomain(
                hostKey,
                patterns: domains), let name = self.readText(stmt, index: 1),
                                    let path = self.readText(stmt, index: 2)
            else {
                continue
            }

            let value: String? = if let plain = self.readText(stmt, index: 5), !plain.isEmpty {
                plain
            } else if let encrypted = self.readBlob(stmt, index: 6) {
                try self.decrypt(encrypted, usingAnyOf: keys())
            } else {
                nil
            }
            guard let value, !value.isEmpty else { continue }

            records.append(BrowserCookieRecord(
                domain: AliyunOneConsoleCookieImporter.normalizeCookieDomain(hostKey),
                name: name,
                path: path,
                value: value,
                expires: self.chromiumExpiry(sqlite3_column_int64(stmt, 3)),
                isSecure: sqlite3_column_int(stmt, 4) != 0,
                isHTTPOnly: false))
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

            if let password = ChromiumSafeStorage.password(service: label.service, account: label.account) {
                keys.append(ChromiumSafeStorage.deriveKey(from: password))
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

    private static func decrypt(_ encryptedValue: Data, usingAnyOf keys: [Data]) -> String? {
        for key in keys {
            guard let data = ChromiumSafeStorage.decrypt(encryptedValue, key: key) else { continue }
            if let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
            if data.count > 32,
               let value = String(data: data.dropFirst(32), encoding: .utf8), !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func makeCookie(from record: BrowserCookieRecord) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.domain,
            .path: record.path,
            .name: record.name,
            .value: record.value,
        ]
        // Foundation treats the Secure attribute's presence as true, even when its value is false.
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

    private static func chromiumExpiry(_ expiresUTC: Int64) -> Date? {
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif

#if os(macOS)

import CommonCrypto
import Foundation
import Security
import SQLite3

enum ChromiumCookieFallbackReader {
    enum ReadError: LocalizedError {
        case keychainDenied
        case databaseUnavailable
        case queryFailed

        var errorDescription: String? {
            switch self {
            case .keychainDenied:
                "macOS Keychain denied access to browser safe storage."
            case .databaseUnavailable:
                "Chromium cookie database unavailable."
            case .queryFailed:
                "Chromium cookie query failed."
            }
        }
    }

    struct SessionKeyResult: Sendable {
        let key: String
        let cookieCount: Int
    }

    struct CookieRecord: Sendable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    static func loadSessionKey(
        databaseURL: URL,
        browserName: String,
        bundleIDs: [String],
        domains: [String],
        logger: ((String) -> Void)? = nil) throws -> SessionKeyResult?
    {
        let key = try self.safeStorageKey(browserName: browserName, bundleIDs: bundleIDs)
        let cookies = try self.readSessionCookies(
            databaseURL: databaseURL,
            domains: domains,
            key: key,
            logger: logger)
        if let sessionKey = ClaudeWebAPIFetcher.findSessionKey(in: cookies) {
            return SessionKeyResult(key: sessionKey, cookieCount: cookies.count)
        }
        return nil
    }

    static func loadCookies(
        databaseURL: URL,
        browserName: String,
        bundleIDs: [String],
        domains: [String],
        logger: ((String) -> Void)? = nil) throws -> [CookieRecord]
    {
        let key = try self.safeStorageKey(browserName: browserName, bundleIDs: bundleIDs)
        return try self.readCookies(
            databaseURL: databaseURL,
            domains: domains,
            key: key,
            logger: logger)
    }

    // MARK: - Keychain + crypto

    private static func safeStorageKey(browserName: String, bundleIDs: [String]) throws -> Data {
        let candidates = self.safeStorageLabels(browserName: browserName, bundleIDs: bundleIDs)
        var password: String?
        for candidate in candidates {
            if let found = self.findGenericPassword(service: candidate.service, account: candidate.account) {
                password = found
                break
            }
        }
        guard let password else {
            throw ReadError.keychainDenied
        }

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
        guard status == kCCSuccess else {
            throw ReadError.keychainDenied
        }
        return key
    }

    private static func safeStorageLabels(
        browserName: String,
        bundleIDs: [String]) -> [(service: String, account: String)]
    {
        let trimmedName = browserName.trimmingCharacters(in: .whitespacesAndNewlines)
        var bases = [trimmedName]
        bases.append(contentsOf: bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = Set<String>()
        return bases.compactMap { base in
            guard !base.isEmpty, seen.insert(base).inserted else { return nil }
            return (service: "\(base) Safe Storage", account: base)
        }
    }

    private static func findGenericPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decryptChromiumValue(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        let prefixString = String(data: prefix, encoding: .utf8)
        guard prefixString == "v10" || prefixString == "v11" else { return nil }
        let payload = encryptedValue.dropFirst(3)

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
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

        let candidate = out.count > 32 ? out.dropFirst(32) : out[...]
        if let decoded = String(data: Data(candidate), encoding: .utf8) {
            return self.cleanValue(decoded)
        }
        if let decoded = String(data: out, encoding: .utf8) {
            return self.cleanValue(decoded)
        }
        return nil
    }

    private static func cleanValue(_ value: String) -> String {
        var i = value.startIndex
        while i < value.endIndex, value[i].unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            i = value.index(after: i)
        }
        return String(value[i...])
    }

    // MARK: - SQLite

    private static func readSessionCookies(
        databaseURL: URL,
        domains: [String],
        key: Data,
        logger: ((String) -> Void)?) throws -> [(name: String, value: String)]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-chromium-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let copiedDB = tempDir.appendingPathComponent("Cookies")
        try? FileManager.default.removeItem(at: copiedDB)
        do {
            try FileManager.default.copyItem(at: databaseURL, to: copiedDB)
        } catch {
            throw ReadError.databaseUnavailable
        }

        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = URL(fileURLWithPath: copiedDB.path + suffix)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        var db: OpaquePointer?
        if sqlite3_open_v2(copiedDB.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            throw ReadError.queryFailed
        }
        defer { sqlite3_close(db) }

        let (sql, bindings) = self.sessionCookieSQL(domains: domains)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            throw ReadError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, value) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), value, -1, transient)
        }

        var results: [(name: String, value: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = Self.readTextColumn(stmt, index: 0) ?? ""
            let value = Self.readTextColumn(stmt, index: 1)
            let encrypted = Self.readBlobColumn(stmt, index: 2)

            if let value, !value.isEmpty {
                results.append((name: name, value: value))
                continue
            }
            if let encrypted, !encrypted.isEmpty,
               let decrypted = Self.decryptChromiumValue(encrypted, key: key)
            {
                results.append((name: name, value: decrypted))
                continue
            }
        }
        logger?("Chromium fallback read \(results.count) cookies")
        return results
    }

    private static func readCookies(
        databaseURL: URL,
        domains: [String],
        key: Data,
        logger: ((String) -> Void)?) throws -> [CookieRecord]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-chromium-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let copiedDB = tempDir.appendingPathComponent("Cookies")
        try? FileManager.default.removeItem(at: copiedDB)
        do {
            try FileManager.default.copyItem(at: databaseURL, to: copiedDB)
        } catch {
            throw ReadError.databaseUnavailable
        }

        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = URL(fileURLWithPath: copiedDB.path + suffix)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        var db: OpaquePointer?
        if sqlite3_open_v2(copiedDB.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            throw ReadError.queryFailed
        }
        defer { sqlite3_close(db) }

        let (sql, bindings) = self.cookieSQL(domains: domains)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            throw ReadError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, value) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), value, -1, transient)
        }

        var results: [CookieRecord] = []
        let now = Date()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hostKey = Self.readTextColumn(stmt, index: 0) ?? ""
            let name = Self.readTextColumn(stmt, index: 1) ?? ""
            let path = Self.readTextColumn(stmt, index: 2) ?? "/"
            let expiresUTC = sqlite3_column_int64(stmt, 3)
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

            let expires = Self.chromeExpiryDate(expiresUTC: expiresUTC)
            if let expires, expires <= now {
                continue
            }

            results.append(CookieRecord(
                domain: hostKey,
                name: name,
                path: path,
                value: value,
                expires: expires,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly))
        }
        logger?("Chromium fallback read \(results.count) cookies")
        return results
    }

    private static func sessionCookieSQL(domains: [String]) -> (String, [String]) {
        let filtered = domains.filter { !$0.isEmpty }
        if filtered.isEmpty {
            return ("SELECT name, value, encrypted_value FROM cookies WHERE name='sessionKey'", [])
        }
        let clauses = filtered.map { _ in "host_key LIKE ?" }.joined(separator: " OR ")
        let sql =
            "SELECT name, value, encrypted_value FROM cookies " +
            "WHERE name='sessionKey' AND (\(clauses))"
        let bindings = filtered.map { "%\($0)%" }
        return (sql, bindings)
    }

    private static func cookieSQL(domains: [String]) -> (String, [String]) {
        let filtered = domains.filter { !$0.isEmpty }
        let base = """
        SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
        FROM cookies
        """
        if filtered.isEmpty {
            return (base, [])
        }
        let clauses = filtered.map { _ in "host_key LIKE ?" }.joined(separator: " OR ")
        let sql = base + " WHERE \(clauses)"
        let bindings = filtered.map { "%\($0)%" }
        return (sql, bindings)
    }

    private static func chromeExpiryDate(expiresUTC: Int64) -> Date? {
        if expiresUTC <= 0 { return nil }
        let secondsSince1601 = Double(expiresUTC) / 1_000_000.0
        let unixEpochOffset = 11_644_473_600.0
        let unixSeconds = secondsSince1601 - unixEpochOffset
        return Date(timeIntervalSince1970: unixSeconds)
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
}

#endif

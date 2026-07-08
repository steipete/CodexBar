import Foundation
#if os(macOS)
import CommonCrypto
import Security
import SQLite3

enum MiniMaxDesktopCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.minimaxCookie)
    private static let sourceLabel = "MiniMax Agent"
    private static let webCookieHosts: Set<String> = [
        "www.minimaxi.com",
        "www.minimax.io",
        "platform.minimaxi.com",
        "platform.minimax.io",
    ]
    private static let safeStorageLabels: [(service: String, account: String)] = [
        ("MiniMax Safe Storage", "MiniMax"),
        ("Chromium Safe Storage", "MiniMax"),
    ]

    static func cookiesDatabaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiniMax/Cookies")
    }

    static func importSession(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default,
        decryptionKeys: [Data]? = nil) -> MiniMaxCookieImporter.SessionInfo?
    {
        let url = databaseURL ?? self.cookiesDatabaseURL(fileManager: fileManager)
        guard fileManager.isReadableFile(atPath: url.path) else { return nil }
        do {
            let records = try self.loadRecords(from: url, decryptionKeys: decryptionKeys)
            guard !records.isEmpty else { return nil }
            let cookies = self.makeHTTPCookies(from: records)
            guard !cookies.isEmpty else { return nil }
            self.log.debug(
                "Imported MiniMax desktop cookies",
                metadata: ["count": "\(cookies.count)", "names": self.cookieNames(from: cookies)])
            return MiniMaxCookieImporter.SessionInfo(cookies: cookies, sourceLabel: self.sourceLabel)
        } catch {
            self.log.debug("MiniMax desktop cookie import failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Record {
        let domain: String
        let name: String
        let value: String
    }

    private static func loadRecords(from url: URL, decryptionKeys: [Data]? = nil) throws -> [Record] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw MiniMaxDesktopCookieImportError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT host_key, name, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE '%minimax%'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw MiniMaxDesktopCookieImportError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [Record] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let domain = self.columnText(stmt, index: 0),
                  let name = self.columnText(stmt, index: 1),
                  self.matchesMiniMaxDomain(domain)
            else {
                continue
            }
            let plain = self.columnText(stmt, index: 2) ?? ""
            let value: String? = if !plain.isEmpty {
                plain
            } else if let encrypted = self.readBlob(stmt, index: 3) {
                self.decrypt(encrypted, keys: decryptionKeys ?? self.derivedKeys())
            } else {
                nil
            }
            guard let value, !value.isEmpty else { continue }
            records.append(Record(domain: domain, name: name, value: value))
        }
        return self.deduplicated(records)
    }

    private static func deduplicated(_ records: [Record]) -> [Record] {
        var merged: [String: Record] = [:]
        for record in records {
            let key = "\(record.name)|\(record.domain)"
            merged[key] = record
        }
        return Array(merged.values).sorted {
            if $0.name == $1.name { return $0.domain < $1.domain }
            if $0.name == "_token" { return true }
            if $1.name == "_token" { return false }
            return $0.name < $1.name
        }
    }

    private static func matchesMiniMaxDomain(_ domain: String) -> Bool {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if self.webCookieHosts.contains(normalized) { return true }
        return normalized == "minimaxi.com" || normalized == "minimax.io"
    }

    private static func makeHTTPCookies(from records: [Record]) -> [HTTPCookie] {
        records.compactMap { record in
            let domain = record.domain.hasPrefix(".") ? String(record.domain.dropFirst()) : record.domain
            guard let cookie = HTTPCookie(properties: [
                .domain: domain,
                .name: record.name,
                .path: "/",
                .value: record.value,
                .secure: "TRUE",
            ]) else {
                return nil
            }
            return cookie
        }
    }

    private static func cookieNames(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ", ")
    }

    private static func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let value = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: value)
    }

    private static func readBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, index))
        guard length > 0, let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: length)
    }

    private static func derivedKeys() -> [Data] {
        var keys: [Data] = []
        for label in self.safeStorageLabels {
            if let password = self.safeStoragePassword(service: label.service, account: label.account) {
                keys.append(self.deriveKey(from: password))
            }
        }
        return keys
    }

    private static func safeStoragePassword(service: String, account: String) -> String? {
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

    private static func decrypt(_ encryptedValue: Data, keys: [Data]) -> String? {
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
}

enum MiniMaxDesktopCookieImportError: LocalizedError {
    case sqliteFailed(String)

    var errorDescription: String? {
        switch self {
        case let .sqliteFailed(message):
            "MiniMax desktop cookie database read failed: \(message)"
        }
    }
}
#endif

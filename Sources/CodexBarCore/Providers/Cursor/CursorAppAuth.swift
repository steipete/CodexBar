import Foundation

#if os(macOS)
#if canImport(SQLite3)
import SQLite3
#endif
#endif

#if os(macOS) || os(Linux)
struct CursorSessionIdentity: Equatable, Sendable {
    let subject: String?
    let email: String?

    var requestUsageUserID: String? {
        Self.normalizedSubject(self.subject)
    }

    var displayLabel: String? {
        Self.normalizedEmail(self.email) ?? Self.normalizedSubject(self.subject)
    }

    func differs(from other: Self) -> Bool? {
        if let lhs = Self.normalizedSubject(self.subject),
           let rhs = Self.normalizedSubject(other.subject)
        {
            return lhs != rhs
        }
        if let lhs = Self.normalizedEmail(self.email),
           let rhs = Self.normalizedEmail(other.email)
        {
            return lhs != rhs
        }
        return nil
    }

    static func from(cookieHeader: String) -> Self? {
        for component in cookieHeader.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == "WorkosCursorSessionToken" else { continue }

            let encodedValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = encodedValue.removingPercentEncoding ?? encodedValue
            let parts = value.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            let token = parts.last ?? ""
            if let identity = try? Self(jwt: token) {
                return identity
            }

            let userID = parts.first
            if let userID, !userID.isEmpty {
                return Self(subject: userID, email: nil)
            }
        }
        return nil
    }

    init(subject: String?, email: String?) {
        self.subject = subject
        self.email = email
    }

    init(jwt: String) throws {
        let json = try Self.payload(jwt: jwt)
        self.init(subject: json["sub"] as? String, email: json["email"] as? String)
    }

    static func payload(jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is not a JWT")
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token has an invalid payload")
        }
        return json
    }

    private static func normalizedSubject(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init)?.lowercased()
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
#endif

#if os(macOS)
struct CursorAppAuthSession: Equatable, Sendable {
    static let persistedCookieMarker = "CodexBar Cursor.app local auth"

    let accessToken: String

    static func from(cookieHeader: String) -> Self? {
        for component in cookieHeader.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "WorkosCursorSessionToken"
            else { continue }
            let encodedValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = encodedValue.removingPercentEncoding ?? encodedValue
            let parts = value.components(separatedBy: "::")
            guard parts.count >= 2,
                  let token = parts.last,
                  token.split(separator: ".", omittingEmptySubsequences: false).count >= 2
            else { return nil }
            return Self(accessToken: token)
        }
        return nil
    }

    var identity: CursorSessionIdentity? {
        try? CursorSessionIdentity(jwt: self.accessToken)
    }

    var isUsable: Bool {
        guard !self.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? self.userID()) != nil,
              let expiresAt = try? self.expiresAt()
        else {
            return false
        }
        return expiresAt.timeIntervalSinceNow > 60
    }

    func cookieHeader() throws -> String {
        try "WorkosCursorSessionToken=\(self.userID())%3A%3A\(self.accessToken)"
    }

    func userID() throws -> String {
        let json = try self.payload()
        guard let subject = json["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is missing a user ID")
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token has an invalid user ID")
        }
        return userID
    }

    func expiresAt() throws -> Date {
        let json = try self.payload()
        guard let expiration = json["exp"] as? NSNumber else {
            throw CursorStatusProbeError.parseFailed("Cursor.app access token is missing an expiration")
        }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }

    func makeCookie() throws -> HTTPCookie {
        let properties: [HTTPCookiePropertyKey: Any] = try [
            .name: "WorkosCursorSessionToken",
            .value: "\(self.userID())%3A%3A\(self.accessToken)",
            .domain: "cursor.com",
            .path: "/",
            .expires: self.expiresAt(),
            .secure: true,
            .comment: Self.persistedCookieMarker,
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            throw CursorStatusProbeError.parseFailed("Cursor.app session cookie could not be created")
        }
        return cookie
    }

    static func isPersistedCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "WorkosCursorSessionToken" && cookie.comment == self.persistedCookieMarker
    }

    private func payload() throws -> [String: Any] {
        try CursorSessionIdentity.payload(jwt: self.accessToken)
    }
}

protocol CursorAppAuthSessionProviding: Sendable {
    func loadSession() throws -> CursorAppAuthSession?
}

struct CursorAppAuthStore: CursorAppAuthSessionProviding {
    private static let defaultDBPath: String = Self.resolveDefaultDBPath()

    private let dbPath: String

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? Self.defaultDBPath
    }

    static func resolveDefaultDBPath(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> String
    {
        #if os(macOS)
        _ = environment
        _ = fileManager
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        #elseif os(Linux)
        let configHome = environment[CodexBarConfigStore.xdgConfigHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedConfigHome = configHome.map { ($0 as NSString).expandingTildeInPath }
        let base: String = if let expandedConfigHome,
                              !expandedConfigHome.isEmpty,
                              (expandedConfigHome as NSString).isAbsolutePath
        {
            expandedConfigHome
        } else {
            "\(home)/.config"
        }
        return "\(base)/Cursor/User/globalStorage/state.vscdb"
        #else
        _ = home
        _ = environment
        _ = fileManager
        return ""
        #endif
    }

    func loadSession() throws -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: self.dbPath) else { return nil }
        guard let accessToken = try self.value(for: "cursorAuth/accessToken"),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return CursorAppAuthSession(accessToken: accessToken)
    }

    private func value(for key: String) throws -> String? {
        do {
            return try self.value(for: key, immutable: false)
        } catch let failure as SQLiteReadFailure {
            // An idle WAL database can retain WAL mode in its header after both sidecars disappear.
            // Immutable mode reads that main file without recreating sidecars. Never use it while a WAL exists,
            // because doing so would ignore live, uncheckpointed Cursor state.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing else {
                throw CursorStatusProbeError.networkError("SQLite error reading Cursor app auth: \(failure.message)")
            }
            do {
                return try self.value(for: key, immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                throw CursorStatusProbeError.networkError(
                    "SQLite error reading Cursor app auth: \(fallbackFailure.message)")
            }
        }
    }

    private func value(for key: String, immutable: Bool) throws -> String? {
        var db: OpaquePointer?
        let databaseURL = URL(fileURLWithPath: self.dbPath, isDirectory: false).absoluteURL
        let filename = immutable ? "\(databaseURL.absoluteString)?immutable=1" : self.dbPath
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            let failure = Self.sqliteFailure(db: db, resultCode: openResult)
            sqlite3_close(db)
            throw failure
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_ROW else {
            if stepResult == SQLITE_DONE {
                return nil
            }
            throw Self.sqliteFailure(db: db, resultCode: stepResult)
        }
        return Self.decodeSQLiteValue(stmt: stmt, index: 0)
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
            // ASCII UTF16LE is also valid UTF8 with NULs, so the fallback below cannot recognize it.
            if data.count.isMultiple(of: 2),
               stride(from: 0, to: data.count, by: 2).allSatisfy({
                   (1..<128).contains(data[$0]) && data[$0 + 1] == 0
               }),
               let decoded = String(data: data, encoding: .utf16LittleEndian),
               // Keep invalid-but-present tokens present: a missing session permits cached-account fallback.
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return decoded
            }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }

    private var walSidecarsAreMissing: Bool {
        !FileManager.default.fileExists(atPath: self.dbPath + "-wal") &&
            !FileManager.default.fileExists(atPath: self.dbPath + "-shm")
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        let code = db.map(sqlite3_errcode) ?? resultCode
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return SQLiteReadFailure(code: code, message: message)
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

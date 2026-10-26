import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
struct CursorSessionIdentity: Equatable, Sendable {
    let subject: String?
    let email: String?

    var requestUsageUserID: String? {
        Self.normalizedSubject(self.subject)
    }

    var displayLabel: String? {
        Self.normalizedValue(self.email) ?? Self.normalizedSubject(self.subject)
    }

    func differs(from other: Self) -> Bool? {
        if let lhs = Self.normalizedSubject(self.subject),
           let rhs = Self.normalizedSubject(other.subject)
        {
            return lhs != rhs
        }
        if let lhs = Self.normalizedValue(self.email),
           let rhs = Self.normalizedValue(other.email)
        {
            return lhs != rhs
        }
        return nil
    }

    static func from(cookieHeader: String) -> Self? {
        for parts in self.sessionTokenComponents(cookieHeader) {
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

    fileprivate static func sessionTokenComponents(_ cookieHeader: String) -> [[String]] {
        cookieHeader.split(separator: ";").compactMap { component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "WorkosCursorSessionToken"
            else { return nil }
            let encoded = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (encoded.removingPercentEncoding ?? encoded).components(separatedBy: "::")
        }
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
        self.normalizedValue(value)?.split(separator: "|", omittingEmptySubsequences: true).last
            .map(String.init)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
#endif

#if os(macOS) || os(Linux)
struct CursorAppAuthSession: Equatable, Sendable {
    static let persistedCookieMarker = "CodexBar Cursor.app local auth"

    let accessToken: String

    static func from(cookieHeader: String) -> Self? {
        for parts in CursorSessionIdentity.sessionTokenComponents(cookieHeader) {
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
        let json = try CursorSessionIdentity.payload(jwt: self.accessToken)
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
        let json = try CursorSessionIdentity.payload(jwt: self.accessToken)
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
        home: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        #if os(macOS)
        _ = environment
        return "\(home ?? NSHomeDirectory())/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        #elseif os(Linux)
        return "\(self.linuxConfigHome(home: home, environment: environment))/Cursor/User/globalStorage/state.vscdb"
        #endif
    }

    #if os(Linux)
    /// An absolute `XDG_CONFIG_HOME`, else `.config` in the home `resolveLinuxHome` picks.
    static func linuxConfigHome(home: String?, environment: [String: String]) -> String {
        let configHome = environment[CodexBarConfigStore.xdgConfigHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configHome,
           !configHome.isEmpty,
           configHome.hasPrefix("/")
        {
            return configHome
        }
        return "\(self.resolveLinuxHome(home: home, environment: environment))/.config"
    }

    /// Prefer an injected home, then an absolute process `HOME`, then the account database home.
    private static func resolveLinuxHome(
        home: String?,
        environment: [String: String]) -> String
    {
        if let home {
            return home
        }

        let envHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envHome,
           !envHome.isEmpty,
           envHome.hasPrefix("/")
        {
            return envHome
        }

        return NSHomeDirectory()
    }
    #endif

    func loadSession() throws -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: self.dbPath),
              let accessToken = try self.accessToken(),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        #if os(macOS)
        let prefix = "cursor-safe-storage:v1:"
        if accessToken.hasPrefix(prefix),
           let encrypted = Data(base64Encoded: String(accessToken.dropFirst(prefix.count))),
           encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
           (encrypted.count - 3).isMultiple(of: 16),
           let password = ChromiumSafeStorage.password(
               service: "Cursor Safe Storage",
               account: "Cursor",
               allowPrompt: true),
           let plaintext = ChromiumSafeStorage.decrypt(encrypted, key: ChromiumSafeStorage.deriveKey(from: password)),
           let decoded = String(data: plaintext, encoding: .utf8)
        {
            return CursorAppAuthSession(accessToken: decoded)
        }
        #endif
        // Preserve an unusable session on decryption failure so stale persisted app auth cannot replace it.
        return CursorAppAuthSession(accessToken: accessToken.hasPrefix("cursor-safe-storage:") ? "" : accessToken)
    }

    private func accessToken() throws -> String? {
        do {
            return try self.accessToken(immutable: false)
        } catch let failure as SQLiteReadFailure {
            // An idle WAL database can retain WAL mode in its header after both sidecars disappear.
            // Immutable mode reads that main file without recreating sidecars. Never use it while a WAL exists,
            // because doing so would ignore live, uncheckpointed Cursor state.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing else {
                throw CursorStatusProbeError.networkError("SQLite error reading Cursor app auth: \(failure.message)")
            }
            do {
                return try self.accessToken(immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                throw CursorStatusProbeError.networkError(
                    "SQLite error reading Cursor app auth: \(fallbackFailure.message)")
            }
        }
    }

    private func accessToken(immutable: Bool) throws -> String? {
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

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

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
#endif

#if os(Linux)
/// The session `cursor-agent login` keeps in `cursor/auth.json` under the config home, for machines with the
/// Cursor CLI and no Cursor.app. Read-only, like the app database: CodexBar never refreshes or writes it.
struct CursorAgentAuthStore: CursorAppAuthSessionProviding {
    private let path: String

    init(path: String? = nil) {
        self.path = path ?? Self.resolveDefaultPath()
    }

    static func resolveDefaultPath(
        home: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        "\(CursorAppAuthStore.linuxConfigHome(home: home, environment: environment))/cursor/auth.json"
    }

    func loadSession() throws -> CursorAppAuthSession? {
        guard let data = FileManager.default.contents(atPath: self.path) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorStatusProbeError.parseFailed("cursor-agent auth file is not a JSON object")
        }
        guard let accessToken = (json["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            return nil
        }
        return CursorAppAuthSession(accessToken: accessToken)
    }
}

#endif

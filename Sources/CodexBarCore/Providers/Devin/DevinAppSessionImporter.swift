import Foundation
#if os(macOS)
import SQLite3
#endif

#if os(macOS)
/// Imports the Devin session kept by the Devin desktop app (Devin.app).
///
/// Devin.app embeds app.devin.ai inside an Electron partition and never writes an
/// `auth1_session`/Auth0 token to the Chromium local storage store CodexBar scans for
/// browsers. Its signed-in session lives in the app's VS Code-style secret storage
/// (`User/globalStorage/state.vscdb`, `secret://{"extensionId":…,"key":"windsurf_auth.sessions"}`),
/// AES-128-CBC encrypted with the `Devin Safe Storage` Keychain password like Chromium
/// `v10` cookie values. Reading it follows the same Safe Storage access gate as cookie
/// imports: background refreshes stay non-interactive and only explicit retries may
/// trigger the macOS prompt.
struct DevinAppSessionImporter {
    static let sourceLabel = "Devin app"

    private static let safeStorageService = "Devin Safe Storage"
    private static let safeStorageAccount = "Devin Key"
    private static let sessionsSecretName = "windsurf_auth.sessions"
    private static let appSupportDirectory = "Library/Application Support/Devin"
    private static let stateDatabasePath = "User/globalStorage/state.vscdb"
    private static let localStoragePath = "Local Storage/leveldb"

    private let dbPath: String
    private let localStorageURL: URL

    init(dbPath: String? = nil, localStorageURL: URL? = nil, home: String = NSHomeDirectory()) {
        // CODEXBAR_DEVIN_APP_HOME points the importer at another Devin.app data root for
        // diagnostics or isolated verification (same idea as CODEXBAR_CONFIG for the CLI).
        let effectiveHome = ProcessInfo.processInfo.environment["CODEXBAR_DEVIN_APP_HOME"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? home
        let root = URL(fileURLWithPath: effectiveHome).appendingPathComponent(Self.appSupportDirectory)
        self.dbPath = dbPath ?? root.appendingPathComponent(Self.stateDatabasePath).path
        self.localStorageURL = localStorageURL ?? root.appendingPathComponent(Self.localStoragePath)
    }

    func importSessions(
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) -> [DevinSessionImporter.SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[devin-storage] \(msg)") }
        var itemTableKeys: [String] = []
        var secretBlobs: [Data] = []
        do {
            let rows = try self.itemTableRows()
            itemTableKeys = rows.map(\.key)
            secretBlobs = rows
                .filter { $0.key.hasPrefix("secret://") && $0.key.contains(Self.sessionsSecretName) }
                .compactMap { Self.bufferData(fromSecretValue: $0.value) }
        } catch {
            log("Devin app database unreadable: \(error.localizedDescription)")
        }

        var tokens: [String] = []
        for payload in self.decryptedSessionsPayloads(secretBlobs: secretBlobs, logger: log) {
            for token in Self.accessTokens(fromSessionsPayload: payload) where !tokens.contains(token) {
                tokens.append(token)
            }
        }
        guard !tokens.isEmpty else {
            log("No Devin app session found in app secret storage")
            return []
        }
        let orgInfo = self.organizationInfo(
            organizationOverride: organizationOverride,
            itemTableKeys: itemTableKeys,
            logger: log)
        log("Found Devin app session; internalOrganizationID=\(orgInfo.internalOrganizationID != nil)")
        return tokens.map {
            DevinSessionImporter.SessionInfo(
                accessToken: $0,
                organization: orgInfo.organization,
                internalOrganizationID: orgInfo.internalOrganizationID,
                sourceLabel: Self.sourceLabel)
        }
    }

    // MARK: - Secret storage

    private func decryptedSessionsPayloads(
        secretBlobs: [Data],
        logger: @escaping (String) -> Void) -> [String]
    {
        guard !secretBlobs.isEmpty else { return [] }
        guard let password = ChromiumSafeStorage.password(
            service: Self.safeStorageService,
            account: Self.safeStorageAccount,
            allowPrompt: true)
        else {
            logger("Devin app session found but its Safe Storage key is unavailable")
            return []
        }
        let key = ChromiumSafeStorage.deriveKey(from: password)
        return secretBlobs.compactMap {
            guard let data = ChromiumSafeStorage.decrypt($0, key: key),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
    }

    /// Values of `secret://{"extensionId":…,"key":"windsurf_auth.sessions"}` rows, which VS Code
    /// secret storage writes as `{"type":"Buffer","data":[…]}` where bytes are a `v10` blob.
    private static func bufferData(fromSecretValue raw: String) -> Data? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let bytes = object["data"] as? [Any] {
            return Data(bytes.compactMap { ($0 as? NSNumber)?.uint8Value })
        }
        if let base64 = object["data"] as? String {
            return Data(base64Encoded: base64)
        }
        return nil
    }

    /// VS Code authentication sessions serialize as `[{id, accessToken, account, scopes}]`.
    static func accessTokens(fromSessionsPayload payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var tokens: [String] = []
        self.collectAccessTokens(in: object, into: &tokens)
        return tokens
    }

    private static func collectAccessTokens(in object: Any, into tokens: inout [String]) {
        if let dictionary = object as? [String: Any],
           let token = dictionary["accessToken"] as? String
        {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !tokens.contains(value) {
                tokens.append(value)
            }
        }
        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                self.collectAccessTokens(in: value, into: &tokens)
            }
        }
        if let array = object as? [Any] {
            for value in array {
                self.collectAccessTokens(in: value, into: &tokens)
            }
        }
    }

    // MARK: - Organization

    private func organizationInfo(
        organizationOverride: String?,
        itemTableKeys: [String],
        logger: @escaping (String) -> Void) -> (organization: String?, internalOrganizationID: String?)
    {
        // Devin.app keeps the same organization metadata keys as browser sessions.
        if let storage = try? DevinSessionImporter.readLocalStorage(from: self.localStorageURL),
           !storage.isEmpty
        {
            let info = DevinSessionImporter.organizationInfo(
                from: storage,
                organizationOverride: organizationOverride)
            if info.organization != nil || info.internalOrganizationID != nil {
                return info
            }
        }

        // An explicit selection decides the organization; a database key scoped to another
        // organization's internal id must not ride along under the selected name.
        if let override = DevinUsageFetcher.normalizedOrganization(organizationOverride) {
            guard override.hasPrefix("organizations/") else { return (override, nil) }
            return (override, String(override.dropFirst("organizations/".count)))
        }

        // The app database scopes several rows by internal org id (devin.desktopShell.….org-…).
        // A single distinct id is unambiguous; several mean the caller must pick one explicitly.
        let ids = Set(itemTableKeys.compactMap(Self.internalOrganizationID))
        if ids.count == 1, let id = ids.first {
            return ("organizations/\(id)", id)
        }
        if !ids.isEmpty {
            logger("Devin app database references \(ids.count) organizations; keeping none")
        }
        return (nil, nil)
    }

    static func internalOrganizationID(in text: String) -> String? {
        guard let range = text.range(of: #"org[-_][A-Za-z0-9]{8,}"#, options: .regularExpression) else {
            return nil
        }
        let value = String(text[range])
        return DevinUsageFetcher.isInternalOrganizationID(value) ? value : nil
    }

    // MARK: - state.vscdb access

    private struct ItemRow {
        let key: String
        let value: String
    }

    private func itemTableRows() throws -> [ItemRow] {
        guard FileManager.default.fileExists(atPath: self.dbPath) else { return [] }
        do {
            return try self.itemTableRows(immutable: false)
        } catch let failure as SQLiteReadFailure {
            // An idle WAL database can retain WAL mode in its header after both sidecars disappear.
            // Immutable mode reads that main file without recreating sidecars. Never use it while a WAL exists,
            // because doing so would ignore live, uncheckpointed app state.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing else { throw failure }
            return try self.itemTableRows(immutable: true)
        }
    }

    private func itemTableRows(immutable: Bool) throws -> [ItemRow] {
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

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db,
            "SELECT key, value FROM ItemTable WHERE key LIKE 'secret://%' " +
                "OR key LIKE '%org-%' OR key LIKE '%org\\_%' ESCAPE '\\';",
            -1,
            &stmt,
            nil)
        guard prepareResult == SQLITE_OK else {
            defer { sqlite3_finalize(stmt) }
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [ItemRow] = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw Self.sqliteFailure(db: db, resultCode: stepResult)
            }
            guard let key = Self.decodeSQLiteValue(stmt: stmt, index: 0),
                  let value = Self.decodeSQLiteValue(stmt: stmt, index: 1)
            else { continue }
            rows.append(ItemRow(key: key, value: value))
        }
        return rows
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
            // ASCII UTF16LE is also valid UTF8 with NULs, so check the stricter decode first.
            if data.count.isMultiple(of: 2),
               stride(from: 0, to: data.count, by: 2).allSatisfy({
                   (1..<128).contains(data[$0]) && data[$0 + 1] == 0
               }),
               let decoded = String(data: data, encoding: .utf16LittleEndian)
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

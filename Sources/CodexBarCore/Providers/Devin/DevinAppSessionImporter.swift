import Foundation
#if os(macOS)
import SQLite3
import SweetCookieKit
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
/// imports, but never requests interaction, including during manual retries.
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
        let root = URL(fileURLWithPath: home).appendingPathComponent(Self.appSupportDirectory)
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
                .filter { Self.isSessionKey($0.key) }
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
        // Keep legacy ACL preflight while refusing escalation even during explicit refreshes.
        guard let password = BrowserCookieKeychainAccessGate.withUserInteractionDisallowed({
            ChromiumSafeStorage.password(
                service: Self.safeStorageService,
                account: Self.safeStorageAccount,
                allowPrompt: true)
        })
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

    private static func isSessionKey(_ key: String) -> Bool {
        guard key.hasPrefix("secret://"),
              let data = String(key.dropFirst("secret://".count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["key"] as? String == Self.sessionsSecretName
    }

    /// Validate the Electron Buffer and v10 AES-CBC framing before consulting Safe Storage.
    private static func bufferData(fromSecretValue raw: String) -> Data? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "Buffer",
              let numbers = object["data"] as? [NSNumber],
              numbers.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() })
        else { return nil }
        let bytes = numbers.compactMap { UInt8(exactly: $0.doubleValue) }
        guard bytes.count == numbers.count, bytes.count > 3,
              (bytes.count - 3).isMultiple(of: 16), bytes.starts(with: "v10".utf8)
        else { return nil }
        return Data(bytes)
    }

    /// VS Code authentication sessions serialize as `[{id, accessToken, account, scopes}]`.
    static func accessTokens(fromSessionsPayload payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var tokens: [String] = []
        for session in sessions {
            guard let token = session["accessToken"] as? String else { continue }
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !tokens.contains(value) { tokens.append(value) }
        }
        return tokens
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
        let source = URL(fileURLWithPath: self.dbPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("state.vscdb")
        try FileManager.default.copyItem(at: source, to: copy)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        return try self.itemTableRows(at: copy)
    }

    private func itemTableRows(at url: URL) throws -> [ItemRow] {
        var db: OpaquePointer?
        // Read-only SQLite connections can still create sidecars. Only open the disposable copy.
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
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
                "OR key LIKE 'devin.desktopShell.%';",
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
            guard let key = Self.decodeSQLiteValue(stmt: stmt, index: 0) else { continue }
            if Self.isSessionKey(key), let value = Self.decodeSQLiteValue(stmt: stmt, index: 1) {
                rows.append(ItemRow(key: key, value: value))
            } else if key.hasPrefix("devin.desktopShell.") {
                rows.append(ItemRow(key: key, value: ""))
            }
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

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(code: db.map(sqlite3_errcode) ?? resultCode)
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
    }
}
#endif

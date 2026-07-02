import Foundation
#if os(macOS)
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

    static func cookiesDatabaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiniMax/Cookies")
    }

    static func importSession(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default) -> MiniMaxCookieImporter.SessionInfo?
    {
        let url = databaseURL ?? self.cookiesDatabaseURL(fileManager: fileManager)
        guard fileManager.isReadableFile(atPath: url.path) else { return nil }
        do {
            let records = try self.loadRecords(from: url)
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

    private static func loadRecords(from url: URL) throws -> [Record] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw MiniMaxDesktopCookieImportError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT host_key, name, value
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
                  let value = self.columnText(stmt, index: 2),
                  !value.isEmpty,
                  self.matchesMiniMaxDomain(domain)
            else {
                continue
            }
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
        return self.webCookieHosts.contains(normalized)
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

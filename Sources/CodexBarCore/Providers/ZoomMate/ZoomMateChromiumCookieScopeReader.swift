import Foundation

#if os(macOS)
import SQLite3
import SweetCookieKit

private let zoomMateSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ZoomMateChromiumCookieScopeReader {
    enum CookieScope: Hashable, Sendable {
        case domain
        case hostOnly
    }

    struct ScopedCookie: Sendable {
        let record: BrowserCookieRecord
        let scope: CookieScope
    }

    struct CookieMetadata: Sendable {
        let hostKey: String
        let topFrameSiteKey: String
        let name: String
        let path: String
    }

    struct Source: Sendable {
        let label: String
        let cookies: [ScopedCookie]
    }

    enum ReadError: LocalizedError {
        case missingDatabase(label: String)
        case sqliteFailed(label: String, details: String)

        var errorDescription: String? {
            switch self {
            case let .missingDatabase(label):
                "\(label) has no Chromium cookie database."
            case let .sqliteFailed(label, details):
                "\(label) cookie scope read failed: \(details)"
            }
        }
    }

    private struct CookieKey: Hashable {
        let domain: String
        let name: String
        let path: String
    }

    private struct ScopeResolution {
        var scopes: Set<CookieScope> = []
        var hasPartitionedRecord = false
    }

    private static let rawDomains = [
        ".zoom.us",
        "zoom.us",
        ".ai.zoom.us",
        "ai.zoom.us",
        ".zoommate.zoom.us",
        "zoommate.zoom.us",
    ]

    static func read(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        cookieClient: BrowserCookieClient,
        logger: ((String) -> Void)? = nil) throws -> [Source]
    {
        let stores = try cookieClient.codexBarStores(for: browser)
            .filter { $0.databaseURL != nil }
        var sources: [Source] = []

        for store in stores {
            try self.withSnapshot(of: store) { snapshotStore in
                let records = try cookieClient.codexBarRecords(
                    matching: query,
                    in: snapshotStore,
                    logger: logger)
                guard !records.isEmpty else { return }

                let metadata = try self.readMetadata(from: snapshotStore)
                let cookies = self.resolve(records: records, metadata: metadata, logger: logger)
                guard !cookies.isEmpty else { return }
                sources.append(Source(label: store.label, cookies: cookies))
            }
        }

        return sources
    }

    static func resolve(
        records: [BrowserCookieRecord],
        metadata: [CookieMetadata],
        logger: ((String) -> Void)? = nil) -> [ScopedCookie]
    {
        var resolutionByKey: [CookieKey: ScopeResolution] = [:]
        for item in metadata {
            let rawHost = item.hostKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let domain = self.normalizedDomain(rawHost)
            guard !domain.isEmpty else { continue }

            let key = CookieKey(domain: domain, name: item.name, path: item.path)
            var resolution = resolutionByKey[key] ?? ScopeResolution()
            resolution.scopes.insert(rawHost.hasPrefix(".") ? .domain : .hostOnly)
            if !item.topFrameSiteKey.isEmpty {
                resolution.hasPartitionedRecord = true
            }
            resolutionByKey[key] = resolution
        }

        var missing = 0
        var ambiguous = 0
        var partitioned = 0
        let resolved = records.compactMap { record -> ScopedCookie? in
            let key = CookieKey(
                domain: self.normalizedDomain(record.domain),
                name: record.name,
                path: record.path)
            guard let resolution = resolutionByKey[key] else {
                missing += 1
                return nil
            }
            guard !resolution.hasPartitionedRecord else {
                partitioned += 1
                return nil
            }
            guard resolution.scopes.count == 1, let scope = resolution.scopes.first else {
                ambiguous += 1
                return nil
            }
            return ScopedCookie(record: record, scope: scope)
        }

        if missing > 0 || ambiguous > 0 || partitioned > 0 {
            logger?(
                "Dropped unresolved Chrome cookies " +
                    "(missing: \(missing), ambiguous scope: \(ambiguous), partitioned: \(partitioned))")
        }
        return resolved
    }

    private static func withSnapshot<T>(
        of store: BrowserCookieStore,
        operation: (BrowserCookieStore) throws -> T) throws -> T
    {
        guard let sourceDB = store.databaseURL else {
            throw ReadError.missingDatabase(label: store.label)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-zoommate-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let copiedDB = directory.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: sourceDB, to: copiedDB)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: sourceDB.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(
                at: source,
                to: URL(fileURLWithPath: copiedDB.path + suffix))
        }

        let snapshotStore = BrowserCookieStore(
            browser: store.browser,
            profile: store.profile,
            kind: store.kind,
            label: store.label,
            databaseURL: copiedDB)
        return try operation(snapshotStore)
    }

    private static func readMetadata(from store: BrowserCookieStore) throws -> [CookieMetadata] {
        guard let databaseURL = store.databaseURL else {
            throw ReadError.missingDatabase(label: store.label)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReadError.sqliteFailed(label: store.label, details: self.sqliteMessage(database))
        }
        defer { sqlite3_close(database) }

        let placeholders = Array(repeating: "?", count: self.rawDomains.count).joined(separator: ", ")
        let sql = """
        SELECT host_key, top_frame_site_key, name, path
        FROM cookies
        WHERE lower(host_key) IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.sqliteFailed(label: store.label, details: self.sqliteMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        for (index, domain) in self.rawDomains.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), domain, -1, zoomMateSQLiteTransient)
        }

        var metadata: [CookieMetadata] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let hostKey = self.text(statement, column: 0),
                  let topFrameSiteKey = self.text(statement, column: 1),
                  let name = self.text(statement, column: 2),
                  let path = self.text(statement, column: 3)
            else {
                stepResult = sqlite3_step(statement)
                continue
            }
            metadata.append(CookieMetadata(
                hostKey: hostKey,
                topFrameSiteKey: topFrameSiteKey,
                name: name,
                path: path))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw ReadError.sqliteFailed(label: store.label, details: self.sqliteMessage(database))
        }
        return metadata
    }

    private static func normalizedDomain(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
    }

    private static func text(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
    }

    private static func sqliteMessage(_ database: OpaquePointer?) -> String {
        guard let database else { return "Unknown SQLite error." }
        return String(cString: sqlite3_errmsg(database))
    }
}
#endif

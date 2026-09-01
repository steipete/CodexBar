import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

enum MuseDashboardURLResolver {
    private static let historyFileName = "History"

    static func mostRecentURL(profileDirectory: URL) -> URL? {
        let historyURL = profileDirectory.appendingPathComponent(self.historyFileName)
        guard FileManager.default.fileExists(atPath: historyURL.path),
              let snapshotURL = self.snapshot(historyURL: historyURL)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(snapshotURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT url
        FROM urls
        WHERE url LIKE 'https://dev.meta.ai/usage%'
          AND url LIKE '%team_id=%'
          AND url LIKE '%project_id=%'
        ORDER BY last_visit_time DESC
        LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_text(statement, 0) else { continue }
            if let url = self.canonicalUsageURL(String(cString: bytes)) { return url }
        }
        return nil
    }

    static func canonicalUsageURL(_ rawValue: String) -> URL? {
        guard let source = URLComponents(string: rawValue),
              source.scheme?.lowercased() == "https",
              source.host?.lowercased() == "dev.meta.ai",
              source.path == "/usage" || source.path == "/usage/"
        else { return nil }

        let teamID = source.queryItems?.first(where: { $0.name == "team_id" })?.value
        let projectID = source.queryItems?.first(where: { $0.name == "project_id" })?.value
        guard let teamID = self.validIdentifier(teamID),
              let projectID = self.validIdentifier(projectID)
        else { return nil }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "dev.meta.ai"
        canonical.path = "/usage/"
        canonical.queryItems = [
            URLQueryItem(name: "team_id", value: teamID),
            URLQueryItem(name: "project_id", value: projectID),
        ]
        return canonical.url
    }

    private static func validIdentifier(_ value: String?) -> String? {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard let value,
              !value.isEmpty,
              value.count <= 256,
              value.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
        else { return nil }
        return value
    }

    private static func snapshot(historyURL: URL) -> URL? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-muse-history-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(self.historyFileName)
            try fileManager.copyItem(at: historyURL, to: destination)
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: historyURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: URL(fileURLWithPath: destination.path + suffix))
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }
    }
}

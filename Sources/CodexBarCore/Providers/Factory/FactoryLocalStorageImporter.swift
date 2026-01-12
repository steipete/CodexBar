import Foundation
#if os(macOS)
import SQLite3
import SweetCookieKit
#endif

#if os(macOS)
enum FactoryLocalStorageImporter {
    struct TokenInfo: Sendable {
        let refreshToken: String
        let accessToken: String?
        let organizationID: String?
        let sourceLabel: String
    }

    static func importWorkOSTokens(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [TokenInfo]
    {
        let log: (String) -> Void = { msg in logger?("[factory-storage] \(msg)") }
        var tokens: [TokenInfo] = []

        let safariCandidates = self.safariLocalStorageCandidates()
        let chromeCandidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if !safariCandidates.isEmpty {
            log("Safari local storage candidates: \(safariCandidates.count)")
        }
        if !chromeCandidates.isEmpty {
            log("Chrome local storage candidates: \(chromeCandidates.count)")
        }

        let candidates = safariCandidates + chromeCandidates
        for candidate in candidates {
            let match: WorkOSTokenMatch? = switch candidate.kind {
            case let .chromeLevelDB(levelDBURL):
                self.readWorkOSToken(from: levelDBURL)
            case let .safariSQLite(dbURL):
                self.readWorkOSTokenFromSafariSQLite(dbURL: dbURL, logger: log)
            }
            guard let token = match else { continue }
            log("Found WorkOS refresh token in \(candidate.label)")
            tokens.append(TokenInfo(
                refreshToken: token.refreshToken,
                accessToken: token.accessToken,
                organizationID: token.organizationID,
                sourceLabel: candidate.label))
        }

        if tokens.isEmpty {
            log("No WorkOS refresh token found in browser local storage")
        }

        return tokens
    }

    static func hasSafariWorkOSRefreshToken() -> Bool {
        for candidate in self.safariLocalStorageCandidates() {
            guard case let .safariSQLite(dbURL) = candidate.kind else { continue }
            if self.readWorkOSTokenFromSafariSQLite(dbURL: dbURL) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Chrome local storage discovery

    private enum LocalStorageSourceKind: Sendable {
        case chromeLevelDB(URL)
        case safariSQLite(URL)
    }

    private struct LocalStorageCandidate: Sendable {
        let label: String
        let kind: LocalStorageSourceKind
    }

    private static func chromeLocalStorageCandidates(browserDetection: BrowserDetection) -> [LocalStorageCandidate] {
        let browsers: [Browser] = [
            .chrome,
            .chromeBeta,
            .chromeCanary,
            .arc,
            .arcBeta,
            .arcCanary,
            .chatgptAtlas,
            .chromium,
            .helium,
        ]

        // Filter to browsers with profile data to avoid unnecessary filesystem access.
        let installedBrowsers = browsers.browsersWithProfileData(using: browserDetection)

        let roots = ChromiumProfileLocator
            .roots(for: installedBrowsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [LocalStorageCandidate] = []
        for root in roots {
            candidates.append(contentsOf: self.chromeProfileLocalStorageDirs(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    private static func chromeProfileLocalStorageDirs(root: URL, labelPrefix: String) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDBURL.path) else { return nil }
            let label = "\(labelPrefix) \(dir.lastPathComponent)"
            return LocalStorageCandidate(label: label, kind: .chromeLevelDB(levelDBURL))
        }
    }

    private static func safariLocalStorageCandidates() -> [LocalStorageCandidate] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("com.apple.Safari")
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("WebKit")
            .appendingPathComponent("WebsiteData")
            .appendingPathComponent("Default")

        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let targets = ["app.factory.ai", "auth.factory.ai"]
        var candidates: [LocalStorageCandidate] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "origin" else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            let ascii = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            guard targets.contains(where: { ascii.contains($0) }) else { continue }

            let storageURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("LocalStorage")
                .appendingPathComponent("localstorage.sqlite3")
            guard FileManager.default.fileExists(atPath: storageURL.path) else { continue }
            let host = self.extractSafariOriginHost(from: ascii) ?? "app.factory.ai"
            candidates.append(LocalStorageCandidate(label: "Safari (\(host))", kind: .safariSQLite(storageURL)))
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let key: String = switch candidate.kind {
            case let .chromeLevelDB(url):
                url.path
            case let .safariSQLite(url):
                url.path
            }
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func extractSafariOriginHost(from ascii: String) -> String? {
        let targets = ["app.factory.ai", "auth.factory.ai", "factory.ai"]
        for host in targets where ascii.contains(host) {
            return host
        }
        return nil
    }

    // MARK: - Token extraction

    private struct WorkOSTokenMatch: Sendable {
        let refreshToken: String
        let accessToken: String?
        let organizationID: String?
    }

    private static func readWorkOSToken(from levelDBURL: URL) -> WorkOSTokenMatch? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: levelDBURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        let files = entries.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "ldb" || ext == "log"
        }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (left ?? .distantPast) > (right ?? .distantPast)
        }

        for file in files {
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            if let match = self.extractWorkOSToken(from: data) {
                return match
            }
        }
        return nil
    }

    private static func extractWorkOSToken(from data: Data) -> WorkOSTokenMatch? {
        guard let contents = String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .isoLatin1)
        else { return nil }
        guard contents.contains("workos:refresh-token") else { return nil }

        let refreshToken = self.matchToken(
            in: contents,
            pattern: "workos:refresh-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})")
        guard let refreshToken else { return nil }

        let accessToken = self.matchToken(
            in: contents,
            pattern: "workos:access-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})")

        let organizationID = self.extractOrganizationID(from: accessToken)
        return WorkOSTokenMatch(
            refreshToken: refreshToken,
            accessToken: accessToken,
            organizationID: organizationID)
    }

    private static func readWorkOSTokenFromSafariSQLite(
        dbURL: URL,
        logger: ((String) -> Void)? = nil) -> WorkOSTokenMatch?
    {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let c = sqlite3_errmsg(db) {
                logger?("Safari local storage open failed: \(String(cString: c))")
            }
            return nil
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 250)
        let tables = self.fetchTableNames(db: db, logger: logger)
        if tables.isEmpty {
            logger?("Safari local storage table lookup returned no tables")
        }
        let table = tables
            .contains("ItemTable") ? "ItemTable" : (tables.contains("localstorage") ? "localstorage" : nil)
        guard let table else {
            logger?("Safari local storage missing ItemTable/localstorage tables (found: \(tables.sorted()))")
            return nil
        }

        let refreshToken = self.fetchLocalStorageValue(db: db, table: table, key: "workos:refresh-token")
        guard let refreshToken, !refreshToken.isEmpty else {
            logger?("Safari local storage missing workos:refresh-token")
            return nil
        }
        let accessToken = self.fetchLocalStorageValue(db: db, table: table, key: "workos:access-token")

        let organizationID = self.extractOrganizationID(from: accessToken)
        return WorkOSTokenMatch(
            refreshToken: refreshToken,
            accessToken: accessToken,
            organizationID: organizationID)
    }

    private static func extractOrganizationID(from accessToken: String?) -> String? {
        guard let accessToken, accessToken.contains(".") else { return nil }
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json["org_id"] as? String
    }

    private static func fetchTableNames(db: OpaquePointer?, logger: ((String) -> Void)? = nil) -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let c = sqlite3_errmsg(db) {
                logger?("Safari local storage table query failed: \(String(cString: c))")
            }
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    names.insert(String(cString: c))
                }
            } else {
                if step != SQLITE_DONE, let c = sqlite3_errmsg(db) {
                    logger?("Safari local storage table query failed: \(String(cString: c))")
                }
                break
            }
        }
        return names
    }

    private static func fetchLocalStorageValue(db: OpaquePointer?, table: String, key: String) -> String? {
        let sql = "SELECT value FROM \(table) WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { cString in
            sqlite3_bind_text(stmt, 1, cString, -1, transient)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return self.decodeSQLiteValue(stmt: stmt, index: 0)
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, index))
            let data = Data(bytes: bytes, count: count)
            return self.decodeValueData(data)
        default:
            return nil
        }
    }

    private static func decodeValueData(_ data: Data) -> String? {
        if let decoded = String(data: data, encoding: .utf16LittleEndian) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    private static func matchToken(in contents: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex.matches(in: contents, options: [], range: range).last else { return nil }
        guard match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: contents)
        else { return nil }
        return String(contents[tokenRange])
    }
}
#endif

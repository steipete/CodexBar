#if os(macOS)
import Foundation
import SQLite3
import SweetCookieKit

/// Reads single local storage values from Gecko (`ls/data.sqlite`) and Safari (`localstorage.sqlite3`) profiles.
/// Both engines keep their databases open while running, so reads use a private snapshot copy.
enum SQLiteWebStorageReader {
    struct Entry: Sendable, Equatable {
        let sourceLabel: String
        let value: String
    }

    // MARK: Gecko

    static func geckoValues(
        key: String,
        host: String,
        browsers: [Browser],
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()) -> [Entry]
    {
        var seenFolders = Set<String>()
        var entries: [Entry] = []
        for browser in browsers {
            guard let folder = browser.geckoProfilesFolder, seenFolders.insert(folder.lowercased()).inserted else {
                continue
            }
            for home in homeDirectories {
                let profilesRoot = home
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
                    .appendingPathComponent(folder, isDirectory: true)
                    .appendingPathComponent("Profiles", isDirectory: true)
                entries += self.geckoValues(
                    key: key,
                    host: host,
                    profilesRoot: profilesRoot,
                    labelPrefix: browser.displayName)
            }
        }
        return entries
    }

    static func geckoValues(key: String, host: String, profilesRoot: URL, labelPrefix: String) -> [Entry] {
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }

        return profiles.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { profile in
            let databaseURL = profile
                .appendingPathComponent("storage/default", isDirectory: true)
                .appendingPathComponent("https+++\(host)", isDirectory: true)
                .appendingPathComponent("ls/data.sqlite", isDirectory: false)
            guard let value = self.withSnapshot(of: databaseURL, { self.readGeckoValue(key: key, db: $0) }) else {
                return nil
            }
            return Entry(sourceLabel: "\(labelPrefix) \(profile.lastPathComponent)", value: value)
        }
    }

    // MARK: Safari

    static func safariValues(
        key: String,
        host: String,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()) -> [Entry]
    {
        homeDirectories.flatMap { home in
            self.safariValues(
                key: key,
                host: host,
                websiteDataRoot: home.appendingPathComponent(
                    "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default",
                    isDirectory: true))
        }
    }

    static func safariValues(key: String, host: String, websiteDataRoot: URL) -> [Entry] {
        let fileManager = FileManager.default
        guard let topFrames = try? fileManager.contentsOfDirectory(
            at: websiteDataRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }

        let hostBytes = Data(host.utf8)
        var entries: [Entry] = []
        for topFrame in topFrames.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // First-party storage lives in <hash>/<same hash>; skip third-party partitions.
            let origin = topFrame.appendingPathComponent(topFrame.lastPathComponent, isDirectory: true)
            guard let originData = try? Data(contentsOf: origin.appendingPathComponent("origin")),
                  self.originFile(originData, containsHost: hostBytes)
            else { continue }
            let databaseURL = origin.appendingPathComponent("LocalStorage/localstorage.sqlite3", isDirectory: false)
            if let value = self.withSnapshot(of: databaseURL, { self.readSafariValue(key: key, db: $0) }) {
                entries.append(Entry(sourceLabel: "Safari", value: value))
            }
        }
        return entries
    }

    /// WebKit's origin file serializes scheme and host as length-prefixed strings; match the host exactly.
    static func originFile(_ data: Data, containsHost host: Data) -> Bool {
        let bytes = [UInt8](data)
        let needle = [UInt8](host)
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        var start = 0
        while start + needle.count <= bytes.count {
            if bytes[start..<(start + needle.count)].elementsEqual(needle) {
                let end = start + needle.count
                let before = start > 0 ? bytes[start - 1] : 0
                let after = end < bytes.count ? bytes[end] : 0
                if !Self.isHostCharacter(before), !Self.isHostCharacter(after) {
                    return true
                }
            }
            start += 1
        }
        return false
    }

    private static func isHostCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
            byte == 0x2D || byte == 0x2E
    }

    // MARK: SQLite

    private static func readGeckoValue(key: String, db: OpaquePointer) -> String? {
        let sql = "SELECT value, conversion_type, compression_type FROM data WHERE key = ? LIMIT 1"
        return self.querySingleRow(db: db, sql: sql, key: key) { statement in
            guard let blob = self.blob(statement, column: 0) else { return nil }
            let conversion = sqlite3_column_int(statement, 1)
            let compression = sqlite3_column_int(statement, 2)
            guard let raw = compression == 0 ? blob : SnappyBlockDecoder.decompress(blob) else { return nil }
            // Gecko stores converted values as UTF-8 and unconverted ones as UTF-16LE.
            return conversion == 1
                ? String(data: raw, encoding: .utf8)
                : String(data: raw, encoding: .utf16LittleEndian)
        }
    }

    private static func readSafariValue(key: String, db: OpaquePointer) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        return self.querySingleRow(db: db, sql: sql, key: key) { statement in
            guard let blob = self.blob(statement, column: 0) else { return nil }
            return String(data: blob, encoding: .utf16LittleEndian)
        }
    }

    private static func querySingleRow(
        db: OpaquePointer,
        sql: String,
        key: String,
        decode: (OpaquePointer) -> String?) -> String?
    {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let value = decode(statement)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        if sqlite3_column_type(statement, column) == SQLITE_TEXT, let text = sqlite3_column_text(statement, column) {
            return Data(bytes: text, count: count)
        }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// Copies the database and its WAL into a private directory so committed-but-uncheckpointed rows are visible
    /// and the browser's own locks are never contended.
    private static func withSnapshot<T>(of databaseURL: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: databaseURL.path) else { return nil }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-webstorage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let copy = directory.appendingPathComponent("storage.sqlite")
            try fileManager.copyItem(at: databaseURL, to: copy)
            let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
            if fileManager.fileExists(atPath: wal.path) {
                try fileManager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                return nil
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 250)
            return body(db)
        } catch {
            return nil
        }
    }
}
#endif

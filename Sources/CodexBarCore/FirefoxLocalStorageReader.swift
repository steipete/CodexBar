#if os(macOS)
import Foundation
import SQLite3
import SweetCookieKit

/// Reads an origin's Firefox localStorage without traversing container or partitioned stores.
struct FirefoxLocalStorageReader {
    struct Entry: Sendable, Equatable {
        let key: String
        let value: String
    }

    struct Profile: Sendable, Equatable {
        let id: String
        let label: String
        let entries: [Entry]
    }

    struct Limits: Sendable {
        let maximumProfiles: Int
        let maximumRows: Int
        let maximumCompressedBytes: Int
        let maximumUncompressedBytes: Int

        static let `default` = Limits(
            maximumProfiles: 32,
            maximumRows: 2048,
            maximumCompressedBytes: 4 * 1024 * 1024,
            maximumUncompressedBytes: 8 * 1024 * 1024)
    }

    private let profileRoots: [URL]
    private let fileManager: FileManager
    private let limits: Limits
    private let isCancelled: @Sendable () -> Bool
    private let operationResultOverride: (@Sendable (Bool) -> Int32?)?

    init(
        profileRoots: [URL],
        fileManager: FileManager = .default,
        limits: Limits = .default,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        operationResultOverride: (@Sendable (Bool) -> Int32?)? = nil)
    {
        self.profileRoots = profileRoots
        self.fileManager = fileManager
        self.limits = limits
        self.isCancelled = isCancelled
        self.operationResultOverride = operationResultOverride
    }

    static func defaultProfileRoots(homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()) -> [URL] {
        homeDirectories.map {
            $0.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        }
    }

    func profiles(
        for origin: String,
        logger: @escaping @Sendable (String) -> Void = { _ in }) -> [Profile]
    {
        guard let origin = Self.originDirectory(for: origin), !self.isCancelled() else {
            logger("Firefox local storage rejected origin")
            return []
        }

        var results: [Profile] = []
        var inspectedProfiles = 0
        for root in self.profileRoots {
            guard inspectedProfiles < self.limits.maximumProfiles, !self.isCancelled() else { break }
            guard let resolvedRoot = self.resolvedDirectory(root),
                  let enumerator = self.fileManager.enumerator(
                      at: resolvedRoot,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles])
            else { continue }

            var rootProfiles: [Profile] = []
            while inspectedProfiles < self.limits.maximumProfiles,
                  !self.isCancelled(),
                  let child = enumerator.nextObject() as? URL
            {
                // Firefox profiles are direct children. Never recurse into a malformed profile while discovering.
                enumerator.skipDescendants()
                guard child.deletingLastPathComponent().standardizedFileURL == resolvedRoot else { continue }
                inspectedProfiles += 1
                guard let profile = self.resolvedDirectory(child), Self.isContained(profile, in: resolvedRoot) else {
                    continue
                }
                let database = profile
                    .appendingPathComponent("storage/default", isDirectory: true)
                    .appendingPathComponent(origin, isDirectory: true)
                    .appendingPathComponent("ls/data.sqlite", isDirectory: false)
                guard let resolvedDatabase = self.resolvedFile(database),
                      Self.isContained(resolvedDatabase, in: profile),
                      Self.isContained(resolvedDatabase, in: resolvedRoot),
                      self.sidecarsAreSafe(database: resolvedDatabase)
                else { continue }

                let id = "firefox:\(profile.lastPathComponent)"
                guard let entries = self.readEntries(database: resolvedDatabase) else {
                    logger("Firefox local storage read failed for \(id)")
                    continue
                }
                rootProfiles.append(Profile(id: id, label: "Firefox \(profile.lastPathComponent)", entries: entries))
            }
            results.append(contentsOf: rootProfiles.sorted {
                $0.label.localizedStandardCompare($1.label) == .orderedAscending
            })
        }
        return results
    }

    /// The storage/default directory name used by Gecko for a canonical HTTPS origin.
    static func originDirectory(for origin: String) -> String? {
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty,
              let rawHost = components.host,
              !rawHost.isEmpty
        else { return nil }

        let host = rawHost.lowercased()
        let allowedHostScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard origin.unicodeScalars.allSatisfy({ $0.value < 128 }),
              host != ".", host != "..",
              host.unicodeScalars.allSatisfy({ allowedHostScalars.contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix("."),
              !host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
        else { return nil }
        guard let port = components.port else { return "https+++\(host)" }
        guard (1...65535).contains(port) else { return nil }
        guard port != 443 else { return "https+++\(host)" }
        return "https+++\(host)+\(port)"
    }

    private func resolvedDirectory(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return resolved
    }

    private func resolvedFile(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return resolved
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func readEntries(database: URL) -> [Entry]? {
        guard !self.isCancelled(), self.sidecarsAreSafe(database: database) else { return nil }
        let before = self.idleIdentity(database)
        let direct = self.withDatabase(at: database, immutable: false) { db in
            self.readEntries(database: db)
        }
        if let entries = direct.entries { return entries }

        // SQLite's immutable mode cannot observe a WAL. It is only safe after SQLITE_CANTOPEN on an idle DB.
        guard Self.baseSQLiteCode(direct.sqliteResult) == SQLITE_CANTOPEN,
              let before,
              self.sidecarsAreSafe(database: database),
              before == self.idleIdentity(database)
        else { return nil }
        let fallback = self.withDatabase(at: database, immutable: true) { db in
            self.readEntries(database: db)
        }
        guard let entries = fallback.entries,
              self.sidecarsAreSafe(database: database),
              before == self.idleIdentity(database)
        else { return nil }
        return entries
    }

    private func withDatabase(
        at url: URL,
        immutable: Bool,
        operation: (OpaquePointer?) -> DatabaseOperation)
    -> DatabaseOperation {
        var db: OpaquePointer?
        let openResult: Int32
        if immutable {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_CANTOPEN)
            }
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let filename = components.url?.absoluteString else {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_CANTOPEN)
            }
            openResult = sqlite3_open_v2(
                filename,
                &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
                nil)
        } else {
            openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard openResult == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return DatabaseOperation(entries: nil, sqliteResult: openResult)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(self.limits.maximumCompressedBytes))
        if let result = self.operationResultOverride?(immutable) {
            return DatabaseOperation(entries: nil, sqliteResult: result)
        }
        return operation(db)
    }

    private func readEntries(database db: OpaquePointer?) -> DatabaseOperation {
        guard let db else { return DatabaseOperation(entries: nil, sqliteResult: SQLITE_MISUSE) }
        guard !self.isCancelled() else { return DatabaseOperation(entries: nil, sqliteResult: SQLITE_INTERRUPT) }
        let state = ReadState(isCancelled: self.isCancelled)
        sqlite3_progress_handler(db, 1000, Self.progress, Unmanaged.passUnretained(state).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }

        let beginResult = self.execute("BEGIN DEFERRED", database: db)
        guard beginResult == SQLITE_OK else {
            return DatabaseOperation(entries: nil, sqliteResult: beginResult)
        }
        defer { _ = self.execute("ROLLBACK", database: db) }
        let schema = self.hasRequiredDataColumns(database: db)
        guard schema.hasColumns else {
            return DatabaseOperation(entries: nil, sqliteResult: schema.sqliteResult)
        }

        let sql = "SELECT key, utf16_length, conversion_type, compression_type, value FROM data"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return DatabaseOperation(entries: nil, sqliteResult: sqlite3_extended_errcode(db))
        }
        defer { sqlite3_finalize(statement) }

        var result: [Entry] = []
        var keyBytes = 0
        var compressedBytes = 0
        var uncompressedBytes = 0
        while true {
            if self.isCancelled() || state.cancelled {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_INTERRUPT)
            }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return DatabaseOperation(entries: result, sqliteResult: SQLITE_OK) }
            guard step == SQLITE_ROW else {
                return DatabaseOperation(entries: nil, sqliteResult: step)
            }
            guard result.count < self.limits.maximumRows,
                  sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER
            else { return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR) }

            let keyLength = Int(sqlite3_column_bytes(statement, 0))
            guard keyLength >= 0,
                  keyLength <= self.limits.maximumCompressedBytes - keyBytes - compressedBytes,
                  let keyPointer = sqlite3_column_text(statement, 0)
            else { return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR) }
            let keyData = Data(bytes: keyPointer, count: keyLength)
            guard let key = String(data: keyData, encoding: .utf8) else {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR)
            }
            keyBytes += keyLength

            let length = Int(sqlite3_column_int64(statement, 1))
            let conversion = sqlite3_column_int(statement, 2)
            let compression = sqlite3_column_int(statement, 3)
            guard length >= 0, conversion == 0 || conversion == 1, compression == 0 || compression == 1 else {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR)
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 4))
            guard byteCount >= 0,
                  byteCount <= self.limits.maximumCompressedBytes - keyBytes - compressedBytes
            else {
                return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR)
            }
            let payload: Data
            if byteCount == 0 {
                payload = Data()
            } else {
                guard let bytes = sqlite3_column_blob(statement, 4) else {
                    return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR)
                }
                payload = Data(bytes: bytes, count: byteCount)
            }
            compressedBytes += byteCount
            guard let decoded = self.decode(
                payload,
                utf16Length: length,
                conversion: conversion,
                compression: compression),
                decoded.utf8.count <= self.limits.maximumUncompressedBytes - uncompressedBytes
            else { return DatabaseOperation(entries: nil, sqliteResult: SQLITE_ERROR) }
            uncompressedBytes += decoded.utf8.count
            result.append(Entry(key: key, value: decoded))
        }
    }

    private func hasRequiredDataColumns(database: OpaquePointer?) -> SchemaResult {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(data)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return SchemaResult(hasColumns: false, sqliteResult: sqlite3_extended_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                let required = Set(["key", "utf16_length", "conversion_type", "compression_type", "value"])
                let hasColumns = required.isSubset(of: columns)
                return SchemaResult(
                    hasColumns: hasColumns,
                    sqliteResult: hasColumns ? SQLITE_OK : SQLITE_ERROR)
            }
            guard step == SQLITE_ROW else {
                return SchemaResult(hasColumns: false, sqliteResult: step)
            }
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
    }

    private func decode(_ payload: Data, utf16Length: Int, conversion: Int32, compression: Int32) -> String? {
        let decoded: Data? = if compression == 0 {
            payload
        } else {
            Self.decodeSnappy(payload, maximumOutputBytes: self.limits.maximumUncompressedBytes)
        }
        guard let decoded else { return nil }
        let value: String?
        if conversion == 1 {
            value = String(data: decoded, encoding: .utf8)
        } else {
            guard decoded.count.isMultiple(of: 2) else { return nil }
            value = String(data: decoded, encoding: .utf16LittleEndian)
        }
        guard let value, value.utf16.count == utf16Length else { return nil }
        return value
    }

    private func execute(_ sql: String, database: OpaquePointer?) -> Int32 {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private static func baseSQLiteCode(_ code: Int32) -> Int32 {
        code & 0xFF
    }

    private func hasWAL(_ database: URL) -> Bool {
        self.fileManager.fileExists(atPath: database.path + "-wal")
    }

    private func sidecarsAreSafe(database: URL) -> Bool {
        let directory = database.deletingLastPathComponent().standardizedFileURL
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            guard self.fileManager.fileExists(atPath: sidecar.path) else { continue }
            guard let resolvedSidecar = self.resolvedFile(sidecar),
                  resolvedSidecar.deletingLastPathComponent().standardizedFileURL == directory
            else { return false }
        }
        return true
    }

    private func idleIdentity(_ database: URL) -> IdleIdentity? {
        guard !self.hasWAL(database), let main = self.fileIdentity(database) else { return nil }
        return IdleIdentity(main: main)
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]),
            let identifier = values.fileResourceIdentifier,
            let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return nil }
        return FileIdentity(identifier: String(describing: identifier), size: size, modified: modified)
    }

    private final class ReadState: @unchecked Sendable {
        private let isCancelled: @Sendable () -> Bool

        init(isCancelled: @escaping @Sendable () -> Bool) {
            self.isCancelled = isCancelled
        }

        var cancelled: Bool {
            self.isCancelled()
        }
    }

    private struct DatabaseOperation {
        let entries: [Entry]?
        let sqliteResult: Int32
    }

    private struct SchemaResult {
        let hasColumns: Bool
        let sqliteResult: Int32
    }

    private struct FileIdentity: Equatable {
        let identifier: String
        let size: Int
        let modified: Date
    }

    private struct IdleIdentity: Equatable {
        let main: FileIdentity
    }

    private static let progress: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
        guard let context else { return 1 }
        return Unmanaged<ReadState>.fromOpaque(context).takeUnretainedValue().cancelled ? 1 : 0
    }

    private static func decodeSnappy(_ input: Data, maximumOutputBytes: Int) -> Data? {
        var index = 0
        guard let expected = Self.readVarint(input, index: &index), expected <= maximumOutputBytes else { return nil }
        var output = Data()
        output.reserveCapacity(expected)
        while index < input.count {
            let tag = input[index]
            index += 1
            let type = tag & 0x03
            let length: Int
            let offset: Int
            switch type {
            case 0:
                var literalLength = Int(tag >> 2) + 1
                if literalLength >= 61 {
                    let extraBytes = literalLength - 60
                    guard extraBytes <= 4, index + extraBytes <= input.count else { return nil }
                    literalLength = 1
                    for shift in 0..<extraBytes {
                        literalLength += Int(input[index + shift]) << (shift * 8)
                    }
                    index += extraBytes
                }
                guard literalLength <= expected - output.count, index + literalLength <= input.count else { return nil }
                output.append(input[index..<(index + literalLength)])
                index += literalLength
                continue
            case 1:
                length = 4 + Int((tag >> 2) & 0x07)
                guard index < input.count else { return nil }
                offset = Int(tag & 0xE0) << 3 | Int(input[index])
                index += 1
            case 2:
                length = 1 + Int(tag >> 2)
                guard index + 2 <= input.count else { return nil }
                offset = Int(input[index]) | Int(input[index + 1]) << 8
                index += 2
            case 3:
                length = 1 + Int(tag >> 2)
                guard index + 4 <= input.count else { return nil }
                offset = Int(input[index]) | Int(input[index + 1]) << 8 | Int(input[index + 2]) << 16 |
                    Int(input[index + 3]) << 24
                index += 4
            default:
                return nil
            }
            guard offset > 0, offset <= output.count, length <= expected - output.count else { return nil }
            for _ in 0..<length {
                output.append(output[output.count - offset])
            }
        }
        return output.count == expected ? output : nil
    }

    private static func readVarint(_ data: Data, index: inout Int) -> Int? {
        var value = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            guard index < data.count else { return nil }
            let byte = data[index]
            index += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}
#endif

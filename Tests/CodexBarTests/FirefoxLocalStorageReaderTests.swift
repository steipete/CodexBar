#if os(macOS)
import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct FirefoxLocalStorageReaderTests {
    @Test(arguments: [
        ("https://app.example.test", "https+++app.example.test"),
        ("https://APP.example.test:443", "https+++app.example.test"),
        ("https://app.example.test:8443", "https+++app.example.test+8443"),
    ])
    func `origin directory is exact and normalized`(_ origin: String, _ expected: String) {
        #expect(FirefoxLocalStorageReader.originDirectory(for: origin) == expected)
    }

    @Test(arguments: [
        "http://app.example.test",
        "https://user@app.example.test",
        "https://app.example.test/path",
        "https://app.example.test?query=value",
        "https://[::1]",
        "https://xn--bcher-kva.example",
        "https://bücher.example",
        "https://../escape.example",
    ])
    func `origin directory rejects unsupported or non-origin URLs`(_ origin: String) {
        #expect(FirefoxLocalStorageReader.originDirectory(for: origin) == nil)
    }

    @Test
    func `profiles are ordered and use stable Firefox identities`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "zeta.default", entries: [self.utf8("z", "value")])
            try self.writeDatabase(root: root, profile: "alpha.default", entries: [self.utf8("a", "value")])
            let profiles = FirefoxLocalStorageReader(profileRoots: [root]).profiles(for: "https://app.example.test")
            #expect(profiles.map(\.id) == ["firefox:alpha.default", "firefox:zeta.default"])
            #expect(profiles.map(\.label) == ["Firefox alpha.default", "Firefox zeta.default"])
        }
    }

    @Test
    func `reader only loads its exact unpartitioned origin directory`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "default", entries: [self.utf8("exact-key", "exact-value")])
            let exact = self.databaseURL(root: root, profile: "default")
            for suffix in ["^userContextId=4", "+8443"] {
                let sibling = exact.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("https+++app.example.test\(suffix)/ls/data.sqlite")
                try FileManager.default.createDirectory(
                    at: sibling.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: exact, to: sibling)
            }

            let entries = FirefoxLocalStorageReader(profileRoots: [root])
                .profiles(for: "https://app.example.test").first?.entries
            #expect(entries?.map(\.key) == ["exact-key"])
            #expect(entries?.map(\.value) == ["exact-value"])
        }
    }

    @Test
    func `reader rejects a symlink profile escaping its root`() throws {
        try self.withFixture { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID())")
            defer { try? FileManager.default.removeItem(at: outside) }
            try self.writeDatabase(root: outside, profile: "escaped.default", entries: [self.utf8("key", "value")])
            let link = root.appendingPathComponent("escape.default")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: outside.appendingPathComponent("escaped.default"))
            #expect(FirefoxLocalStorageReader(profileRoots: [root]).profiles(for: "https://app.example.test").isEmpty)
        }
    }

    @Test
    func `profile inspection cap includes malformed profiles`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "a-malformed", entries: [
                Row(key: "bad", length: 0, conversion: 99, compression: 0, value: Data()),
            ])
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("b-missing"),
                withIntermediateDirectories: true)
            try self.writeDatabase(root: root, profile: "z-valid", entries: [self.utf8("valid", "value")])

            let reader = FirefoxLocalStorageReader(
                profileRoots: [root],
                limits: .init(
                    maximumProfiles: 2,
                    maximumRows: 10,
                    maximumCompressedBytes: 1024,
                    maximumUncompressedBytes: 1024))
            #expect(reader.profiles(for: "https://app.example.test").isEmpty)
        }
    }

    @Test
    func `reader rejects sidecar symlink escapes`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "default", entries: [self.utf8("key", "value")])
            let database = self.databaseURL(root: root, profile: "default")
            let outside = root.deletingLastPathComponent().appendingPathComponent("sidecar-\(UUID())")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: URL(fileURLWithPath: database.path + "-wal"),
                withDestinationURL: outside)
            #expect(FirefoxLocalStorageReader(profileRoots: [root]).profiles(for: "https://app.example.test").isEmpty)
        }
    }

    @Test
    func `reader preserves embedded NUL keys and rejects oversized keys`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "nul", entries: [
                self.utf8("shared\u{0000}one", "first"),
                self.utf8("shared\u{0000}two", "second"),
            ])
            try self.writeDatabase(root: root, profile: "oversized", entries: [
                self.utf8(String(repeating: "k", count: 128), "value"),
            ])
            try self.writeDatabase(root: root, profile: "budget", entries: [
                self.utf8(String(repeating: "k", count: 40), String(repeating: "v", count: 30)),
            ])
            let reader = FirefoxLocalStorageReader(
                profileRoots: [root],
                limits: .init(
                    maximumProfiles: 10,
                    maximumRows: 10,
                    maximumCompressedBytes: 64,
                    maximumUncompressedBytes: 1024))
            let profiles = reader.profiles(for: "https://app.example.test")
            #expect(profiles.first(where: { $0.id == "firefox:nul" })?.entries.map(\.key) == [
                "shared\u{0000}one",
                "shared\u{0000}two",
            ])
            #expect(profiles.contains(where: { $0.id == "firefox:oversized" }) == false)
            #expect(profiles.contains(where: { $0.id == "firefox:budget" }) == false)
        }
    }

    @Test
    func `reader decodes utf8 utf16 and raw Snappy values`() throws {
        try self.withFixture { root in
            let snappy = Data([6, 20]) + Data("snappy".utf8)
            try self.writeDatabase(root: root, profile: "default", entries: [
                self.utf8("utf8", "plain"),
                self.utf16("utf16", "native"),
                Row(key: "snappy", length: 6, conversion: 1, compression: 1, value: snappy),
            ])
            let entries = FirefoxLocalStorageReader(profileRoots: [root])
                .profiles(for: "https://app.example.test").first?.entries
            #expect(entries?.map(\.key) == ["utf8", "utf16", "snappy"])
            #expect(entries?.map(\.value) == ["plain", "native", "snappy"])
        }
    }

    @Test
    func `reader rejects malformed oversized and schema-drift stores without partial entries`() throws {
        try self.withFixture { root in
            let malformed = Data([5, 1, 0]) // A copy before any literal output.
            try self.writeDatabase(root: root, profile: "malformed", entries: [
                Row(key: "fixture-secret-key", length: 5, conversion: 1, compression: 1, value: malformed),
                Row(
                    key: "fixture-secret-value-key",
                    length: 0,
                    conversion: 99,
                    compression: 0,
                    value: Data("fixture-secret-value".utf8)),
            ])
            try self.writeDatabase(root: root, profile: "oversized", entries: [
                Row(key: "large", length: 5, conversion: 1, compression: 1, value: Data([5, 16]) + Data("large".utf8)),
            ])
            let drift = self.databaseURL(root: root, profile: "drift")
            try FileManager.default.createDirectory(
                at: drift.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try self.exec(database: drift, sql: "CREATE TABLE data (key TEXT, value BLOB)")

            let diagnostics = DiagnosticLog()
            let reader = FirefoxLocalStorageReader(
                profileRoots: [root],
                limits: .init(
                    maximumProfiles: 32,
                    maximumRows: 20,
                    maximumCompressedBytes: 1024,
                    maximumUncompressedBytes: 4))
            let profiles = reader.profiles(for: "https://app.example.test") { diagnostics.messages.append($0) }
            #expect(profiles.filter {
                $0.id == "firefox:malformed" || $0.id == "firefox:drift" || $0.id == "firefox:oversized"
            }.isEmpty)
            #expect(!diagnostics.messages.joined(separator: " ").contains("fixture-secret-key"))
            #expect(!diagnostics.messages.joined(separator: " ").contains("fixture-secret-value"))
        }
    }

    @Test
    func `cancellation fails closed before opening the store`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "default", entries: [self.utf8("key", "value")])
            let reader = FirefoxLocalStorageReader(profileRoots: [root], isCancelled: { true })
            #expect(reader.profiles(for: "https://app.example.test").isEmpty)
            try FileManager.default.removeItem(at: self.databaseURL(root: root, profile: "default"))
        }
    }

    @Test
    func `row cap rejects the entire store and handles are released`() throws {
        try self.withFixture { root in
            try self.writeDatabase(
                root: root,
                profile: "default",
                entries: [self.utf8("one", "1"), self.utf8("two", "2")])
            let reader = FirefoxLocalStorageReader(
                profileRoots: [root],
                limits: .init(
                    maximumProfiles: 2,
                    maximumRows: 1,
                    maximumCompressedBytes: 1024,
                    maximumUncompressedBytes: 1024))
            #expect(reader.profiles(for: "https://app.example.test").isEmpty)
            let database = self.databaseURL(root: root, profile: "default")
            try FileManager.default.removeItem(at: database)
            #expect(!FileManager.default.fileExists(atPath: database.path))
        }
    }

    @Test
    func `reader retries immutable after a deferred CANTOPEN on a stable idle database`() throws {
        try self.withFixture { root in
            try self.writeDatabase(root: root, profile: "default", entries: [self.utf8("key", "value")])
            let reader = FirefoxLocalStorageReader(
                profileRoots: [root],
                operationResultOverride: { immutable in immutable ? nil : SQLITE_CANTOPEN })
            let entries = reader.profiles(for: "https://app.example.test").first?.entries
            #expect(entries == [FirefoxLocalStorageReader.Entry(key: "key", value: "value")])
        }
    }

    @Test
    func `reader observes an active WAL without mutating database or WAL bytes`() throws {
        try self.withFixture { root in
            let database = self.databaseURL(root: root, profile: "default")
            try self.writeDatabase(root: root, profile: "default", entries: [])
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { sqlite3_close(db) }
            _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            try self.insert(database: db, row: self.utf8("wal", "uncheckpointed"))
            let wal = URL(fileURLWithPath: database.path + "-wal")
            let mainBefore = try Data(contentsOf: database)
            let walBefore = try Data(contentsOf: wal)

            let entries = FirefoxLocalStorageReader(profileRoots: [root])
                .profiles(for: "https://app.example.test").first?.entries
            #expect(entries?.first?.value == "uncheckpointed")
            #expect(try Data(contentsOf: database) == mainBefore)
            #expect(try Data(contentsOf: wal) == walBefore)
        }
    }

    private final class DiagnosticLog: @unchecked Sendable {
        var messages: [String] = []
    }

    private struct Row {
        let key: String
        let length: Int
        let conversion: Int32
        let compression: Int32
        let value: Data
    }

    private func utf8(_ key: String, _ value: String) -> Row {
        Row(key: key, length: value.utf16.count, conversion: 1, compression: 0, value: Data(value.utf8))
    }

    private func utf16(_ key: String, _ value: String) -> Row {
        Row(key: key, length: value.utf16.count, conversion: 0, compression: 0, value: Data(value.utf16LE))
    }

    private func withFixture(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("firefox-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try operation(root)
    }

    private func databaseURL(root: URL, profile: String) -> URL {
        root.appendingPathComponent(profile)
            .appendingPathComponent("storage/default/https+++app.example.test/ls/data.sqlite")
    }

    private func writeDatabase(root: URL, profile: String, entries: [Row]) throws {
        let database = self.databaseURL(root: root, profile: profile)
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.exec(
            database: database,
            sql: "CREATE TABLE data (key TEXT, utf16_length INTEGER, conversion_type INTEGER, " +
                "compression_type INTEGER, value BLOB)")
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for entry in entries {
            try self.insert(database: db, row: entry)
        }
    }

    private func exec(database: URL, sql: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(database.path, &db, flags, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func insert(database: OpaquePointer?, row: Row) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO data (key, utf16_length, conversion_type, compression_type, value) " +
            "VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
        else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = row.key.withCString {
            sqlite3_bind_text(statement, 1, $0, Int32(row.key.utf8.count), transient)
        }
        sqlite3_bind_int64(statement, 2, sqlite3_int64(row.length))
        sqlite3_bind_int(statement, 3, row.conversion)
        sqlite3_bind_int(statement, 4, row.compression)
        _ = row.value.withUnsafeBytes { sqlite3_bind_blob(
            statement,
            5,
            $0.baseAddress,
            Int32(row.value.count),
            transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension String {
    fileprivate var utf16LE: [UInt8] {
        self.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}
#endif

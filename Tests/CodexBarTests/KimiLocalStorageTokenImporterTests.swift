#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct KimiLocalStorageTokenImporterTests {
    @Test
    func `snappy decoder expands literals and overlapping copies`() {
        // varint(9), literal "abc", copy-1 (length 6, offset 3)
        let compressed = Data([0x09, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03])
        #expect(SnappyBlockDecoder.decompress(compressed) == Data("abcabcabc".utf8))
    }

    @Test(arguments: [
        Data([0x05, 0x08, 0x61, 0x62, 0x63]),
        Data([0x03, 0x09, 0x05]),
        Data([0x80]),
        Data([0x81, 0x80, 0x40]),
    ])
    func `snappy decoder rejects truncated or oversized input`(input: Data) {
        #expect(SnappyBlockDecoder.decompress(input) == nil)
    }

    @Test
    func `gecko reader decodes snappy compressed UTF-8 values for the exact host only`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = Self.jwt(expiry: Date().addingTimeInterval(3600))
        try Self.createGeckoDatabase(
            profilesRoot: root,
            profile: "abc.default",
            host: "www.kimi.ai",
            key: "access_token",
            value: Self.snappyLiteral(Data(token.utf8)))
        try Self.createGeckoDatabase(
            profilesRoot: root,
            profile: "abc.default",
            host: "www.kimi.com",
            key: "access_token",
            value: Self.snappyLiteral(Data("other-region".utf8)))

        let entries = SQLiteWebStorageReader.geckoValues(
            key: "access_token",
            host: "www.kimi.ai",
            profilesRoot: root,
            labelPrefix: "Zen")
        #expect(entries == [.init(sourceLabel: "Zen abc.default", value: token)])
    }

    @Test
    func `safari reader matches first party origin files by exact host`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createSafariOrigin(root: root, hash: "A", host: "www.kimi.ai", value: "first-party")
        try Self.createSafariOrigin(root: root, hash: "B", host: "www.kimi.ai.example.com", value: "lookalike")
        try Self.createSafariOrigin(root: root, hash: "C", host: "www.kimi.ai", value: "partition", nested: "D")

        let entries = SQLiteWebStorageReader.safariValues(
            key: "access_token",
            host: "www.kimi.ai",
            websiteDataRoot: root)
        #expect(entries.map(\.value) == ["first-party"])
    }

    @Test
    func `token normalization accepts live JWTs and rejects expired or malformed values`() {
        let live = Self.jwt(expiry: Date().addingTimeInterval(3600))
        #expect(KimiLocalStorageTokenImporter.normalizedToken(live) == live)
        #expect(KimiLocalStorageTokenImporter.normalizedToken("\"\(live)\"") == live)
        #expect(KimiLocalStorageTokenImporter.normalizedToken(Self.jwt(expiry: Date(timeIntervalSince1970: 1))) == nil)
        #expect(KimiLocalStorageTokenImporter.normalizedToken("not-a-token") == nil)
        #expect(KimiLocalStorageTokenImporter.normalizedToken("a.b.c; kimi-auth=x") == nil)
    }

    // MARK: Fixtures

    private static func jwt(expiry: Date) -> String {
        let payload = Data("{\"exp\":\(Int(expiry.timeIntervalSince1970))}".utf8)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
    }

    private static func snappyLiteral(_ data: Data) -> Data {
        var output = Data()
        var length = data.count
        while length >= 0x80 {
            output.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        output.append(UInt8(length))
        // Literal tag with a two-byte length (60 + 1 extra bytes).
        output.append(61 << 2)
        let literalLength = data.count - 1
        output.append(UInt8(literalLength & 0xFF))
        output.append(UInt8(literalLength >> 8))
        output.append(data)
        return output
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiLocalStorageTokenImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func createGeckoDatabase(
        profilesRoot: URL,
        profile: String,
        host: String,
        key: String,
        value: Data) throws
    {
        let directory = profilesRoot
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("storage/default/https+++\(host)/ls", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.withDatabase(at: directory.appendingPathComponent("data.sqlite")) { db in
            try Self.exec(db, """
            CREATE TABLE data(key TEXT PRIMARY KEY, utf16_length INTEGER NOT NULL, conversion_type INTEGER NOT NULL,
            compression_type INTEGER NOT NULL, last_access_time INTEGER NOT NULL DEFAULT 0, value BLOB NOT NULL)
            """)
            try Self.insert(db, sql: "INSERT INTO data VALUES (?, 0, 1, 1, 0, ?)", key: key, value: value)
        }
    }

    private static func createSafariOrigin(
        root: URL,
        hash: String,
        host: String,
        value: String,
        nested: String? = nil) throws
    {
        let directory = root
            .appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent(nested ?? hash, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("LocalStorage", isDirectory: true),
            withIntermediateDirectories: true)
        var origin = Data([0x05, 0x00, 0x00, 0x00, 0x01])
        origin.append(Data("https".utf8))
        origin.append(contentsOf: [UInt8(host.utf8.count), 0x00, 0x00, 0x00, 0x01])
        origin.append(Data(host.utf8))
        try origin.write(to: directory.appendingPathComponent("origin"))
        let databaseURL = directory.appendingPathComponent("LocalStorage/localstorage.sqlite3")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL)")
            try Self.insert(
                db,
                sql: "INSERT INTO ItemTable VALUES (?, ?)",
                key: "access_token",
                value: value.data(using: .utf16LittleEndian)!)
        }
    }

    private static func withDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }

    private static func insert(_ db: OpaquePointer, sql: String, key: String, value: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(value.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private enum FixtureError: Error {
        case sqlite
    }
}

#endif

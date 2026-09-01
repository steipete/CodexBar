import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct CursorAppAuthEncodingTests {
    @Test(arguments: [false, true])
    func `text and UTF8 blobs preserve usable app tokens`(asText: Bool) throws {
        let token = try makeCursorAppAuthToken()
        let value: SQLiteValue = asText ? .text(token) : .blob(Data(token.utf8))
        let session = try #require(try Self.load(value))
        #expect(session.accessToken == token)
        #expect(session.isUsable)
    }

    @Test(arguments: [false, true])
    func `ASCII UTF16LE blobs decode without normalizing the app token`(padded: Bool) throws {
        let original = try makeCursorAppAuthToken()
        let token = padded ? " \t" + original + "\r\n" : original
        let bytes = Data(token.utf8.flatMap { [$0, 0] })
        let session = try #require(try Self.load(.blob(bytes)))
        #expect(session.accessToken == token)
        #expect(session.isUsable)
    }

    @Test(arguments: [
        "ordinary", "\"quoted\"", " padded \n", "Málaga", "mixed\0value",
    ])
    func `other UTF8 blobs remain byte exact`(token: String) throws {
        let session = try #require(try Self.load(.blob(Data(token.utf8))))
        #expect(Data(session.accessToken.utf8) == Data(token.utf8))
    }

    @Test(arguments: [false, true])
    func `UTF8 NULs outside a usable JWT payload are not reinterpreted`(inHeader: Bool) throws {
        let token = try makeCursorAppAuthToken()
        let malformed = inHeader ? "\0" + token : token + "\0"
        #expect(CursorAppAuthSession(accessToken: malformed).isUsable)
        let session = try #require(try Self.load(.blob(Data(malformed.utf8))))
        #expect(session.accessToken == malformed)
        #expect(session.isUsable)
    }

    private static let compatibilityBytes: [[UInt8]] = [
        [0x41, 0, 0x42], // Odd length must not drop the last byte.
        [0x41, 0, 0, 0, 0x42, 0], // An embedded NUL is not ASCII token text.
        [0, 0x41, 0, 0x42], // Do not add big-endian detection.
        [0xFF, 0xFE, 0x41, 0, 0x42, 0], // Preserve Foundation's BOM handling.
        [0xFE, 0xFF, 0, 0x41, 0, 0x42],
        [0xEF, 0xBB, 0xBF, 0x41], // UTF8 BOM handling also belongs to Foundation.
        [0xE9, 0, 0x61, 0], // Existing UTF8-failure to UTF16LE fallback.
        [0, 0xD8], // Unpaired surrogate.
        [0xFF], // Invalid in both decoders.
        [0x20, 0, 0x09, 0, 0x0D, 0, 0x0A, 0], // Keep a present invalid session distinct from no session.
        [0],
        [],
    ]

    @Test(arguments: Self.compatibilityBytes)
    func `other blobs retain the original decoding and missing session semantics`(bytes: [UInt8]) throws {
        let data = Data(bytes)
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
        let expected = decoded.flatMap { token in
            token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token
        }
        let session = try Self.load(.blob(data))
        #expect(session?.accessToken == expected)
    }

    @Test
    func `SQLite text keeps its existing NUL terminator behavior`() throws {
        let session = try #require(try Self.load(.text("before\0after")))
        #expect(session.accessToken == "before")
    }

    private enum SQLiteValue {
        case text(String)
        case blob(Data)
    }

    private static func load(_ value: SQLiteValue) throws -> CursorAppAuthSession? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-encoding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(
            database, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            database, "INSERT INTO ItemTable VALUES('cursorAuth/accessToken', ?);", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let binding: Int32 = switch value {
        case let .text(token):
            sqlite3_bind_text(statement, 1, token, Int32(token.utf8.count), transient)
        case let .blob(data) where data.isEmpty:
            sqlite3_bind_zeroblob(statement, 1, 0)
        case let .blob(data):
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient)
            }
        }
        try #require(binding == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        let before = try Data(contentsOf: databaseURL)
        let session = try CursorAppAuthStore(dbPath: databaseURL.path).loadSession()
        #expect(try Data(contentsOf: databaseURL) == before)
        return session
    }
}

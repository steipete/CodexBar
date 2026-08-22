import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodexUsageStoreWindowTests {
    @Test
    func `window start covers inclusive report history`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let expected = try calendar.startOfDay(for: #require(calendar.date(byAdding: .day, value: -364, to: now)))

        #expect(OpenCodexUsageStore.windowStart(
            now: now,
            historyDays: 365,
            calendar: calendar) == expected)
        #expect(OpenCodexUsageStore.windowStart(now: now, historyDays: 0, calendar: calendar) == nil)
    }

    @Test
    func `empty cache hit does not force JSONL reparse`() throws {
        let fixture = StoreCacheFixture()
        try fixture.prepare()
        defer { fixture.cleanup() }
        let store = OpenCodexUsageStore(cacheRoot: fixture.cacheRoot)

        _ = try store.loadEntries(logURL: fixture.logURL)
        try FileManager.default.setAttributes([
            .posixPermissions: 0o000,
        ], ofItemAtPath: fixture.logURL.path)
        let cached = try store.loadEntries(logURL: fixture.logURL)

        #expect(cached.isEmpty)
    }

    @Test
    func `cache miss applies report window while preserving cached history`() throws {
        let fixture = StoreCacheFixture()
        try fixture.prepare()
        defer { fixture.cleanup() }
        let store = OpenCodexUsageStore(cacheRoot: fixture.cacheRoot)
        let old = Date(timeIntervalSince1970: 1_784_179_200)
        let now = old.addingTimeInterval(86400)
        let oldMillis = Int(old.timeIntervalSince1970 * 1000)
        let nowMillis = Int(now.timeIntervalSince1970 * 1000)
        try """
        {"requestId":"old","timestamp":\(oldMillis),"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported"}
        {"requestId":"new","timestamp":\(nowMillis),"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported"}
        """.write(to: fixture.logURL, atomically: true, encoding: .utf8)

        let windowed = try store.loadEntries(logURL: fixture.logURL, since: now)

        #expect(windowed.map(\.requestID) == ["new"])

        let fullCache = try store.loadEntries(logURL: fixture.logURL)
        #expect(fullCache.map(\.requestID) == ["old", "new"])
    }

    @Test
    func `version one cache gains timestamp index without losing entries`() throws {
        let fixture = StoreCacheFixture()
        try fixture.prepare()
        defer { fixture.cleanup() }
        let store = OpenCodexUsageStore(cacheRoot: fixture.cacheRoot)
        let old = Date(timeIntervalSince1970: 1_784_179_200)
        let now = old.addingTimeInterval(86400)
        let oldMillis = Int(old.timeIntervalSince1970 * 1000)
        let nowMillis = Int(now.timeIntervalSince1970 * 1000)
        try """
        {"requestId":"old","timestamp":\(oldMillis),"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported"}
        {"requestId":"new","timestamp":\(nowMillis),"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported"}
        """.write(to: fixture.logURL, atomically: true, encoding: .utf8)

        let seeded = try store.loadEntries(logURL: fixture.logURL)
        #expect(seeded.map(\.requestID) == ["old", "new"])

        let databaseURL = fixture.cacheRoot.appendingPathComponent(
            OpenCodexUsageStore.databaseFilename,
            isDirectory: false)
        try Self.setUserVersion(databaseURL, 1)
        try Self.dropIndex(databaseURL, name: "entries_timestamp_request_id")
        #expect(!Self.indexExists(databaseURL, name: "entries_timestamp_request_id"))

        let cached = try store.loadEntries(
            logURL: fixture.logURL,
            fileManager: UnreadableFileFixtureFileManager())

        #expect(cached.map(\.requestID) == ["old", "new"])
        #expect(Self.indexExists(databaseURL, name: "entries_timestamp_request_id"))
        #expect(Self.userVersion(databaseURL) == 2)
    }
}

extension OpenCodexUsageStoreWindowTests {
    fileprivate static func setUserVersion(_ url: URL, _ version: Int32) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw StoreTestError.open
        }
        defer { sqlite3_close(database) }
        let sql = "PRAGMA user_version = \(version)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreTestError.exec
        }
    }

    fileprivate static func dropIndex(_ url: URL, name: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw StoreTestError.open
        }
        defer { sqlite3_close(database) }
        let sql = "DROP INDEX IF EXISTS \(name)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreTestError.exec
        }
    }

    fileprivate static func userVersion(_ url: URL) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return Int(sqlite3_column_int(statement, 0))
    }

    fileprivate static func indexExists(_ url: URL, name: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

private enum StoreTestError: Error {
    case open
    case exec
}

private final class UnreadableFileFixtureFileManager: FileManager {
    override func fileExists(atPath path: String) -> Bool {
        true
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        [
            .size: NSNumber(value: 42),
            .modificationDate: Date(timeIntervalSince1970: 1_784_179_200 + 86400),
        ]
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(
            .fileReadNoPermission,
            userInfo: [NSFilePathErrorKey: srcURL.path])
    }
}

private struct StoreCacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codexbar-open-codex-window-\(UUID().uuidString)")

    var logURL: URL {
        self.root.appendingPathComponent("usage.jsonl")
    }

    var cacheRoot: URL {
        self.root.appendingPathComponent("cache")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try Data().write(to: self.logURL)
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: self.logURL.path)
        try? FileManager.default.removeItem(at: self.root)
    }
}

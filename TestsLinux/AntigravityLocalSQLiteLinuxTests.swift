#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore
#if canImport(CSQLite3)
import CSQLite3
#elseif canImport(SQLite3)
import SQLite3
#endif

#if canImport(CSQLite3) || canImport(SQLite3)
struct AntigravityLocalSQLiteLinuxTests {
    @Test
    func `reads current CLI conversation rows using steps table timestamps`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-linux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        let directory = context.databaseRoots[0]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("linux-session.db")

        do {
            var database: OpaquePointer?
            let opened = sqlite3_open_v2(
                path.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil)
            guard opened == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                throw AntigravityLocalReader.ScanFailure.invalid
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(
                database,
                "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);" +
                    "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB)",
                nil,
                nil,
                nil) == SQLITE_OK else { throw AntigravityLocalReader.ScanFailure.invalid }
            try Self.insert(database, table: "gen_metadata", id: "0", data: Self.modernTurn())
            try Self.insert(database, table: "gen_metadata", id: "1", data: Self.aggregateRecord())
            try Self.insertStep(
                database,
                idx: 0,
                stepType: 15,
                metadata: Self.stepMetadata(
                    botID: "bot-linux-1", createdSeconds: 1_787_832_000, nanos: 456_789_000))
        }

        var limits = AntigravityLocalReader.Limits()
        limits.duration = 60
        let report = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: context,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"),
            limits: limits)
        #expect(report.coverage == .complete)
        let entry = try #require(report.report.data.first)
        #expect(entry.date == "2026-08-27")
        #expect(entry.inputTokens == 111)
        #expect(entry.outputTokens == 30)
        #expect(entry.cacheReadTokens == 50)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.reasoningTokens == 7)
        #expect(entry.totalTokens == 198)
    }

    private static func insert(
        _ database: OpaquePointer,
        table: String,
        id: String,
        data: [UInt8]) throws
    {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let idColumn = table == "gen_metadata" ? "idx" : "id"
        let sql = "INSERT INTO \(table) (\(idColumn), data) VALUES (?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AntigravityLocalReader.ScanFailure.invalid }
        if let integer = Int64(String(id)) {
            sqlite3_bind_int64(statement, 1, integer)
        } else {
            sqlite3_bind_text(statement, 1, String(id), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), nil)
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    private static func insertStep(
        _ database: OpaquePointer,
        idx: Int64,
        stepType: Int64,
        metadata: [UInt8]) throws
    {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO steps (idx, step_type, metadata) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AntigravityLocalReader.ScanFailure.invalid }
        sqlite3_bind_int64(statement, 1, idx)
        sqlite3_bind_int64(statement, 2, stepType)
        let result = metadata.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(metadata.count), nil)
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    private static func varint(_ field: Int, _ value: UInt64) -> [UInt8] {
        self.unsigned(UInt64(field << 3)) + self.unsigned(value)
    }

    private static func message(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        self.unsigned(UInt64(field << 3 | 2)) + self.unsigned(UInt64(bytes.count)) + bytes
    }

    private static func modernTurn() -> [UInt8] {
        let usage = self.varint(1, 11) + self.varint(2, 100) + self.varint(5, 50)
            + self.message(7, Array("bot-linux-1".utf8))
            + self.varint(9, 30) + self.varint(10, 7) + self.message(11, Array("response".utf8))
        let generation = self.varint(2, UInt64.max) + self.message(
            10, self.varint(1, 20_000) + self.varint(4, 256_000))
        let chat = self.message(4, usage) + self.message(9, generation)
            + self.message(19, Array("gemini-3-flash".utf8))
        return self.message(1, chat)
    }

    private static func aggregateRecord() -> [UInt8] {
        let usage = self.message(4, self.varint(1, 11))
        let conversation = self.message(1, self.varint(1, 1)) + usage
        return self.message(1, conversation)
    }

    private static func stepMetadata(botID: String, createdSeconds: UInt64, nanos: UInt64) -> [UInt8] {
        let timestamp = self.message(1, self.varint(1, createdSeconds) + self.varint(2, nanos))
        let botInfo = self.message(9, self.message(7, Array(botID.utf8)))
        return timestamp + botInfo
    }

    private static func unsigned(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        while value >= 128 {
            result.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }
}
#endif
#endif

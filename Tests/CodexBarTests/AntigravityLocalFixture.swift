import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Synthetic, not a private capture. Independent schema and JSONL producer provenance:
/// https://github.com/junhoyeo/tokscale/tree/62ca1eb1677556972ba963fdfa3a41ab23c1eb4b
/// crates/tokscale-core/src/sessions/antigravity_cli.rs records six DBs / 140 turns:
/// usage #9 text + #10 thinking == #3 total output. Modern timing evidence:
/// https://github.com/AstroQore/agent-session-kit/pull/11
/// path 1.9.10.1 is elapsed milliseconds and 1.9.10.4 is separate context metadata.
/// The separate producer in crates/tokscale-cli/src/antigravity.rs emits sessionId and retry usage.
final class AntigravityLocalFixture: Sendable {
    static let now = Date(timeIntervalSince1970: 1_787_832_000) // 2026-08-27 12:00 UTC
    static let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    let root: URL
    var environment: [String: String] {
        ["HOME": self.root.path]
    }

    var context: AntigravityLocalReader.Context {
        .init(environment: self.environment)
    }

    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-proof-\(UUID())")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: self.root) }

    func report(
        environment: [String: String]? = nil,
        limits: AntigravityLocalReader.Limits = .init(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> AntigravityLocalReader.DailyReportResult
    {
        try AntigravityLocalReader.makeDailyReportWithStatus(
            context: .init(environment: environment ?? self.environment),
            calendar: Self.calendar,
            limits: limits,
            clock: clock,
            checkCancellation: checkCancellation)
    }

    func snapshot(environment: [String: String]? = nil) async throws -> CostUsageTokenSnapshot {
        var options = CostUsageScanner.Options()
        options.calendar = Self.calendar
        options.cacheRoot = self.root.appendingPathComponent("scanner-cache")
        return try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: environment ?? self.environment,
            now: Self.now,
            forceRefresh: true,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)
    }

    @discardableResult
    func database(
        _ session: String = "session-a",
        rootIndex: Int = 0,
        blobs: [[UInt8]] = [],
        createdSeconds: UInt64? = nil,
        createdNanos: UInt64? = nil,
        sessionMetadataBlob: [UInt8]? = nil) throws -> URL
    {
        let directory = self.context.databaseRoots[rootIndex]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(session).db")
        let database = try Self.open(url)
        defer { sqlite3_close(database) }
        try Self.execute(database, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
        for (index, blob) in blobs.enumerated() {
            try Self.insert(database, row: Int64(index), blob: blob)
        }
        let metadata = sessionMetadataBlob ?? createdSeconds.map {
            Self.sessionMetadata(createdSeconds: $0, nanos: createdNanos)
        }
        if let metadata {
            try Self.execute(
                database,
                "CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB)")
            try Self.insertSessionMetadata(database, metadata: metadata)
        }
        return url
    }

    @discardableResult
    func jsonl(_ lines: [String], session: String = "cache", root: URL? = nil) throws -> URL {
        let directory = root ?? self.context.cacheRoot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw AntigravityLocalReader.ScanFailure.invalid
        }
        return database
    }

    static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AntigravityLocalReader.ScanFailure.invalid
        }
    }

    static func insert(_ database: OpaquePointer, row: Int64, blob: [UInt8]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK
        else { throw AntigravityLocalReader.ScanFailure.invalid }
        sqlite3_bind_int64(statement, 1, row)
        let result = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(blob.count), nil)
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    private static func insertSessionMetadata(_ database: OpaquePointer, metadata: [UInt8]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES (?, ?)",
            -1,
            &statement,
            nil) == SQLITE_OK else { throw AntigravityLocalReader.ScanFailure.invalid }
        sqlite3_bind_text(statement, 1, "main", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = metadata.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(metadata.count), nil)
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    static func varint(_ field: Int, _ value: UInt64) -> [UInt8] {
        self.unsigned(UInt64(field << 3)) + self.unsigned(value)
    }

    static func message(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        self.unsigned(UInt64(field << 3 | 2)) + self.unsigned(UInt64(bytes.count)) + bytes
    }

    private static func unsigned(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 128 {
            bytes.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    static func blob(
        model: String? = "fixture-model-a",
        label: String? = "Fixture model",
        system: UInt64 = 11,
        input: UInt64 = 100,
        output: UInt64 = 30,
        cacheRead: UInt64 = 50,
        reasoning: UInt64 = 7,
        response: String? = nil,
        seconds: UInt64? = 1_787_832_000) -> [UInt8]
    {
        var usage = self.varint(1, system) + self.varint(2, input) + self.varint(5, cacheRead)
            + self.varint(9, output) + self.varint(10, reasoning)
        if let response { usage += self.message(11, Array(response.utf8)) }
        var chat = self.message(4, usage)
        if let seconds {
            chat += self.message(9, self.message(4, self.varint(1, seconds) + self.varint(2, 250_000_000)))
        }
        if let model { chat += self.message(19, Array(model.utf8)) }
        if let label { chat += self.message(21, Array(label.utf8)) }
        return self.message(1, chat)
    }

    static func modernBlob(
        model: String? = "fixture-modern-model",
        label: String? = "Fixture modern model",
        response: String? = "modern-response",
        elapsedMilliseconds: UInt64 = 0,
        contextWindow: UInt64 = 128_000,
        generationMarker: UInt64 = UInt64.max,
        legacySeconds: UInt64? = nil,
        legacyNanos: UInt64 = 0,
        generationFields: [UInt8]? = nil) -> [UInt8]
    {
        var usage = self.varint(1, 11) + self.varint(2, 100) + self.varint(5, 50)
            + self.varint(9, 30) + self.varint(10, 7)
        if let response { usage += self.message(11, Array(response.utf8)) }
        var chat = self.message(4, usage)
        var generation = self.varint(2, generationMarker)
        if let generationFields {
            generation += generationFields
        } else {
            generation += self.message(
                10,
                self.relativeTimestamp(
                    elapsedMilliseconds: elapsedMilliseconds,
                    contextWindow: contextWindow))
        }
        if let legacySeconds {
            var legacy = self.varint(1, legacySeconds)
            if legacyNanos > 0 { legacy += self.varint(2, legacyNanos) }
            generation += self.message(4, legacy)
        }
        chat += self.message(9, generation)
        if let model { chat += self.message(19, Array(model.utf8)) }
        if let label { chat += self.message(21, Array(label.utf8)) }
        return self.message(1, chat)
    }

    static func relativeTimestamp(elapsedMilliseconds: UInt64, contextWindow: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        // Proto3 omits the zero-valued elapsed offset.
        if elapsedMilliseconds > 0 { bytes += self.varint(1, elapsedMilliseconds) }
        bytes += self.varint(4, contextWindow)
        return bytes
    }

    static func sessionMetadata(createdSeconds: UInt64, nanos: UInt64? = nil) -> [UInt8] {
        var timestamp = self.varint(1, createdSeconds)
        if let nanos { timestamp += self.varint(2, nanos) }
        return self.message(2, timestamp)
    }

    static func conversationMarkerBlob(
        marker: [UInt8]? = nil,
        includeGeneration: Bool = false) -> [UInt8]
    {
        let markerField = marker ?? self.message(1, self.varint(1, 1))
        var conversation = markerField + self.message(4, self.varint(1, 11))
        if includeGeneration {
            let usage = self.varint(1, 11) + self.varint(2, 100) + self.varint(5, 50)
                + self.varint(9, 30) + self.varint(10, 7)
            let generation = self.varint(2, UInt64.max) + self.message(
                10,
                self.relativeTimestamp(elapsedMilliseconds: 0, contextWindow: 128_000))
            conversation += self.message(4, usage) + self.message(9, generation)
        }
        return self.message(1, conversation)
    }

    static let cacheUsage =
        #"{"type":"usage","sessionId":"cache-session","input":100,"output":30,"cacheRead":50,"#
            + #""cacheWrite":0,"reasoning":0,"timestamp":1787832000250,"responseId":null}"#
}

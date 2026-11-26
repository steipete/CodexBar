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
/// crates/tokscale-core/src/sessions/antigravity_cli.rs records six DBs / 140 turns and the
/// usage #9 + #10 == #3 total output identity. Tokscale itself reads #9 as text and #10 as thinking;
/// ccusage's Antigravity adapter reads #9 as reasoning and #10 as text, and this fixture follows
/// ccusage, per independent confirmation from decoding real local databases. The opaque 1.1.18 time
/// inference is NOT used. The separate producer in crates/tokscale-cli/src/antigravity.rs emits
/// sessionId and retry usage.
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
        scanOptions: AntigravityLocalScanOptions = .defaultOptions,
        limits: AntigravityLocalReader.Limits = .init(),
        includeBreakdowns: Bool = false,
        dayRange: (sinceKey: String, untilKey: String)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> AntigravityLocalReader.DailyReportResult
    {
        try AntigravityLocalReader.makeDailyReportWithStatus(
            context: .init(environment: environment ?? self.environment, scanOptions: scanOptions),
            calendar: Self.calendar,
            limits: limits,
            includeBreakdowns: includeBreakdowns,
            dayRange: dayRange,
            clock: clock,
            checkCancellation: checkCancellation)
    }

    func snapshot(
        environment: [String: String]? = nil,
        scanOptions: AntigravityLocalScanOptions = .defaultOptions,
        historyDays: Int = 30) async throws -> CostUsageTokenSnapshot
    {
        var options = CostUsageScanner.Options()
        options.calendar = Self.calendar
        options.cacheRoot = self.root.appendingPathComponent("scanner-cache")
        return try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: environment ?? self.environment,
            antigravityScanOptions: scanOptions,
            now: Self.now,
            forceRefresh: true,
            historyDays: historyDays,
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
        stepBlobs: [[UInt8]]? = nil,
        trajectoryMetadataBlob: [UInt8]? = nil) throws -> URL
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
        if let stepBlobs {
            try Self.execute(database, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)")
            for (index, blob) in stepBlobs.enumerated() {
                try Self.insertStep(database, row: Int64(index), blob: blob)
            }
        }
        if let trajectoryMetadataBlob {
            try Self.addTrajectoryMetadata(database, blob: trajectoryMetadataBlob)
        }
        return url
    }

    struct WorkspaceFixture {
        var workspaceURI: String?
        var gitRootURI: String?
        var repoSlug: String?
        var repoRemoteURL: String?
        var repoUpstreamURL: String?
        var branch: String?
    }

    static func trajectoryMetadataBlob(
        workspaces: [WorkspaceFixture] = [],
        parentCascadeID: String? = nil,
        rootCascadeID: String? = nil,
        primaryWorkspaceURI: String? = nil,
        projectID: String? = nil,
        opaqueField4Size: Int = 0) -> [UInt8]
    {
        var bytes: [UInt8] = []
        for workspace in workspaces {
            var entry: [UInt8] = []
            if let uri = workspace.workspaceURI {
                entry += self.message(1, Array(uri.utf8))
            }
            if let gitRoot = workspace.gitRootURI {
                entry += self.message(2, Array(gitRoot.utf8))
            }
            var repo: [UInt8] = []
            if let slug = workspace.repoSlug {
                repo += self.message(1, Array(slug.utf8))
            }
            if let remote = workspace.repoRemoteURL {
                repo += self.message(2, Array(remote.utf8))
            }
            if let upstream = workspace.repoUpstreamURL {
                repo += self.message(3, Array(upstream.utf8))
            }
            if !repo.isEmpty || workspace.repoSlug != nil {
                entry += self.message(3, repo)
            }
            if let branch = workspace.branch {
                entry += self.message(4, Array(branch.utf8))
            }
            bytes += self.message(1, entry)
        }
        if opaqueField4Size > 0 {
            bytes += self.message(4, Array(repeating: 0xAA, count: opaqueField4Size))
        }
        if let parentCascadeID {
            bytes += self.message(5, Array(parentCascadeID.utf8))
        }
        if let rootCascadeID {
            bytes += self.message(6, Array(rootCascadeID.utf8))
        }
        if let primaryWorkspaceURI {
            bytes += self.message(7, Array(primaryWorkspaceURI.utf8))
        }
        if let projectID {
            bytes += self.message(18, Array(projectID.utf8))
        }
        return bytes
    }

    static func addTrajectoryMetadata(_ database: OpaquePointer, blob: [UInt8]) throws {
        try self.execute(database, "CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB)")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?)",
            -1,
            &statement,
            nil) == SQLITE_OK
        else { throw AntigravityLocalReader.ScanFailure.invalid }
        let result = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(blob.count), nil)
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    struct ConversationSummaryRowFixture {
        let conversationID: String
        let title: String
        let workspaceURIsJSON: String
        let projectID: String
        let parentConversationID: String
    }

    @discardableResult
    func conversationSummariesDatabase(
        relativePath: String = "antigravity/conversation_summaries.db",
        rows: [ConversationSummaryRowFixture],
        walMode: Bool = false) throws -> URL
    {
        let geminiHome = self.root.appendingPathComponent(".gemini", isDirectory: true)
        let url = geminiHome.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try Self.open(url)
        defer { sqlite3_close(database) }
        if walMode {
            try Self.execute(database, "PRAGMA journal_mode=WAL")
        }
        try Self.execute(database, """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            workspace_uris TEXT NOT NULL DEFAULT '',
            project_id TEXT NOT NULL DEFAULT '',
            parent_conversation_id TEXT NOT NULL DEFAULT ''
        )
        """)
        for row in rows {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            INSERT INTO conversation_summaries
                (conversation_id, title, workspace_uris, project_id, parent_conversation_id)
            VALUES (?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AntigravityLocalReader.ScanFailure.invalid
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, row.conversationID, -1, transient)
            sqlite3_bind_text(statement, 2, row.title, -1, transient)
            sqlite3_bind_text(statement, 3, row.workspaceURIsJSON, -1, transient)
            sqlite3_bind_text(statement, 4, row.projectID, -1, transient)
            sqlite3_bind_text(statement, 5, row.parentConversationID, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AntigravityLocalReader.ScanFailure.invalid
            }
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
            if let database {
                sqlite3_close(database)
            }
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

    static func insertStep(_ database: OpaquePointer, row: Int64, blob: [UInt8]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database, "INSERT INTO steps (idx, metadata) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK
        else { throw AntigravityLocalReader.ScanFailure.invalid }
        sqlite3_bind_int64(statement, 1, row)
        let result = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(blob.count), nil)
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
        modelID: UInt64 = 1298,
        input: UInt64 = 100,
        output: UInt64 = 30,
        cacheRead: UInt64 = 50,
        reasoning: UInt64 = 7,
        response: String? = nil,
        seconds: UInt64? = 1_787_832_000) -> [UInt8]
    {
        var usage = self.varint(1, modelID) + self.varint(2, input) + self.varint(5, cacheRead)
            + self.varint(9, reasoning) + self.varint(10, output)
        if let response {
            usage += self.message(11, Array(response.utf8))
        }
        var chat = self.message(4, usage)
        if let seconds {
            chat += self.message(9, self.message(4, self.varint(1, seconds) + self.varint(2, 250_000_000)))
        }
        if let model {
            chat += self.message(19, Array(model.utf8))
        }
        if let label {
            chat += self.message(21, Array(label.utf8))
        }
        return self.message(1, chat)
    }

    static func blobWithRootEnvelope(
        stepUUID: String? = "step-uuid-1",
        botID: String? = nil,
        model: String? = "fixture-model-a",
        label: String? = "Fixture model",
        modelID: UInt64 = 1298,
        input: UInt64 = 100,
        output: UInt64 = 30,
        cacheRead: UInt64 = 50,
        reasoning: UInt64 = 7,
        response: String? = nil,
        seconds: UInt64? = nil) -> [UInt8]
    {
        var root = self.message(2, [0x01, 0x02])
        if let stepUUID {
            root += self.message(4, Array(stepUUID.utf8))
        }
        var usage = self.varint(1, modelID) + self.varint(2, input) + self.varint(5, cacheRead)
            + self.varint(9, reasoning) + self.varint(10, output)
        if let botID {
            usage += self.message(7, Array(botID.utf8))
        }
        if let response {
            usage += self.message(11, Array(response.utf8))
        }
        var chat = self.message(4, usage)
        if let seconds {
            chat += self.message(9, self.message(4, self.varint(1, seconds) + self.varint(2, 250_000_000)))
        }
        if let model {
            chat += self.message(19, Array(model.utf8))
        }
        if let label {
            chat += self.message(21, Array(label.utf8))
        }
        root += self.message(1, chat)
        return root
    }

    static func stepMetadataBlob(
        stepUUID: String? = "step-uuid-1",
        botID: String? = nil,
        seconds: UInt64 = 1_787_832_000,
        nanos: UInt64 = 250_000_000) -> [UInt8]
    {
        var meta = self.message(1, self.varint(1, seconds) + self.varint(2, nanos))
        if let botID {
            let usage = self.message(7, Array(botID.utf8))
            meta += self.message(9, usage)
        }
        if let stepUUID {
            meta += self.message(12, Array(stepUUID.utf8))
        }
        return meta
    }

    static let cacheUsage =
        #"{"type":"usage","sessionId":"cache-session","input":100,"output":30,"cacheRead":50,"#
            + #""cacheWrite":0,"reasoning":0,"timestamp":1787832000250,"responseId":null}"#
}

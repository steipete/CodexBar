#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Independent OpenCodex usage cache. Never writes Codex `cost-usage.sqlite`.
public struct OpenCodexUsageStore: Sendable {
    public static let databaseFilename = "opencodex-usage.sqlite"
    private static let schemaVersion = 2
    private static let cursorMetaKey = "parseCursor"
    private static let prefixDigestByteLimit = 64 * 1024

    private let databaseURL: URL

    public init(cacheRoot: URL) {
        self.databaseURL = cacheRoot.appendingPathComponent(Self.databaseFilename, isDirectory: false)
    }

    static func withLogReadRecorderForTesting<T>(
        _ recorder: OpenCodexUsageParser.LogReadRecorder,
        operation: () throws -> T) rethrows -> T
    {
        try OpenCodexUsageParser.withLogReadRecorderForTesting(recorder, operation: operation)
    }

    public func loadSnapshot(
        logURL: URL,
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        customPricing: CostUsageCustomPricing = .empty,
        fileManager: FileManager = .default) throws -> CostUsageTokenSnapshot
    {
        let entries = try self.loadEntries(logURL: logURL, fileManager: fileManager)
        return OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            customPricing: customPricing)
    }

    public func loadEntries(logURL: URL, fileManager: FileManager = .default) throws -> [OpenCodexUsageEntry] {
        var shouldRetryStaleWrite = true
        while true {
            guard fileManager.fileExists(atPath: logURL.path) else { return [] }
            guard let identity = Self.statLog(at: logURL) else { return [] }
            let cursor = self.readCursor()
            if let cursor, Self.canReuseCursor(cursor, identity: identity) {
                if identity.size == cursor.parsedOffset {
                    if let cached = self.readCachedEntries() {
                        return cached
                    }
                } else if let entries = try self.incrementalReload(
                    logURL: logURL,
                    identity: identity,
                    cursor: cursor,
                    fileManager: fileManager)
                {
                    return entries
                } else if shouldRetryStaleWrite {
                    // Another loader committed a later same-file cursor. Re-run the cursor
                    // path once against that durable state, then fall back to a full reload.
                    shouldRetryStaleWrite = false
                    continue
                } else {
                    return try self.fullReload(
                        logURL: logURL,
                        identity: identity,
                        fileManager: fileManager)
                }
            }
            return try self.fullReload(logURL: logURL, identity: identity, fileManager: fileManager)
        }
    }

    func parseCursorForTesting() -> (
        parsedOffset: Int64,
        prefixDigest: String,
        fileIdentity: String,
        path: String)?
    {
        guard let cursor = self.readCursor() else { return nil }
        return (cursor.parsedOffset, cursor.prefixDigest, cursor.fileIdentity, cursor.path)
    }

    func writeIncrementalEntriesForTesting(
        _ entries: [OpenCodexUsageEntry],
        path: String,
        fileIdentity: String,
        parsedOffset: Int64,
        prefixDigest: String)
    {
        _ = self.writeEntries(
            entries,
            cursor: ParseCursor(
                path: path,
                fileIdentity: fileIdentity,
                parsedOffset: parsedOffset,
                prefixDigest: prefixDigest),
            replaceAll: false)
    }

    private func fullReload(
        logURL: URL,
        identity: LogIdentity,
        fileManager: FileManager) throws -> [OpenCodexUsageEntry]
    {
        let parsed = try OpenCodexUsageParser.parseLog(fileURL: logURL, from: 0, fileManager: fileManager)
        let entries = Self.dedupedAndSorted(parsed.entries)
        let cursor = ParseCursor(
            path: identity.path,
            fileIdentity: identity.fileIdentity,
            parsedOffset: parsed.nextOffset,
            prefixDigest: Self.prefixDigest(fileURL: logURL, parsedOffset: parsed.nextOffset) ?? "")
        self.replaceCachedEntries(Self.dedupedAndSorted(parsed.newlineTerminatedEntries), cursor: cursor)
        return entries
    }

    /// Returns `nil` when the incremental write observed a newer same-file durable cursor.
    private func incrementalReload(
        logURL: URL,
        identity: LogIdentity,
        cursor: ParseCursor,
        fileManager: FileManager) throws -> [OpenCodexUsageEntry]?
    {
        guard let existing = self.readCachedEntries() else {
            return try self.fullReload(logURL: logURL, identity: identity, fileManager: fileManager)
        }
        let parsed = try OpenCodexUsageParser.parseLog(
            fileURL: logURL,
            from: cursor.parsedOffset,
            fileManager: fileManager)
        let nextOffset = parsed.nextOffset
        let committed = parsed.newlineTerminatedEntries
        let pending = parsed.pendingTrailingEntries
        if committed.isEmpty, nextOffset == cursor.parsedOffset {
            return Self.dedupedAndSorted(existing + pending)
        }
        let digest = nextOffset == cursor.parsedOffset
            ? cursor.prefixDigest
            : (Self.prefixDigest(fileURL: logURL, parsedOffset: nextOffset) ?? "")
        if self.insertCachedEntries(
            committed,
            cursor: ParseCursor(
                path: identity.path,
                fileIdentity: identity.fileIdentity,
                parsedOffset: nextOffset,
                prefixDigest: digest)) == .stale
        {
            return nil
        }
        return Self.dedupedAndSorted(existing + committed + pending)
    }

    private func readCachedEntries() -> [OpenCodexUsageEntry]? {
        guard let db = self.open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        guard Self.userVersion(db) == Self.schemaVersion else { return nil }
        var statement: OpaquePointer?
        let sql = """
        SELECT request_id, timestamp, provider, model, usage_status, account_label, surface, conversation_id, \
        input_tokens, output_tokens, cached_input_tokens, cache_read_input_tokens, \
        cache_creation_input_tokens, reasoning_output_tokens, usage_total_tokens, total_tokens
        FROM entries
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var entries: [OpenCodexUsageEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let requestID = Self.text(statement, 0),
               let provider = Self.text(statement, 2),
               let model = Self.text(statement, 3),
               let statusRaw = Self.text(statement, 4)
            {
                let usage = Self.tokenUsage(
                    inputTokens: Self.int(statement, 8),
                    outputTokens: Self.int(statement, 9),
                    cachedInputTokens: Self.int(statement, 10),
                    cacheReadInputTokens: Self.int(statement, 11),
                    cacheCreationInputTokens: Self.int(statement, 12),
                    reasoningOutputTokens: Self.int(statement, 13),
                    totalTokens: Self.int(statement, 14))
                entries.append(OpenCodexUsageEntry(
                    requestID: requestID,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    provider: provider,
                    model: model,
                    usageStatus: OpenCodexUsageStatus(rawValue: statusRaw) ?? .unreported,
                    accountLogLabel: Self.text(statement, 5),
                    surface: Self.text(statement, 6),
                    conversationID: Self.text(statement, 7),
                    usage: usage,
                    totalTokens: Self.int(statement, 15)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return nil }
        return Self.dedupedAndSorted(entries)
    }

    private func replaceCachedEntries(_ entries: [OpenCodexUsageEntry], cursor: ParseCursor) {
        self.writeEntries(entries, cursor: cursor, replaceAll: true)
    }

    private func insertCachedEntries(_ entries: [OpenCodexUsageEntry], cursor: ParseCursor) -> CachedWriteResult {
        self.writeEntries(entries, cursor: cursor, replaceAll: false)
    }

    @discardableResult
    private func writeEntries(
        _ entries: [OpenCodexUsageEntry],
        cursor: ParseCursor,
        replaceAll: Bool) -> CachedWriteResult
    {
        guard let db = self.open(readOnly: false) else { return .applied }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return .applied }
        // Incremental appends only (`replaceAll == false`): after BEGIN IMMEDIATE, re-read the
        // durable cursor. A concurrent loader may already have committed a later parsedOffset
        // for this path + fileIdentity; writing this snapshot would move the cursor backwards
        // and re-insert rows it already stored. Full reloads re-derived the whole file and must
        // still replace even a newer cursor (truncation, rotation, schema rebuild).
        if !replaceAll, Self.isStaleIncrementalCursor(proposed: cursor, durable: Self.parseCursor(from: db)) {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return .stale
        }
        if replaceAll {
            _ = sqlite3_exec(db, "DELETE FROM entries", nil, nil, nil)
        }
        Self.setCursor(db, cursor)
        guard Self.insertEntries(db, entries) else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return .applied
        }
        _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return .applied
    }

    private func open(readOnly: Bool) -> OpaquePointer? {
        if !readOnly {
            try? FileManager.default.createDirectory(
                at: self.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(self.databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 250)
        if !readOnly {
            _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
            Self.ensureSchema(db)
        }
        return db
    }

    private func readCursor() -> ParseCursor? {
        guard let db = self.open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        guard Self.userVersion(db) == Self.schemaVersion else { return nil }
        return Self.parseCursor(from: db)
    }

    private static func parseCursor(from db: OpaquePointer?) -> ParseCursor? {
        guard let raw = self.meta(db, key: cursorMetaKey),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ParseCursor.self, from: data)
    }

    private static func isStaleIncrementalCursor(proposed: ParseCursor, durable: ParseCursor?) -> Bool {
        guard let durable else { return false }
        return durable.path == proposed.path
            && durable.fileIdentity == proposed.fileIdentity
            && durable.parsedOffset >= proposed.parsedOffset
    }

    /// Threat model: the digest covers only the first min(64 KiB, parsedOffset) bytes, so an
    /// in-place rewrite past 64 KiB that preserves size and inode is not detected. Rotation
    /// changes the inode and truncation trips `size >= parsedOffset`. Acceptable because the log
    /// is append-only.
    private static func canReuseCursor(_ cursor: ParseCursor, identity: LogIdentity) -> Bool {
        cursor.path == identity.path
            && cursor.fileIdentity == identity.fileIdentity
            && identity.size >= cursor.parsedOffset
            && self.prefixDigest(fileURL: identity.url, parsedOffset: cursor.parsedOffset) == cursor.prefixDigest
    }

    private static func ensureSchema(_ db: OpaquePointer?) {
        // `!= schemaVersion` deliberately rebuilds a NEWER database too: a downgrade must not
        // read a schema it does not understand.
        guard self.userVersion(db) != self.schemaVersion else { return }
        let sql = """
        DROP TABLE IF EXISTS entries;
        DROP TABLE IF EXISTS meta;
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE entries (
            request_id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            usage_status TEXT NOT NULL,
            account_label TEXT,
            surface TEXT,
            conversation_id TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cached_input_tokens INTEGER,
            cache_read_input_tokens INTEGER,
            cache_creation_input_tokens INTEGER,
            reasoning_output_tokens INTEGER,
            usage_total_tokens INTEGER,
            total_tokens INTEGER
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return }
        Self.setUserVersion(db, Self.schemaVersion)
    }

    private static func insertEntries(_ db: OpaquePointer?, _ entries: [OpenCodexUsageEntry]) -> Bool {
        var statement: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO entries(
            request_id, timestamp, provider, model, usage_status, account_label, surface, conversation_id,
            input_tokens, output_tokens, cached_input_tokens, cache_read_input_tokens,
            cache_creation_input_tokens, reasoning_output_tokens, usage_total_tokens, total_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        for entry in entries {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(statement, 1, entry.requestID)
            sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
            Self.bind(statement, 3, entry.provider)
            Self.bind(statement, 4, entry.model)
            Self.bind(statement, 5, entry.usageStatus.rawValue)
            Self.bind(statement, 6, entry.accountLogLabel)
            Self.bind(statement, 7, entry.surface)
            Self.bind(statement, 8, entry.conversationID)
            Self.bind(statement, 9, entry.usage?.inputTokens)
            Self.bind(statement, 10, entry.usage?.outputTokens)
            Self.bind(statement, 11, entry.usage?.cachedInputTokens)
            Self.bind(statement, 12, entry.usage?.cacheReadInputTokens)
            Self.bind(statement, 13, entry.usage?.cacheCreationInputTokens)
            Self.bind(statement, 14, entry.usage?.reasoningOutputTokens)
            Self.bind(statement, 15, entry.usage?.totalTokens)
            Self.bind(statement, 16, entry.totalTokens)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        }
        return true
    }

    private static func userVersion(_ db: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func setUserVersion(_ db: OpaquePointer?, _ version: Int) {
        _ = sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    private static func meta(_ db: OpaquePointer?, key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.text(statement, 0)
    }

    private static func setCursor(_ db: OpaquePointer?, _ cursor: ParseCursor) {
        guard let data = try? JSONEncoder().encode(cursor),
              let value = String(data: data, encoding: .utf8)
        else { return }
        Self.setMeta(db, key: Self.cursorMetaKey, value: value)
    }

    private static func setMeta(_ db: OpaquePointer?, key: String, value: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            -1,
            &statement,
            nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, key)
        Self.bind(statement, 2, value)
        _ = sqlite3_step(statement)
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    // Token fields are stored as independent nullable columns; keep the mapping explicit.
    // swiftlint:disable:next function_parameter_count
    private static func tokenUsage(
        inputTokens: Int?,
        outputTokens: Int?,
        cachedInputTokens: Int?,
        cacheReadInputTokens: Int?,
        cacheCreationInputTokens: Int?,
        reasoningOutputTokens: Int?,
        totalTokens: Int?) -> OpenCodexTokenUsage?
    {
        if inputTokens == nil,
           outputTokens == nil,
           cachedInputTokens == nil,
           cacheReadInputTokens == nil,
           cacheCreationInputTokens == nil,
           reasoningOutputTokens == nil,
           totalTokens == nil
        {
            return nil
        }
        return OpenCodexTokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens)
    }

    private static func dedupedAndSorted(_ entries: [OpenCodexUsageEntry]) -> [OpenCodexUsageEntry] {
        var unique: [String: OpenCodexUsageEntry] = [:]
        unique.reserveCapacity(entries.count)
        for entry in entries {
            unique[entry.requestID] = entry
        }
        return self.sortedEntries(Array(unique.values))
    }

    private static func sortedEntries(_ entries: [OpenCodexUsageEntry]) -> [OpenCodexUsageEntry] {
        entries.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.requestID < $1.requestID
        }
    }

    private static func statLog(at url: URL) -> LogIdentity? {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return nil }
            var status = stat()
            guard stat(pointer, &status) == 0 else { return nil }
            return LogIdentity(
                url: url,
                path: url.path,
                fileIdentity: "\(status.st_dev):\(status.st_ino)",
                size: Int64(status.st_size))
        }
    }

    /// Covers only the first min(64 KiB, parsedOffset) bytes; see `canReuseCursor` for the threat model.
    private static func prefixDigest(fileURL: URL, parsedOffset: Int64) -> String? {
        let length = min(Int64(Self.prefixDigestByteLimit), max(0, parsedOffset))
        let prefix: Data
        if length == 0 {
            prefix = Data()
        } else {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: Int(length)), data.count == Int(length) else {
                return nil
            }
            prefix = data
        }
        return SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
    }

    private enum CachedWriteResult: Equatable {
        case applied
        case stale
    }

    private struct ParseCursor: Equatable, Sendable, Codable {
        var path: String
        var fileIdentity: String
        var parsedOffset: Int64
        var prefixDigest: String
    }

    private struct LogIdentity: Equatable, Sendable {
        var url: URL
        var path: String
        var fileIdentity: String
        var size: Int64
    }
}

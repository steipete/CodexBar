#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation

/// Independent OpenCodex usage cache. Never writes Codex `cost-usage.sqlite`.
public struct OpenCodexUsageStore: Sendable {
    public static let databaseFilename = "opencodex-usage.sqlite"
    private static let schemaVersion = 1

    private let databaseURL: URL

    public init(cacheRoot: URL) {
        self.databaseURL = cacheRoot.appendingPathComponent(Self.databaseFilename, isDirectory: false)
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

    func loadEntries(logURL: URL, fileManager: FileManager) throws -> [OpenCodexUsageEntry] {
        guard fileManager.fileExists(atPath: logURL.path) else { return [] }
        let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(logURL.path)|\(size)|\(mtime)"

        if let cached = self.readCachedEntries(identity: identity), !cached.isEmpty {
            return cached
        }

        let parsed = try OpenCodexUsageParser.parse(fileURL: logURL, fileManager: fileManager)
        var unique: [String: OpenCodexUsageEntry] = [:]
        for entry in parsed {
            unique[entry.requestID] = entry
        }
        let deduped = unique.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.requestID < $1.requestID
        }
        self.replaceCachedEntries(deduped, identity: identity)
        return deduped
    }

    private func readCachedEntries(identity: String) -> [OpenCodexUsageEntry]? {
        guard let db = self.open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        guard Self.userVersion(db) == Self.schemaVersion,
              Self.meta(db, key: "identity") == identity
        else { return nil }
        var statement: OpaquePointer?
        let sql = """
        SELECT request_id, timestamp, provider, model, usage_status, account_label, surface, conversation_id, payload
        FROM entries
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var entries: [OpenCodexUsageEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let payload = Self.text(statement, 8),
                  let data = payload.data(using: .utf8),
                  let entry = OpenCodexUsageParser.parse(data)
            else { continue }
            entries.append(entry)
        }
        return entries
    }

    private func replaceCachedEntries(_ entries: [OpenCodexUsageEntry], identity: String) {
        guard let db = self.open(readOnly: false) else { return }
        defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM entries", nil, nil, nil)
        Self.setMeta(db, key: "identity", value: identity)
        var statement: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO entries(
            request_id, timestamp, provider, model, usage_status, account_label, surface, conversation_id, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
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
            let payload = Self.payloadJSON(entry)
            Self.bind(statement, 9, payload)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
        }
        _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
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

    private static func ensureSchema(_ db: OpaquePointer?) {
        guard self.userVersion(db) == 0 else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS entries (
            request_id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            usage_status TEXT NOT NULL,
            account_label TEXT,
            surface TEXT,
            conversation_id TEXT,
            payload TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return }
        Self.setUserVersion(db, Self.schemaVersion)
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

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func payloadJSON(_ entry: OpenCodexUsageEntry) -> String {
        var object: [String: Any] = [
            "requestId": entry.requestID,
            "timestamp": entry.timestamp.timeIntervalSince1970 * 1000,
            "provider": entry.provider,
            "model": entry.model,
            "usageStatus": entry.usageStatus.rawValue,
        ]
        if let accountLogLabel = entry.accountLogLabel {
            object["accountLogLabel"] = accountLogLabel
        }
        if let surface = entry.surface {
            object["surface"] = surface
        }
        if let conversationID = entry.conversationID {
            object["conversationId"] = conversationID
        }
        if let totalTokens = entry.totalTokens {
            object["totalTokens"] = totalTokens
        }
        if let usage = entry.usage {
            var usageObject: [String: Any] = [:]
            if let inputTokens = usage.inputTokens {
                usageObject["inputTokens"] = inputTokens
            }
            if let outputTokens = usage.outputTokens {
                usageObject["outputTokens"] = outputTokens
            }
            if let cachedInputTokens = usage.cachedInputTokens {
                usageObject["cachedInputTokens"] = cachedInputTokens
            }
            if let cacheReadInputTokens = usage.cacheReadInputTokens {
                usageObject["cacheReadInputTokens"] = cacheReadInputTokens
            }
            if let cacheCreationInputTokens = usage.cacheCreationInputTokens {
                usageObject["cacheCreationInputTokens"] = cacheCreationInputTokens
            }
            if let reasoningOutputTokens = usage.reasoningOutputTokens {
                usageObject["reasoningOutputTokens"] = reasoningOutputTokens
            }
            if let totalTokens = usage.totalTokens {
                usageObject["totalTokens"] = totalTokens
            }
            object["usage"] = usageObject
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

import Dispatch
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Captured by the native adapter. UI code never discovers another account's cache or session files.
public struct CostUsageSessionDetailSource: Sendable, Equatable, Hashable {
    public let databaseURL: URL
    public let sessionSource: SessionToolActivitySource
    public let parsedBytes: Int64?

    public init(databaseURL: URL, sessionSource: SessionToolActivitySource, parsedBytes: Int64?) {
        self.databaseURL = databaseURL
        self.sessionSource = sessionSource
        self.parsedBytes = parsedBytes
    }
}

public enum CostUsageSessionDetailError: Error, Sendable, Equatable {
    case unavailable, sourceChanged, limitExceeded
}

/// No cache: the selected SwiftUI pane owns the only retained request-detail result.
public enum CostUsageSessionDetailLoader {
    private static let queue = DispatchQueue(label: "com.steipete.codexbar.session-details", qos: .utility)

    struct Limits: Sendable {
        var requests = 5000
        var payloadBytes = 8 * 1024 * 1024
        var metadataBytes = 1024 * 1024
        var pricingMetadataBytes = 1024 * 1024
        var aggregates = 5000
    }

    public static func load(
        source: CostUsageSessionDetailSource,
        lastActivity: Date,
        range: Range<Date>,
        timeZone: TimeZone) async throws -> [CostUsageSessionTurn]
    {
        try await CostUsageScanExecutor.run(on: self.queue) { checkCancellation in
            try self.read(
                source: source,
                lastActivity: lastActivity,
                range: range,
                timeZone: timeZone,
                checkCancellation: checkCancellation)
        }
    }

    static func read(
        source: CostUsageSessionDetailSource,
        lastActivity: Date,
        range: Range<Date>,
        timeZone: TimeZone,
        limits: Limits = Limits(),
        catalog: ModelsDevCatalog? = nil,
        checkCancellation: () throws -> Void = {}) throws -> [CostUsageSessionTurn]
    {
        try checkCancellation()
        guard range.lowerBound < range.upperBound else { throw CostUsageSessionDetailError.unavailable }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(source.databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CostUsageSessionDetailError.unavailable
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 500)
        guard try CostUsageStore.scalarInt(database, "PRAGMA user_version") == Int64(CostUsageStore.schemaVersion)
        else { throw CostUsageSessionDetailError.sourceChanged }
        let cache = try CostUsageStore.inReadTransaction(database) {
            try self.readSelectedCache(
                database,
                source: source,
                lastActivity: lastActivity,
                limits: limits,
                checkCancellation: checkCancellation)
        }
        try checkCancellation()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = CostUsageScanner.CostUsageDayRange(
            since: range.lowerBound,
            until: range.upperBound.addingTimeInterval(-0.001),
            calendar: calendar)
        var turns = CostUsageScanner.SessionTurns()
        let cacheRoot = source.databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: days,
            modelsDevCatalog: catalog,
            modelsDevCacheRoot: cacheRoot,
            onPricedRow: { row, cost, complete in turns.add(row, cost: cost, isComplete: complete) })
        try checkCancellation()
        return turns.build(report: report)
    }

    private static func readSelectedCache(
        _ database: OpaquePointer,
        source: CostUsageSessionDetailSource,
        lastActivity: Date,
        limits: Limits,
        checkCancellation: () throws -> Void) throws -> CostUsageCache
    {
        let path = source.sessionSource.fileURL.path
        let fileID = try self.validateFile(database, source: source, lastActivity: lastActivity, limits: limits)
        try self.validateBudget(
            database,
            sql: "SELECT length(payload) AS bytes FROM usage_rows WHERE file_id = ? LIMIT ?",
            fileID: fileID,
            rows: limits.requests,
            bytes: limits.payloadBytes)
        try self.validateBudget(
            database,
            sql: "SELECT length(cast(model AS BLOB)) AS bytes " +
                "FROM file_day_aggregates WHERE file_id = ? LIMIT ?",
            fileID: fileID,
            rows: limits.aggregates,
            bytes: limits.metadataBytes)
        try checkCancellation()
        let statement = try CostUsageStore.prepare(database, CostUsageStore.fileSelectSQL + " WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        CostUsageStore.bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CostUsageSessionDetailError.unavailable }
        let file = try CostUsageStore.decodeFile(statement)
        let decoder = JSONDecoder()
        var rows: [CostUsageScanner.CodexUsageRow] = []
        var readError: Error?
        try CostUsageStore.forEachUsageRow(database, path: path) { stored in
            // The budget preflight runs in the same read transaction as this bounded stream.
            guard readError == nil else { return }
            do {
                try checkCancellation()
                try rows.append(decoder.decode(CostUsageScanner.CodexUsageRow.self, from: stored.payload))
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        try checkCancellation()
        let aggregates = try CostUsageStore.readFileDayAggregates(database, path: path)
        let snapshot = CostUsageStoreSnapshot(
            metadata: .empty,
            files: [file],
            tokenSnapshots: [],
            fileDayAggregates: aggregates,
            dayAggregates: aggregates.map(\.aggregate),
            forkLineage: [],
            bufferedLines: [],
            discoveryState: nil,
            lookbackState: nil,
            accumulators: [])
        var cache = CostUsageStore.decodeCodexCache(
            from: snapshot,
            recorder: nil,
            tokenSnapshotsLoaded: false,
            decodedUsageRows: [path: rows],
            includesRequestLedgerState: false)
        cache.codexResolvedPriorityTurns = try self.readPriorityEvidence(
            database,
            turnIDs: Set(rows.compactMap(\.turnID)),
            maximumBytes: limits.pricingMetadataBytes)
        return cache
    }

    private struct PricingPayload: Decodable {
        let priorityTurnStatePayload: Data?
    }

    private struct SelectedPriorityEvidence: Decodable {
        static let selectionKey = CodingUserInfoKey(rawValue: "selectedSessionTurnIDs")!
        let turns: [String: CostUsageScanner.CodexPriorityTurnMetadata]

        private enum CodingKeys: String, CodingKey { case resolvedTurns }
        private struct TurnKey: CodingKey {
            let stringValue: String
            var intValue: Int? {
                nil
            }

            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: CodingKeys.self)
            guard root.contains(.resolvedTurns), try !root.decodeNil(forKey: .resolvedTurns) else {
                self.turns = [:]
                return
            }
            let values = try root.nestedContainer(keyedBy: TurnKey.self, forKey: .resolvedTurns)
            let selected = decoder.userInfo[Self.selectionKey] as? Set<String> ?? []
            var turns: [String: CostUsageScanner.CodexPriorityTurnMetadata] = [:]
            for id in selected {
                if let value = try values.decodeIfPresent(
                    CostUsageScanner.CodexPriorityTurnMetadata.self,
                    forKey: TurnKey(stringValue: id))
                {
                    turns[id] = value
                }
            }
            self.turns = turns
        }
    }

    private static func readPriorityEvidence(
        _ database: OpaquePointer,
        turnIDs: Set<String>,
        maximumBytes: Int) throws -> [String: CostUsageScanner.CodexPriorityTurnMetadata]
    {
        guard !turnIDs.isEmpty else { return [:] }
        let preflight = try CostUsageStore.prepare(database, "SELECT length(payload) FROM scan_metadata WHERE id = 1")
        defer { sqlite3_finalize(preflight) }
        let status = sqlite3_step(preflight)
        if status == SQLITE_DONE { return [:] }
        guard status == SQLITE_ROW else { throw CostUsageSessionDetailError.unavailable }
        guard maximumBytes >= 0, sqlite3_column_int64(preflight, 0) <= Int64(maximumBytes) else {
            throw CostUsageSessionDetailError.limitExceeded
        }
        // Bound the serialized envelope before copying it. Decode only the selected turn keys,
        // never the historical cursor, inventory, previous report, or full resolved-turn dictionary.
        let statement = try CostUsageStore.prepare(database, "SELECT payload FROM scan_metadata WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let payload = CostUsageStore.columnData(statement, at: 0)
        else { throw CostUsageSessionDetailError.unavailable }
        let decoder = JSONDecoder()
        guard let pricing = try decoder.decode(PricingPayload.self, from: payload).priorityTurnStatePayload
        else { return [:] }
        decoder.userInfo[SelectedPriorityEvidence.selectionKey] = turnIDs
        return try decoder.decode(SelectedPriorityEvidence.self, from: pricing).turns
    }

    private static func validateFile(
        _ database: OpaquePointer,
        source: CostUsageSessionDetailSource,
        lastActivity: Date,
        limits: Limits) throws -> Int64
    {
        let statement = try CostUsageStore.prepare(database, """
        SELECT id, mtime_ms, length(scan_state), parsed_bytes FROM files WHERE path = ? AND session_id = ?
        """)
        defer { sqlite3_finalize(statement) }
        CostUsageStore.bind(source.sessionSource.fileURL.path, to: statement, at: 1)
        CostUsageStore.bind(source.sessionSource.sessionID, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CostUsageSessionDetailError.unavailable }
        let recorded = Double(sqlite3_column_int64(statement, 1)) / 1000
        // Catch-up advances stored rows without changing the rollout's modification time.
        guard abs(recorded - lastActivity.timeIntervalSince1970) < 0.001,
              CostUsageStore.columnInt64(statement, at: 3) == source.parsedBytes
        else {
            throw CostUsageSessionDetailError.sourceChanged
        }
        guard sqlite3_column_int64(statement, 2) <= Int64(limits.metadataBytes) else {
            throw CostUsageSessionDetailError.limitExceeded
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func validateBudget(
        _ database: OpaquePointer,
        sql: String,
        fileID: Int64,
        rows: Int,
        bytes: Int) throws
    {
        guard rows >= 0, rows < Int.max, bytes >= 0 else { throw CostUsageSessionDetailError.limitExceeded }
        let statement = try CostUsageStore.prepare(database, "SELECT count(*), coalesce(sum(bytes), 0) FROM (\(sql))")
        defer { sqlite3_finalize(statement) }
        CostUsageStore.bind(fileID, to: statement, at: 1)
        CostUsageStore.bind(Int64(rows + 1), to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CostUsageSessionDetailError.unavailable }
        guard sqlite3_column_int64(statement, 0) <= Int64(rows),
              sqlite3_column_int64(statement, 1) <= Int64(bytes)
        else { throw CostUsageSessionDetailError.limitExceeded }
    }
}

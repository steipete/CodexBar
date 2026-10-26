import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Imports usage metadata into the existing cost store. Source reads never write to OpenCode.
enum OpenCodeLocalHistoryAdapter {
    static let maximumRowBytes = 64 * 1024
    static let maximumPassBytes = 256 * 1024
    static let maximumMetadataBytes = 8192

    enum Namespace: String, Codable, Sendable {
        case message
        case part
        case session_message
    }

    static func rowIdentity(
        namespace: Namespace,
        sourceID: String) -> Int64
    {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (namespace.rawValue + ":" + sourceID).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    struct Turn: Codable, Equatable, Sendable {
        var namespace: String
        var sourceID: String
        var createdMs: Int64
        var costUSD: Double
        var modelID: String
        var totalTokens: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var day: String?

        var identity: Int64 {
            OpenCodeLocalHistoryAdapter.rowIdentity(
                namespace: Namespace(rawValue: self.namespace) ?? .message,
                sourceID: self.sourceID)
        }

        var aggregate: CostUsageStoreDayAggregate {
            var legacyCalendar = Calendar(identifier: .gregorian)
            legacyCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var value = CostUsageStoreDayAggregate.zero(
                day: self.day ?? OpenCodeLocalHistoryAdapter.dayKey(
                    fromUnixMs: self.createdMs,
                    calendar: legacyCalendar),
                model: self.modelID)
            value.inputTokens = Int64(self.inputTokens ?? 0)
            value.cachedTokens = Int64(self.cacheReadTokens ?? 0) + Int64(self.cacheCreationTokens ?? 0)
            value.outputTokens = Int64(self.outputTokens ?? 0)
            value.reasoningTokens = Int64(self.reasoningTokens ?? 0)
            value.requestCount = 1
            value.authoritativeCostNanos = Int64((self.costUSD * 1e9).rounded())
            value.standardInputTokens = value.inputTokens
            value.standardCachedTokens = value.cachedTokens
            value.standardOutputTokens = value.outputTokens
            // Draft v1 rows predate reporting-calendar buckets and stored component totals.
            value.standardTokens = self.day == nil
                ? value.inputTokens + value.cachedTokens + value.outputTokens : Int64(self.totalTokens ?? 0)
            return value
        }
    }

    struct Payload: Codable, Equatable, Sendable {
        var providerID: String?
        var role: String?
        var type: String?
        var modelID: String?
        var cost: Double?
        var created: Int64?
        var tokens: TokenCounts?

        private enum CodingKeys: String, CodingKey {
            case providerID, role, type, modelID, cost, created, tokens
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.providerID = try? values.decode(
                String.self,
                forKey: .providerID)
            self.role = try? values.decode(
                String.self,
                forKey: .role)
            self.type = try? values.decode(
                String.self,
                forKey: .type)
            self.modelID = try? values.decode(
                String.self,
                forKey: .modelID)
            self.cost = try? values.decode(
                Double.self,
                forKey: .cost)
            self.created = try? values.decode(
                Int64.self,
                forKey: .created)
            let tokens = try? values.decode(
                TokenCounts.self,
                forKey: .tokens)
            self.tokens = tokens?.isValid == true ? tokens : nil
        }

        /// Provider-specific by design: this source imports only OpenAI-backed assistant usage.
        var isAssistant: Bool {
            self.providerID == "openai" && self.role == "assistant"
        }
    }

    struct TokenCounts: Codable, Equatable, Sendable {
        struct Cache: Codable, Equatable, Sendable { var read: Int?; var write: Int? }
        var total: Int?
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cache: Cache?

        var isValid: Bool {
            var total = 0
            for value in [self.total, self.input, self.output, self.reasoning, self.cache?.read, self.cache?.write] {
                guard let value else { continue }
                let addition = total.addingReportingOverflow(value)
                guard value >= 0, !addition.overflow else { return false }
                total = addition.partialValue
            }
            return true
        }

        var computedTotal: Int? {
            if let total { return total }
            let values = [self.input, self.output, self.reasoning, self.cache?.read, self.cache?.write]
            guard self.isValid, values.allSatisfy({ $0 != nil }) else { return nil }
            return values.compactMap(\.self).reduce(0, +)
        }
    }

    struct Message: Codable, Equatable, Sendable {
        var id: String
        var rowID: Int64
        var updatedMs: Int64
        var createdMs: Int64
        var payload: Payload?
        var parentID: String?
        var oversized = false
    }

    static func dayKey(
        fromUnixMs ms: Int64,
        calendar: Calendar = .current) -> String
    {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func registeredPath(for url: URL) -> String { url.resolvingSymlinksInPath().path }

    static func fingerprint(for url: URL) -> OpenCodeSourceCheckpoint.Fingerprint? {
        let path = self.registeredPath(for: url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let wal = try? FileManager.default.attributesOfItem(atPath: path + "-wal")
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let birth = (attributes[.creationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1e9) } ?? 0
        return .init(
            path: path,
            size: size,
            modifiedUnixMs: Int64(modified.timeIntervalSince1970 * 1000),
            walSize: (wal?[.size] as? NSNumber)?.int64Value,
            walModifiedUnixMs: (wal?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) },
            identity: "\(device):\(inode):\(birth)",
            modifiedUnixNs: Int64(modified.timeIntervalSince1970 * 1e9),
            walModifiedUnixNs: (wal?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1e9) })
    }

    enum SkipReason: Equatable, Sendable { case unreadable, unchanged, movedUnderRead, staleBaseline }
    enum PassOutcome: Equatable, Sendable { case applied(PassSummary), skipped(SkipReason) }
    struct PassSummary: Equatable, Sendable {
        var rawRowsRead: Int
        var complete: Bool
        var payloadBytes: Int
        var sqliteSteps: Int
        var sqliteCacheMisses: Int
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension OpenCodeLocalHistoryAdapter {
    static func runPass(
        databaseURL: URL,
        store: CostUsageStore,
        rowBudget: Int = 256,
        calendar: Calendar = .current,
        sinceDay: String? = nil,
        untilDay: String? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) async throws -> PassOutcome?
    {
        let path = self.registeredPath(for: databaseURL)
        guard let before = self.fingerprint(for: databaseURL) else { return .skipped(.unreadable) }
        let stored = await store.withDatabase(default: CostUsageStoreFile?.none) { database in
            try CostUsageStore.readFile(
                database,
                path: path)
        }
        let baseline = OpenCodeSourceCheckpoint.decode(stored?.scanState.resumePayload)
        let replaced = baseline?.fingerprint.identity != before.identity
            || (baseline.map { before.size < $0.fingerprint.size } ?? false)
        let changedCalendar = baseline?.timeZoneIdentifier != calendar.timeZone.identifier
        let changedWindow = changedCalendar || baseline?.sinceDay != sinceDay || baseline?.untilDay != untilDay
        if let baseline, !replaced, !changedWindow, !baseline.hasPendingWork, baseline.fingerprint == before,
           stored?.scanState.isComplete == baseline.isComplete
        {
            return .skipped(.unchanged)
        }
        var checkpoint: OpenCodeSourceCheckpoint
        if let baseline, !replaced, !changedWindow, baseline.hasPendingWork {
            checkpoint = baseline
        } else {
            checkpoint = .fresh(
                sourcePath: path,
                fingerprint: before,
                calendar: calendar)
            checkpoint.sinceDay = sinceDay
            checkpoint.untilDay = untilDay
        }
        checkpoint.rebuilding = checkpoint
            .rebuilding || (stored != nil && (replaced || changedCalendar || baseline == nil))
        let source = try Source(
            databaseURL: databaseURL,
            rowBudget: rowBudget,
            checkCancellation: checkCancellation)
        defer { source.close() }
        var pass = Pass(
            source: source,
            checkpoint: checkpoint,
            calendar: calendar)
        try pass.advanceSource()
        try await pass.reconcile(
            store: store,
            path: path)
        checkpoint = pass.checkpoint
        try source.budget.check()
        var cacheMisses: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(source.database, SQLITE_DBSTATUS_CACHE_MISS, &cacheMisses, &highwater, 0)
        source.close()
        guard before == Self.fingerprint(for: databaseURL) else { return .skipped(.movedUnderRead) }
        // A changing source is reconciled again after this bounded sweep; no completed
        // checkpoint can conceal a mutation to a row already visited in this cycle.
        if checkpoint.phase == .done, checkpoint.fingerprint != before {
            checkpoint = .fresh(
                sourcePath: path,
                fingerprint: before,
                calendar: calendar)
            checkpoint.sinceDay = sinceDay
            checkpoint.untilDay = untilDay
            checkpoint.rebuilding = pass.checkpoint.rebuilding
        }
        if checkpoint.phase == .done { checkpoint.rebuilding = false }
        var state = CostUsageStoreScanState(isComplete: checkpoint.isComplete)
        state.source = .opencodeLocalHistory
        state.resumePayload = try JSONEncoder().encode(checkpoint)
        let file = CostUsageStoreFile(
            path: path,
            inode: nil,
            mtimeUnixMs: before.modifiedUnixMs,
            size: before.size,
            parsedBytes: nil,
            anchor: nil,
            scanState: state,
            sessionID: nil,
            coverageSinceDay: sinceDay,
            coverageUntilDay: untilDay,
            updatedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000))
        let accepted = await store.applyOpenCodeLocalHistoryPass(
            file: file,
            expectedBaselineResumePayload: stored?.scanState.resumePayload,
            turns: pass.changes,
            deletions: pass.deletions)
        try Task.checkCancellation()
        guard accepted else { return .skipped(.staleBaseline) }
        return .applied(.init(
            rawRowsRead: source.budget.rowsRead,
            complete: checkpoint.isComplete,
            payloadBytes: source.budget.bytesRead,
            sqliteSteps: source.budget.steps,
            sqliteCacheMisses: Int(cacheMisses)))
    }

    private struct Pass {
        let source: Source
        var checkpoint: OpenCodeSourceCheckpoint
        let calendar: Calendar
        var changes: [Int64: Turn] = [:]
        var deletions = Set<Int64>()
        var evaluated: [String: Bool] = [:]
        var validParents: [String: Bool] = [:]

        mutating func remove(
            _ namespace: Namespace,
            _ id: String)
        {
            let identity = OpenCodeLocalHistoryAdapter.rowIdentity(
                namespace: namespace,
                sourceID: id)
            self.changes.removeValue(forKey: identity)
            self.deletions.insert(identity)
        }

        func contains(day: String) -> Bool {
            (self.checkpoint.sinceDay == nil || day >= self.checkpoint.sinceDay!)
                && (self.checkpoint.untilDay == nil || day <= self.checkpoint.untilDay!)
        }

        mutating func record(_ turn: Turn) {
            guard self.contains(day: turn.aggregate.day) else {
                self.remove(Namespace(rawValue: turn.namespace)!, turn.sourceID)
                return
            }
            self.checkpoint.hasUnknownTokens = self.checkpoint.hasUnknownTokens
                || [
                    turn.totalTokens,
                    turn.inputTokens,
                    turn.outputTokens,
                    turn.reasoningTokens,
                    turn.cacheReadTokens,
                    turn.cacheCreationTokens,
                ].contains(nil)
            guard let payload = try? JSONEncoder().encode(turn),
                  payload.count <= OpenCodeLocalHistoryAdapter.maximumMetadataBytes
            else {
                self.checkpoint.skippedOversizedRow = true
                self.remove(Namespace(rawValue: turn.namespace)!, turn.sourceID)
                return
            }
            self.changes[turn.identity] = turn
            self.deletions.remove(turn.identity)
        }

        mutating func finish(_ pending: OpenCodeSourceCheckpoint.PartContinuation) {
            let id = pending.message.id
            let fallback = OpenCodeLocalHistoryAdapter.turn(
                from: pending.message,
                namespace: .message,
                calendar: self.calendar)
            self.evaluated[id] = pending.hasValidParts || fallback != nil
            if pending.hasValidParts {
                self.remove(.message, id)
                self.remove(.session_message, id)
            } else if let fallback {
                self.record(fallback)
                self.remove(.session_message, id)
            } else {
                self.remove(.message, id)
                if let fallback = pending.sessionFallback { self.record(fallback) }
            }
            self.checkpoint.pendingPartContinuation = nil
        }

        mutating func advancePending(_ pending: inout OpenCodeSourceCheckpoint.PartContinuation) throws {
            if pending.needsLegacyLookup {
                let legacy = try self.source.row(
                    table: .message,
                    id: pending.message.id)
                self.validParents[pending.message.id] = legacy?.payload?.isAssistant == true
                pending.needsLegacyLookup = false
                if let legacy, legacy.payload?.isAssistant == true {
                    pending.message = legacy
                    self.checkpoint.pendingPartContinuation = pending
                } else {
                    if let fallback = pending.sessionFallback { self.record(fallback) }
                    self.checkpoint.pendingPartContinuation = nil
                }
                return
            }
            if self.validParents[pending.message.id] == nil, !pending.resumeValidated {
                let latest = try self.source.row(table: .message, id: pending.message.id)
                self.validParents[pending.message.id] = latest?.payload?.isAssistant == true
                guard let latest, latest.payload?.isAssistant == true else {
                    self.remove(.message, pending.message.id)
                    self.checkpoint.pendingPartContinuation = nil
                    return
                }
                // A one-row pass can spend its budget on validation. Keep that receipt
                // until a part advances, even if another source write arrives meanwhile.
                pending.message = latest
                pending.resumeValidated = true
                self.checkpoint.pendingPartContinuation = pending
                return
            }
            self.validParents[pending.message.id] = true
            pending.resumeValidated = false
            guard let part = try self.source.row(
                table: .part,
                position: pending.position.rowID,
                parentID: pending.message.id)
            else { self.finish(pending); return }
            pending.position = .init(
                timestamp: part.updatedMs,
                rowID: part.rowID)
            self.checkpoint.skippedOversizedRow = self.checkpoint.skippedOversizedRow || part.oversized
            if part.parentID == pending.message.id {
                if part.payload?.type == "step-finish",
                   let turn = OpenCodeLocalHistoryAdapter.turn(
                       from: part,
                       namespace: .part,
                       model: pending.message.payload?.modelID,
                       calendar: self.calendar)
                {
                    pending.hasValidParts = true
                    self.record(turn)
                    self.remove(.message, pending.message.id)
                    self.remove(.session_message, pending.message.id)
                } else {
                    self.remove(.part, part.id)
                }
            }
            self.checkpoint.pendingPartContinuation = pending
        }

        mutating func advanceSource() throws {
            while self.source.budget.canRead, self.checkpoint.phase != .reconciliation, self.checkpoint.phase != .done {
                if var pending = self.checkpoint.pendingPartContinuation {
                    try self.advancePending(&pending)
                    continue
                }
                let table: Namespace = self.checkpoint.phase == .message ? .message : .session_message
                guard let row = try self.source.row(
                    table: table,
                    position: self.checkpoint.position.rowID)
                else {
                    self.checkpoint.phase = table == .message ? .session_message : .reconciliation
                    self.checkpoint.position = .init(
                        timestamp: 0,
                        rowID: table == .message ? Int64.max : -1)
                    continue
                }
                self.checkpoint.position = .init(
                    timestamp: row.updatedMs,
                    rowID: row.rowID)
                self.checkpoint.skippedOversizedRow = self.checkpoint.skippedOversizedRow || row.oversized
                if table == .message {
                    self.validParents[row.id] = row.payload?.isAssistant == true
                    self.evaluated[row.id] = false
                }
                guard row.payload?.isAssistant == true else { self.remove(table, row.id); continue }
                if table == .message {
                    self.checkpoint.pendingPartContinuation = .init(
                        message: row)
                } else {
                    guard let fallback = OpenCodeLocalHistoryAdapter.turn(
                        from: row,
                        namespace: table,
                        calendar: self.calendar)
                    else { self.remove(table, row.id); continue }
                    if let usable = self.evaluated[row.id] {
                        if usable { self.remove(table, row.id) } else { self.record(fallback) }
                    } else {
                        self.checkpoint.pendingPartContinuation = .init(
                            message: row,
                            sessionFallback: fallback,
                            needsLegacyLookup: true)
                    }
                }
            }
        }

        mutating func reconcile(
            store: CostUsageStore,
            path: String) async throws
        {
            guard self.checkpoint.phase == .reconciliation else { return }
            if self.source.budget.canRead, let pending = self.checkpoint.pendingParentCheck {
                if try !self.validParent(pending.parentID) {
                    self.deletions.insert(pending.rowIndex)
                }
                self.checkpoint.position.rowID = pending.rowIndex
                self.checkpoint.pendingParentCheck = nil
            }
            guard self.source.budget.canRead else { return }
            let after = self.checkpoint.position.rowID
            let limit = min(
                self.source.budget.remainingRows,
                OpenCodeLocalHistoryAdapter.maximumPassBytes / OpenCodeLocalHistoryAdapter.maximumMetadataBytes)
            let rows = await store.withDatabase(default: [CostUsageStoreUsageRow]()) { database in
                try CostUsageStore.readUsageRowsPage(
                    database,
                    path: path,
                    after: after,
                    limit: limit)
            }
            var visited = 0
            for row in rows {
                guard self.source.budget.canRead else { break }
                let identity = Int64(row.rowIndex)
                if self.changes[identity] == nil, !self.deletions.contains(identity) {
                    guard try self.reconcile(row) else { break }
                }
                self.checkpoint.position.rowID = identity
                visited += 1
            }
            if visited == rows.count, rows.count < limit { self.checkpoint.phase = .done }
        }

        mutating func validParent(_ id: String) throws -> Bool {
            if let valid = self.validParents[id] { return valid }
            let valid = try self.source.row(
                table: .message,
                id: id)?.payload?.isAssistant == true
            self.validParents[id] = valid
            return valid
        }

        mutating func reconcile(_ row: CostUsageStoreUsageRow) throws -> Bool {
            let identity = Int64(row.rowIndex)
            guard let turn = try? JSONDecoder().decode(
                Turn.self,
                from: row.payload),
                let namespace = Namespace(rawValue: turn.namespace)
            else {
                self.deletions.insert(identity)
                return true
            }
            let live = try self.source.row(
                table: namespace,
                id: turn.sourceID)
            var valid = live?.oversized == false && self.contains(day: turn.aggregate.day)
            if namespace == .part, let live, valid {
                guard self.validParents[live.parentID ?? ""] != nil || self.source.budget.canRead else {
                    self.checkpoint.pendingParentCheck = .init(
                        rowIndex: identity,
                        parentID: live.parentID ?? "")
                    return false
                }
                valid = try self.validParent(live.parentID ?? "")
            }
            if !valid { self.deletions.insert(identity) }
            return true
        }
    }

    private static func turn(
        from row: Message,
        namespace: Namespace,
        model: String? = nil,
        calendar: Calendar) -> Turn?
    {
        guard let payload = row.payload, let cost = payload.cost, cost.isFinite,
              cost >= 0, cost < Double(Int64.max) / 1e9 - 1,
              payload.tokens?.isValid != false,
              row.id.utf8.count <= 512,
              (model ?? payload.modelID ?? "unknown").utf8.count <= 1024
        else { return nil }
        let created = payload.created ?? row.createdMs
        guard created > 0 else { return nil }
        return Turn(
            namespace: namespace.rawValue,
            sourceID: row.id,
            createdMs: created,
            costUSD: cost,
            modelID: model ?? payload.modelID ?? "unknown",
            totalTokens: payload.tokens?.computedTotal,
            inputTokens: payload.tokens?.input,
            outputTokens: payload.tokens?.output,
            reasoningTokens: payload.tokens?.reasoning,
            cacheReadTokens: payload.tokens?.cache?.read,
            cacheCreationTokens: payload.tokens?.cache?.write,
            day: Self.dayKey(
                fromUnixMs: created,
                calendar: calendar))
    }
}
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
extension OpenCodeLocalHistoryAdapter {
    final class ReadBudget {
        enum Limit: Error { case deadline, instructions }
        var remainingRows: Int
        var remainingBytes = OpenCodeLocalHistoryAdapter.maximumPassBytes
        var rowsRead = 0
        var bytesRead = 0
        var steps = 0
        var currentStatementSteps = 0
        var failure: Error?
        let maximumSteps: Int
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        let cancellation: CostUsageScanner.CancellationCheck?

        init(
            rows: Int,
            cancellation: CostUsageScanner.CancellationCheck?)
        {
            self.remainingRows = min(max(rows, 1), 1024)
            self.maximumSteps = 20000 + self.remainingRows * 1000
            self.cancellation = cancellation
        }

        var canRead: Bool {
            self.remainingRows > 0 && self.remainingBytes >= OpenCodeLocalHistoryAdapter.maximumRowBytes
                + OpenCodeLocalHistoryAdapter.maximumMetadataBytes + 1 + 1026
        }

        func check() throws {
            if let failure { throw failure }
            try Task.checkCancellation()
            try self.cancellation?()
            guard ContinuousClock.now < self.deadline else { throw Limit.deadline }
            guard self.steps + self.currentStatementSteps < self.maximumSteps else { throw Limit.instructions }
        }

        func consume(bytes: Int) {
            self.rowsRead += 1
            self.remainingRows -= 1
            self.bytesRead += bytes
            self.remainingBytes -= bytes
        }
    }

    final class Source {
        var database: OpaquePointer?
        let budget: ReadBudget
        private var tables = Set<Namespace>()
        private var partIndex: String?

        init(
            databaseURL: URL,
            rowBudget: Int,
            checkCancellation: CostUsageScanner.CancellationCheck?) throws
        {
            self.budget = ReadBudget(
                rows: rowBudget,
                cancellation: checkCancellation)
            let code = sqlite3_open_v2(databaseURL.path, &self.database, SQLITE_OPEN_READONLY, nil)
            guard code == SQLITE_OK, let database else {
                if let database = self.database { sqlite3_close(database) }
                self.database = nil
                throw OpenCodeAdapterSourceFailure(code: code)
            }
            do {
                sqlite3_busy_timeout(database, 50)
                sqlite3_progress_handler(
                    database,
                    100,
                    { context in
                        guard let context else { return 1 }
                        let budget = Unmanaged<ReadBudget>.fromOpaque(context).takeUnretainedValue()
                        budget.currentStatementSteps += 100
                        do { try budget.check(); return 0 } catch { budget.failure = error; return 1 }
                    },
                    Unmanaged.passUnretained(self.budget).toOpaque())
                try self.execute("BEGIN")
                for table in [Namespace.message, .part, .session_message]
                    where try self
                    .scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table.rawValue)'") != nil
                {
                    self.tables.insert(table)
                }
                if self.tables.contains(.part) {
                    // Only this index shape supplies rowid order without a sort or hidden filtering.
                    self.partIndex = try self.scalar("""
                    SELECT l.name FROM pragma_index_list('part') l JOIN pragma_index_xinfo(l.name) i
                    WHERE l.partial = 0 AND i.seqno = 0 AND i.name = 'message_id' AND i.coll = 'BINARY'
                      AND NOT EXISTS (
                        SELECT 1 FROM pragma_index_xinfo(l.name) rest WHERE rest.key = 1 AND rest.seqno > 0)
                    LIMIT 1
                    """)
                }
            } catch {
                self.close()
                throw error
            }
        }

        deinit { self.close() }

        func close() {
            guard let database else { return }
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
            self.database = nil
        }

        private func execute(_ sql: String) throws {
            let code = sqlite3_exec(self.database, sql, nil, nil, nil)
            guard code == SQLITE_OK else { throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code) }
        }

        private func finalize(_ statement: OpaquePointer) {
            self.budget.steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
            self.budget.currentStatementSteps = 0
            sqlite3_finalize(statement)
        }

        private func scalar(_ sql: String) throws -> String? {
            let statement = try self.prepare(sql)
            defer { self.finalize(statement) }
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else {
                throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code)
            }
            return code == SQLITE_ROW ? CostUsageStore.columnText(statement, at: 0) : nil
        }

        private func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            let code = sqlite3_prepare_v2(self.database, sql, -1, &statement, nil)
            guard code == SQLITE_OK, let statement else {
                throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code)
            }
            return statement
        }

        /// Admit one raw row before eligibility filtering. The incremental-blob length
        /// check precedes every field read: columns after a large body can traverse its overflow pages.
        func row(
            table: Namespace,
            position: Int64 = 0,
            id: String? = nil,
            parentID: String? = nil) throws -> Message?
        {
            try self.budget.check()
            guard self.tables.contains(table) else { return nil }
            let ascending = table == .part
            var predicate = id == nil ? "rowid \(ascending ? ">" : "<") ?" : "id = ?"
            let indexedParent = parentID != nil && self.partIndex != nil
            if indexedParent { predicate += " AND message_id = ?" }
            let index = indexedParent ?
                " INDEXED BY \"\(self.partIndex!.replacingOccurrences(of: "\"", with: "\"\""))\"" : ""
            let statement = try self.prepare("""
            SELECT rowid
            FROM \(table.rawValue)\(index) WHERE \(predicate)
            ORDER BY rowid \(ascending ? "ASC" : "DESC") LIMIT 1
            """)
            defer { self.finalize(statement) }
            if let id { CostUsageStore.bind(
                id,
                to: statement,
                at: 1) } else { sqlite3_bind_int64(statement, 1, position) }
            if indexedParent { CostUsageStore.bind(
                parentID,
                to: statement,
                at: 2) }
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else {
                throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code)
            }
            let rowID = sqlite3_column_int64(statement, 0)
            let size = try self.payloadSize(table: table, rowID: rowID)
            guard size <= OpenCodeLocalHistoryAdapter.maximumRowBytes else {
                self.budget.consume(bytes: 0)
                return Message(
                    id: id ?? "",
                    rowID: rowID,
                    updatedMs: 0,
                    createdMs: 0,
                    payload: nil,
                    parentID: nil,
                    oversized: true)
            }
            return try self.decodeRow(table: table, rowID: rowID, bodyBytes: size)
        }

        private func payloadSize(
            table: Namespace,
            rowID: Int64) throws -> Int
        {
            var blob: OpaquePointer?
            let code = sqlite3_blob_open(self.database, "main", table.rawValue, "data", rowID, 0, &blob)
            guard code == SQLITE_OK, let blob else {
                // NULL and numeric bodies cannot contain usage JSON. They still consume a raw row.
                if code == SQLITE_ERROR { return 0 }
                throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code)
            }
            defer { sqlite3_blob_close(blob) }
            return Int(sqlite3_blob_bytes(blob))
        }

        private func decodeRow(
            table: Namespace,
            rowID: Int64,
            bodyBytes: Int) throws -> Message
        {
            let parent = table == .part ? "substr(CAST(message_id AS BLOB), 1, 513)" : "NULL"
            let role = table == .session_message ? "type" : "NULL"
            let providerPath = table == .session_message ? "$.model.providerID" : "$.providerID"
            let modelPath = table == .session_message ? "$.model.id" : "$.modelID"
            let statement = try self.prepare("""
            SELECT CASE WHEN json_valid(data) THEN substr(CAST(json_object(
              'providerID', json_extract(data, '\(providerPath)'),
              'modelID', json_extract(data, '\(modelPath)'),
              'role', COALESCE(\(role), json_extract(data, '$.role')),
              'type', json_extract(data, '$.type'),
              'cost', CASE WHEN json_type(data, '$.cost') IN ('integer', 'real')
                THEN json_extract(data, '$.cost') END,
              'created', CASE WHEN json_type(data, '$.time.created') = 'integer'
                THEN json_extract(data, '$.time.created') END,
              'tokens', json_extract(data, '$.tokens')) AS BLOB),
              1, \(OpenCodeLocalHistoryAdapter.maximumMetadataBytes + 1)) END,
              substr(CAST(id AS BLOB), 1, 513), \(parent), time_created, time_updated
            FROM \(table.rawValue) WHERE rowid = ?
            """)
            defer { self.finalize(statement) }
            sqlite3_bind_int64(statement, 1, rowID)
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                throw self.budget.failure ?? OpenCodeAdapterSourceFailure(code: code)
            }
            let metadata = CostUsageStore.columnData(statement, at: 0)
            let identifier = CostUsageStore.columnData(statement, at: 1) ?? Data()
            let parentData = CostUsageStore.columnData(statement, at: 2)
            let oversized = identifier.count > 512 || (parentData?.count ?? 0) > 512
                || (metadata?.count ?? 0) > OpenCodeLocalHistoryAdapter.maximumMetadataBytes
            self.budget.consume(bytes: bodyBytes + (metadata?.count ?? 0)
                + identifier.count + (parentData?.count ?? 0))
            let payload = oversized ? nil : metadata.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            return Message(
                id: identifier.count <= 512 ? String(data: identifier, encoding: .utf8) ?? "" : "",
                rowID: rowID,
                updatedMs: sqlite3_column_int64(statement, 4),
                createdMs: sqlite3_column_int64(statement, 3),
                payload: payload,
                parentID: parentData.flatMap { $0.count <= 512 ? String(data: $0, encoding: .utf8) : nil },
                oversized: oversized || (payload?.modelID?.utf8.count ?? 0) > 1024)
        }
    }
}

struct OpenCodeAdapterSourceFailure: Error { let code: Int32 }
#endif

extension OpenCodeLocalHistoryAdapter {
    static func xdgDataRoot(
        homeDirectory: URL,
        environment: [String: String]) -> URL
    {
        if let raw = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("/")
        {
            return URL(
                fileURLWithPath: raw,
                isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(
                ".local",
                isDirectory: true)
            .appendingPathComponent(
                "share",
                isDirectory: true)
    }

    /// Resolves the single database OpenCode itself would use, mirroring upstream
    /// `database.path()`: `OPENCODE_DB` selects exactly one database (`:memory:` is
    /// unreachable for an on-disk reader; absolute paths win as-is; relative names resolve
    /// inside the data directory) and is never substituted with another database. Without
    /// an explicit selection, the plain `opencode.db` is the contract's selection;
    /// non-release channel databases stay reachable through `OPENCODE_DB`, exactly like
    /// pointing OpenCode itself at them.
    static func resolvedDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        let dataDirectory = Self.xdgDataRoot(
            homeDirectory: homeDirectory,
            environment: environment)
            .appendingPathComponent(
                "opencode",
                isDirectory: true)
        if let override = environment["OPENCODE_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            if override == ":memory:" {
                return nil
            }
            if override.hasPrefix("/") {
                return URL(fileURLWithPath: override)
            }
            return dataDirectory.appendingPathComponent(
                override,
                isDirectory: false)
        }
        return dataDirectory.appendingPathComponent(
            "opencode.db",
            isDirectory: false)
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension OpenCodeLocalHistoryAdapter {
    static func reportEntries(
        from aggregates: [CostUsageStoreFileDayAggregate],
        tokensComplete: Bool = true) -> [CostUsageDailyReport.Entry]
    {
        let byDay = Dictionary(grouping: aggregates, by: \.aggregate.day)
        return byDay.keys.sorted().map { day in
            let rows = byDay[day, default: []].map(\.aggregate)
            func tokens(_ keyPath: KeyPath<CostUsageStoreDayAggregate, Int64>) -> Int? {
                tokensComplete ? CheckedSum.integers(rows.map { Int($0[keyPath: keyPath]) }) : nil
            }
            let breakdowns = rows.map { aggregate in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: aggregate.model,
                    costUSD: Double(aggregate.authoritativeCostNanos) / 1e9,
                    totalTokens: tokensComplete ? Int(aggregate.standardTokens) : nil,
                    requestCount: Int(aggregate.requestCount),
                    inputTokens: tokensComplete ? Int(aggregate.inputTokens) : nil,
                    outputTokens: tokensComplete ? Int(aggregate.outputTokens) : nil,
                    reasoningTokens: tokensComplete ? Int(aggregate.reasoningTokens) : nil,
                    sourceRecorded: true)
            }
            let requests = CheckedSum.integers(rows.map { Int($0.requestCount) })
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: tokens(\.inputTokens),
                outputTokens: tokens(\.outputTokens),
                cacheReadTokens: tokens(\.cachedTokens),
                cacheCreationTokens: tokensComplete ? 0 : nil,
                reasoningTokens: tokens(\.reasoningTokens),
                totalTokens: tokens(\.standardTokens),
                requestCount: requests,
                costUSD: rows.reduce(0) { $0 + Double($1.authoritativeCostNanos) / 1e9 },
                modelsUsed: breakdowns.map(\.modelName).sorted(),
                modelBreakdowns: CostUsageDailyReport.sortedModelBreakdowns(breakdowns),
                pricedRequestCount: requests)
        }
    }
}

#endif

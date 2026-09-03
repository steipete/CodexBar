import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Hermes Local Reader

// swiftlint:disable:next type_body_length
public enum HermesLocalReader {
    public enum LocalStoreStatus: Sendable, Equatable {
        case present
        case absent
        case unavailable
    }

    public enum Coverage: Sendable, Equatable {
        case complete
        case partial
        case unavailable
    }

    public struct DailyReportResult: Sendable {
        public let report: CostUsageDailyReport
        public let coverage: Coverage
        public let statistics: Statistics

        public var isComplete: Bool {
            self.coverage == .complete
        }

        public var isAvailable: Bool {
            self.coverage == .complete || self.coverage == .partial
        }
    }

    /// Hermes stores both vendor-reported and list-price costs. Keep that distinction when
    /// converting the local rows to CodexBar's snapshot model instead of inferring it from a
    /// non-nil amount (a known zero is still a real cost result).
    public static func costProvenance(for entries: [CostUsageDailyReport.Entry]) -> CostProvenance {
        var hasActual = false
        var hasEstimate = false
        for entry in entries {
            // A zero request count is still authoritative when the producer persisted a cost
            // status. The count remains zero for coverage; the optional category field carries
            // the independent provenance signal.
            hasActual = hasActual || entry.pricedRequestCount != nil
            hasEstimate = hasEstimate || entry.estimatedRequestCount != nil
        }
        switch (hasActual, hasEstimate) {
        case (true, true): return .mixed
        case (true, false): return .vendorMetered
        case (false, true): return .listPriceEstimate
        case (false, false): return .unknown
        }
    }

    public struct Context: Sendable {
        public let home: URL
        public let environment: [String: String]

        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.environment = environment
            if let raw = environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty
            {
                let expanded = (raw as NSString).expandingTildeInPath
                self.home = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            } else if let envHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !envHome.isEmpty
            {
                let expanded = (envHome as NSString).expandingTildeInPath
                self.home = URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent(".hermes", isDirectory: true)
                    .standardizedFileURL
            } else {
                self.home = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".hermes", isDirectory: true)
                    .standardizedFileURL
            }
        }

        public init(home: URL, environment: [String: String] = [:]) {
            self.home = home.standardizedFileURL
            self.environment = environment
        }

        public var databaseRoots: [URL] {
            guard self.home.deletingLastPathComponent().lastPathComponent != "profiles" else {
                // An explicit HERMES_HOME may point at one named profile. Keep that choice
                // isolated instead of silently widening it to sibling/default profiles.
                return [self.home]
            }
            return [
                self.home,
                self.home.appendingPathComponent("profiles", isDirectory: true),
            ]
        }
    }

    public struct Limits: Sendable {
        public var databases: Int = 50
        public var rowsPerDatabase: Int = 50000
        public var rows: Int = 100_000
        public var databaseBytes: Int = 64 * 1024 * 1024
        public var bytes: Int = 128 * 1024 * 1024
        public var duration: TimeInterval = 5

        public init() {}
    }

    public struct Statistics: Sendable, Equatable {
        public var files: Int = 0
        public var rows: Int = 0
        public var attemptedBytes: Int = 0
        public var sqliteHandlesOpened: Int = 0
        public var sqliteHandlesClosed: Int = 0

        public init() {}
    }

    public enum ScanFailure: Error {
        case exhausted
        case invalid
    }

    public final class Budget: @unchecked Sendable {
        public let limits: Limits
        public let cancellation: () throws -> Void
        public let clock: () -> TimeInterval
        public let started: TimeInterval
        public var statistics: Statistics
        private var rowsInCurrentDatabase: Int = 0

        public init(
            limits: Limits = Limits(),
            clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            cancellation: @escaping () throws -> Void = {})
        {
            self.limits = limits
            self.clock = clock
            self.started = clock()
            self.cancellation = cancellation
            self.statistics = Statistics()
        }

        public func check() throws {
            try self.cancellation()
            guard self.clock() - self.started < self.limits.duration else {
                throw ScanFailure.exhausted
            }
        }

        public func chargeBytes(_ count: Int) throws {
            try self.check()
            let (attempted, overflow) = self.statistics.attemptedBytes.addingReportingOverflow(max(0, count))
            self.statistics.attemptedBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.bytes else {
                throw ScanFailure.exhausted
            }
        }

        public func beginDatabase() {
            self.rowsInCurrentDatabase = 0
        }

        public func chargeRow() throws {
            try self.check()
            let (databaseRows, databaseOverflow) = self.rowsInCurrentDatabase.addingReportingOverflow(1)
            let (rows, rowsOverflow) = self.statistics.rows.addingReportingOverflow(1)
            guard !databaseOverflow, !rowsOverflow else {
                throw ScanFailure.exhausted
            }
            self.rowsInCurrentDatabase = databaseRows
            self.statistics.rows = rows
            guard databaseRows <= self.limits.rowsPerDatabase, rows <= self.limits.rows else {
                throw ScanFailure.exhausted
            }
        }
    }

    public static func hermesHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        Context(environment: environment).home
    }

    // MARK: - Safe Integer Helpers

    public static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    public static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    public static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard let next = self.checkedAdd(total, value) else { return nil }
            total = next
        }
        return total
    }

    public static func checkedSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard let next = self.checkedAdd(total, value) else { return nil }
            total = next
        }
        return total
    }

    // MARK: - Row Models

    private struct SMURow {
        let sessionID: String
        let model: String
        let billingProvider: String?
        let billingBaseURL: String?
        let billingMode: String?
        let task: String?
        let apiCallCount: Int64?
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let cacheWriteTokens: Int64
        let reasoningTokens: Int64
        let estimatedCostUSD: Double?
        let actualCostUSD: Double?
        let costStatus: String?
        let costSource: String?
        let firstSeen: Double?
        let lastSeen: Double?
    }

    private struct SessionRow {
        let id: String
        let model: String?
        let billingProvider: String?
        let startedAt: Double
        let lastActivityAt: Double?
        let apiCallCount: Int64?
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let cacheWriteTokens: Int64
        let reasoningTokens: Int64
        let estimatedCostUSD: Double?
        let actualCostUSD: Double?
        let costStatus: String?
        let costSource: String?
    }

    private struct UsageItem {
        let sessionID: String
        let sourceDatabase: String
        let model: String
        let billingProvider: String?
        let task: String?
        let timestamp: Double?
        let apiCalls: Int64?
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let reasoning: Int64
        let totalTokens: Int64
        let costUSD: Double?
        let costKind: CostKind
        let dedupKey: String
        /// Full cumulative session counters used when reconciling a residual against a newer
        /// profile. These are nil for model rows and keep residual coverage comparisons from
        /// mistaking the residual remainder for the whole session.
        let sessionTotalTokens: Int64?
        let sessionTotalApiCalls: Int64?
    }

    private enum CostKind: Sendable, Equatable {
        case actual
        case estimated
        case included
        case unknown
        case mixed
    }

    private struct CostValue: Sendable, Equatable {
        let amount: Double?
        let kind: CostKind
    }

    private struct DatabaseScanResult {
        var items: [UsageItem] = []
        var isComplete: Bool = true
    }

    private struct DatabaseDiscoveryResult {
        let paths: [URL]
        let isComplete: Bool
    }

    // MARK: - Discovery

    public static func discoverDatabasePaths(context: Context, budget: Budget) throws -> [URL] {
        try self.discoverDatabasePathsWithStatus(context: context, budget: budget).paths
    }

    /// Lightweight provider availability check. This only discovers selected `state.db`
    /// paths; the token-cost pipeline owns opening and scanning them once per refresh.
    public static func hasLocalStore(context: Context) -> Bool {
        let budget = Budget()
        return ((try? self.discoverDatabasePaths(context: context, budget: budget)) ?? []).isEmpty == false
    }

    /// Distinguish a confirmed empty Hermes home from a store that could not be inspected.
    /// Callers use this to avoid clearing an already-established snapshot after a transient
    /// profile-directory or filesystem failure.
    public static func localStoreStatus(context: Context) -> LocalStoreStatus {
        let budget = Budget()
        guard let discovery = try? self.discoverDatabasePathsWithStatus(context: context, budget: budget) else {
            return .unavailable
        }
        guard discovery.isComplete else { return .unavailable }
        return discovery.paths.isEmpty ? .absent : .present
    }

    private static func discoverDatabasePathsWithStatus(
        context: Context,
        budget: Budget) throws -> DatabaseDiscoveryResult
    {
        try budget.check()
        var paths: [URL] = []
        var isComplete = true
        let fileManager = FileManager.default
        let defaultDB = context.home.appendingPathComponent("state.db", isDirectory: false)
        if fileManager.fileExists(atPath: defaultDB.path) {
            paths.append(defaultDB)
        }
        guard context.databaseRoots.count > 1 else {
            return DatabaseDiscoveryResult(paths: paths, isComplete: isComplete)
        }
        let profilesDir = context.home.appendingPathComponent("profiles", isDirectory: true)
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: profilesDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            for entry in contents.sorted(by: { $0.path < $1.path }) {
                try budget.check()
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let profileDB = entry.appendingPathComponent("state.db", isDirectory: false)
                if fileManager.fileExists(atPath: profileDB.path) {
                    paths.append(profileDB)
                }
            }
        } catch CocoaError.fileReadNoSuchFile {
            // A profile directory is optional; its absence is a complete scan.
        } catch {
            // Keep a readable default database useful, but do not report complete history when
            // profile discovery itself was denied or failed.
            isComplete = false
        }
        return DatabaseDiscoveryResult(paths: paths, isComplete: isComplete)
    }

    // MARK: - Main Report Generation

    public static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        var allItems: [UsageItem] = []
        var isComplete = true
        do {
            let discovery = try self.discoverDatabasePathsWithStatus(context: context, budget: budget)
            let databases = discovery.paths
            isComplete = discovery.isComplete
            guard !databases.isEmpty else {
                return DailyReportResult(
                    report: CostUsageDailyReport(data: [], summary: nil),
                    coverage: isComplete ? .unavailable : .partial,
                    statistics: budget.statistics)
            }
            for dbURL in databases {
                try budget.check()
                budget.statistics.files += 1
                guard budget.statistics.files <= budget.limits.databases else {
                    throw ScanFailure.exhausted
                }
                let scanResult = try self.scanDatabase(dbURL, budget: budget)
                allItems.append(contentsOf: scanResult.items)
                if !scanResult.isComplete {
                    isComplete = false
                }
            }
            return try self.aggregate(
                items: allItems,
                calendar: calendar,
                isComplete: isComplete,
                budget: budget,
                checkBudget: true)
        } catch ScanFailure.exhausted {
            if let partial = try? self.aggregate(
                items: allItems,
                calendar: calendar,
                isComplete: false,
                budget: budget,
                checkBudget: false)
            {
                return partial
            }
            return DailyReportResult(
                report: CostUsageDailyReport(data: [], summary: nil),
                coverage: .partial,
                statistics: budget.statistics)
        } catch is CancellationError {
            if let partial = try? self.aggregate(
                items: allItems,
                calendar: calendar,
                isComplete: false,
                budget: budget,
                checkBudget: false)
            {
                return partial
            }
            return DailyReportResult(
                report: CostUsageDailyReport(data: [], summary: nil),
                coverage: .partial,
                statistics: budget.statistics)
        }
    }

    public static func makeDailyReport(
        calendar: Calendar = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageDailyReport
    {
        let result = try? self.makeDailyReportWithStatus(
            context: Context(environment: environment),
            calendar: calendar)
        return result?.report ?? CostUsageDailyReport(data: [], summary: nil)
    }

    // MARK: - SQLite Scanning

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func databaseFootprint(_ url: URL) -> Int? {
        let fileManager = FileManager.default
        let related = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
        var total = 0
        for file in related where fileManager.fileExists(atPath: file.path) {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size >= 0
            else { return nil }
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func hasRequiredColumns(
        table: String,
        columns: Set<String>,
        in database: OpaquePointer) -> Bool
    {
        let escapedTable = table.replacingOccurrences(of: "\"", with: "\"\"")
        let sql = "PRAGMA table_info(\"\(escapedTable)\")"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        var found: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let ptr = sqlite3_column_text(statement, 1) {
                found.insert(String(cString: ptr))
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE && columns.isSubset(of: found)
    }
    #endif

    // swiftlint:disable function_body_length
    // swiftlint:disable:next cyclomatic_complexity
    private static func scanDatabase(_ url: URL, budget: Budget) throws -> DatabaseScanResult {
        #if canImport(SQLite3) || canImport(CSQLite3)
        budget.beginDatabase()
        guard let bytes = self.databaseFootprint(url) else {
            return DatabaseScanResult(items: [], isComplete: false)
        }
        guard bytes <= budget.limits.databaseBytes else {
            return DatabaseScanResult(items: [], isComplete: false)
        }
        try budget.chargeBytes(bytes)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let opened = sqlite3_open_v2(url.path, &database, flags, nil)
        if database != nil {
            budget.statistics.sqliteHandlesOpened += 1
        }
        guard opened == SQLITE_OK, let database else {
            if let database, sqlite3_close(database) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
            return DatabaseScanResult(items: [], isComplete: false)
        }
        defer {
            if sqlite3_close(database) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
        }
        sqlite3_busy_timeout(database, 250)
        guard sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            return DatabaseScanResult(items: [], isComplete: false)
        }
        defer {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        }

        let hasSMUTable = self.tableExists("session_model_usage", in: database)
        let hasSessionsTable = self.tableExists("sessions", in: database)
        guard hasSessionsTable || hasSMUTable else {
            return DatabaseScanResult(items: [], isComplete: false)
        }
        guard !hasSMUTable || self.hasRequiredColumns(
            table: "session_model_usage",
            columns: [
                "session_id", "model", "billing_provider", "billing_base_url", "billing_mode", "task",
                "api_call_count", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
                "reasoning_tokens", "estimated_cost_usd", "actual_cost_usd", "cost_status", "cost_source",
                "first_seen", "last_seen",
            ],
            in: database),
            !hasSessionsTable || self.hasRequiredColumns(
                table: "sessions",
                columns: [
                    "id", "model", "billing_provider", "started_at", "last_activity_at",
                    "api_call_count", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
                    "reasoning_tokens", "estimated_cost_usd", "actual_cost_usd", "cost_status", "cost_source",
                ],
                in: database)
        else {
            return DatabaseScanResult(items: [], isComplete: false)
        }

        var smuRowsBySession: [String: [SMURow]] = [:]
        var smuComplete = true
        if hasSMUTable {
            let (rows, complete) = try self.readSMURows(database: database, budget: budget)
            smuComplete = complete
            for row in rows {
                smuRowsBySession[row.sessionID, default: []].append(row)
            }
        }

        var sessionRowsByID: [String: SessionRow] = [:]
        var sessionsComplete = true
        if hasSessionsTable, smuComplete {
            let (rows, complete) = try self.readSessionRows(database: database, budget: budget)
            sessionsComplete = complete
            for row in rows {
                sessionRowsByID[row.id] = row
            }
        }

        var items: [UsageItem] = []
        let allSessionIDs = Set(smuRowsBySession.keys).union(sessionRowsByID.keys)
        let sourceDatabase = url.standardizedFileURL.path

        for sessionID in allSessionIDs {
            if smuComplete, sessionsComplete {
                try budget.check()
            }
            let smuRows = smuRowsBySession[sessionID] ?? []
            let sessionRow = sessionRowsByID[sessionID]
            let sessionCost = sessionRow.map { row in
                self.costValue(
                    actual: row.actualCostUSD,
                    estimated: row.estimatedCostUSD,
                    status: row.costStatus,
                    source: row.costSource)
            }
            // A vendor-metered session total is authoritative for the whole session. If its
            // per-model rows carry estimates (or no cost), do not add those estimates beside the
            // session total; retain the model token details and publish the actual once as the
            // residual. Rows whose costs are also actual remain eligible for normal subtraction.
            let knownModelCostTotal: Double? = {
                var total = 0.0
                for row in smuRows {
                    let rowCost = self.costValue(
                        actual: row.actualCostUSD,
                        estimated: row.estimatedCostUSD,
                        status: row.costStatus,
                        source: row.costSource)
                    guard let amount = rowCost.amount else { return nil }
                    let next = total + amount
                    guard next.isFinite else { return nil }
                    total = next
                }
                return total
            }()
            let modelCostScale: Double? = if let sessionCost,
                                             let sessionAmount = sessionCost.amount,
                                             let knownModelCostTotal,
                                             knownModelCostTotal > sessionAmount,
                                             knownModelCostTotal > 0,
                                             smuRows.allSatisfy({ row in
                                                 let rowCost = self.costValue(
                                                     actual: row.actualCostUSD,
                                                     estimated: row.estimatedCostUSD,
                                                     status: row.costStatus,
                                                     source: row.costSource)
                                                 return rowCost.kind == sessionCost.kind && rowCost.amount != nil
                                             })
            {
                sessionAmount / knownModelCostTotal
            } else {
                nil
            }
            let prefersAuthoritativeSessionCost: Bool = if let sessionCost,
                                                           let sessionAmount = sessionCost.amount
            {
                smuRows.contains { row in
                    let rowCost = self.costValue(
                        actual: row.actualCostUSD,
                        estimated: row.estimatedCostUSD,
                        status: row.costStatus,
                        source: row.costSource)
                    return rowCost.kind != sessionCost.kind || rowCost.amount == nil
                } || ((knownModelCostTotal.map { $0 > sessionAmount } ?? false) && modelCostScale == nil)
            } else {
                false
            }

            var smuInput: Int64 = 0
            var smuOutput: Int64 = 0
            var smuCacheRead: Int64 = 0
            var smuCacheWrite: Int64 = 0
            var smuReasoning: Int64 = 0
            var smuCost = 0.0
            var smuCostKnown = true
            var smuCostKind: CostKind?
            var smuCalls: Int64 = 0
            var smuCallsKnown = true

            for row in smuRows {
                let inp = max(0, row.inputTokens)
                let out = max(0, row.outputTokens)
                let cr = max(0, row.cacheReadTokens)
                let cw = max(0, row.cacheWriteTokens)
                let reas = max(0, row.reasoningTokens)
                // Canonical total in Hermes producer semantics: input + output + cacheRead + cacheWrite
                guard let rowTotal = self.checkedSum([inp, out, cr, cw]) else {
                    smuComplete = false
                    continue
                }
                let (nextInp, o1) = smuInput.addingReportingOverflow(inp)
                let (nextOut, o2) = smuOutput.addingReportingOverflow(out)
                let (nextCr, o3) = smuCacheRead.addingReportingOverflow(cr)
                let (nextCw, o4) = smuCacheWrite.addingReportingOverflow(cw)
                let (nextReas, o5) = smuReasoning.addingReportingOverflow(reas)
                guard !o1, !o2, !o3, !o4, !o5 else {
                    smuComplete = false
                    continue
                }
                smuInput = nextInp
                smuOutput = nextOut
                smuCacheRead = nextCr
                smuCacheWrite = nextCw
                smuReasoning = nextReas

                let parsedCostValue = self.costValue(
                    actual: row.actualCostUSD,
                    estimated: row.estimatedCostUSD,
                    status: row.costStatus,
                    source: row.costSource)
                let costValue: CostValue = if prefersAuthoritativeSessionCost {
                    CostValue(amount: nil, kind: sessionCost?.kind ?? .unknown)
                } else if let modelCostScale,
                          let amount = parsedCostValue.amount
                {
                    CostValue(amount: amount * modelCostScale, kind: parsedCostValue.kind)
                } else {
                    parsedCostValue
                }
                if prefersAuthoritativeSessionCost {
                    smuCostKind = self.mergedCostKind(smuCostKind, sessionCost?.kind ?? .unknown)
                } else if let cost = costValue.amount {
                    let next = smuCost + cost
                    guard next.isFinite else {
                        smuComplete = false
                        continue
                    }
                    smuCost = next
                    smuCostKind = self.mergedCostKind(smuCostKind, costValue.kind)
                } else {
                    smuCostKnown = false
                }
                if let calls = row.apiCallCount {
                    let (nextCalls, callsOverflow) = smuCalls.addingReportingOverflow(calls)
                    guard !callsOverflow else {
                        smuComplete = false
                        continue
                    }
                    smuCalls = nextCalls
                } else {
                    smuCallsKnown = false
                }

                // Hermes counters are cumulative; attribute each route to its latest observation
                // instead of backdating the whole total to the session start. Legacy model rows
                // may not carry their own observation timestamp, so retain them on the matching
                // session's activity/start date rather than silently dropping their usage.
                let timestamp: Double? = if let ls = row.lastSeen, ls.isFinite, ls > 0 {
                    ls
                } else if let fs = row.firstSeen, fs.isFinite, fs > 0 {
                    fs
                } else if let sessionRow,
                          let activity = sessionRow.lastActivityAt,
                          activity.isFinite,
                          activity > 0
                {
                    activity
                } else if let sessionRow, sessionRow.startedAt.isFinite, sessionRow.startedAt > 0 {
                    sessionRow.startedAt
                } else {
                    nil
                }

                let providerKey = row.billingProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseURLKey = row.billingBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let billingModeKey = row.billingMode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let taskKey = row.task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let dedup = "hermes:smu:\(sessionID):\(row.model):\(providerKey ?? "<null>"):" +
                    "\(baseURLKey):\(billingModeKey):\(taskKey)"
                items.append(UsageItem(
                    sessionID: sessionID,
                    sourceDatabase: sourceDatabase,
                    model: row.model,
                    billingProvider: providerKey,
                    task: taskKey,
                    timestamp: timestamp,
                    apiCalls: row.apiCallCount,
                    input: inp,
                    output: out,
                    cacheRead: cr,
                    cacheWrite: cw,
                    reasoning: reas,
                    totalTokens: rowTotal,
                    costUSD: costValue.amount,
                    costKind: costValue.kind,
                    dedupKey: dedup,
                    sessionTotalTokens: nil,
                    sessionTotalApiCalls: nil))
            }

            // Reconcile residual against sessions aggregate row
            if let s = sessionRow {
                let sInput = max(0, s.inputTokens)
                let sOutput = max(0, s.outputTokens)
                let sCacheRead = max(0, s.cacheReadTokens)
                let sCacheWrite = max(0, s.cacheWriteTokens)
                let sReasoning = max(0, s.reasoningTokens)
                let sessionCostValue = sessionCost ?? CostValue(amount: nil, kind: .unknown)
                let sCost = sessionCostValue.amount
                let sCalls = s.apiCallCount
                let sessionTotalTokens = self.checkedSum([sInput, sOutput, sCacheRead, sCacheWrite])
                let sessionTotalApiCalls = sCalls.map { max(0, $0) }

                let resInput = max(0, sInput - smuInput)
                let resOutput = max(0, sOutput - smuOutput)
                let resCacheRead = max(0, sCacheRead - smuCacheRead)
                let resCacheWrite = max(0, sCacheWrite - smuCacheWrite)
                let resReasoning = max(0, sReasoning - smuReasoning)
                let resCost: Double? = if let sCost, smuCostKnown,
                                          let smuKind = smuCostKind,
                                          smuKind == sessionCostValue.kind
                {
                    max(0.0, sCost - smuCost)
                } else if smuRows.isEmpty {
                    sCost
                } else {
                    nil
                }
                let resCalls: Int64? = if let sCalls, smuCallsKnown {
                    max(0, sCalls - smuCalls)
                } else if smuRows.isEmpty {
                    sCalls
                } else {
                    nil
                }

                guard let resTotal = self.checkedSum([resInput, resOutput, resCacheRead, resCacheWrite])
                else { continue }

                let hasResidual = resTotal > 0
                    || (resCost ?? 0) > 0
                    || (resCalls ?? 0) > 0
                    || (prefersAuthoritativeSessionCost && sCost != nil)
                    || (smuRows.isEmpty && (sCost != nil || (sCalls ?? 0) > 0))
                if hasResidual {
                    // Residual cumulative session totals follow the latest activity timestamp.
                    // `startedAt` is only a last-resort fallback for old rows without activity.
                    let timestamp: Double? = if let la = s.lastActivityAt, la.isFinite, la > 0 {
                        la
                    } else if s.startedAt.isFinite, s.startedAt > 0 {
                        s.startedAt
                    } else {
                        nil
                    }
                    let modelName = s.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let effectiveModel = (modelName?.isEmpty == false) ? modelName! : "unknown"
                    let providerKey = s.billingProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Residual rows represent the session-level remainder. Keep one newest
                    // observation per session even when its mutable model/provider metadata
                    // changed between the default and profile databases.
                    let dedup = "hermes:res:\(sessionID)"
                    items.append(UsageItem(
                        sessionID: sessionID,
                        sourceDatabase: sourceDatabase,
                        model: effectiveModel,
                        billingProvider: providerKey,
                        task: "",
                        timestamp: timestamp,
                        apiCalls: resCalls,
                        input: resInput,
                        output: resOutput,
                        cacheRead: resCacheRead,
                        cacheWrite: resCacheWrite,
                        reasoning: resReasoning,
                        totalTokens: resTotal,
                        costUSD: resCost,
                        costKind: resCost == nil ? .unknown : sessionCostValue.kind,
                        dedupKey: dedup,
                        sessionTotalTokens: sessionTotalTokens,
                        sessionTotalApiCalls: sessionTotalApiCalls))
                }
            }
        }

        return DatabaseScanResult(
            items: items,
            isComplete: smuComplete && sessionsComplete)
        #else
        return DatabaseScanResult(items: [], isComplete: false)
        #endif
    }

    // swiftlint:enable function_body_length

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func tableExists(_ tableName: String, in database: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, tableName, -1, self.SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func readSMURows(
        database: OpaquePointer,
        budget: Budget) throws -> (rows: [SMURow], complete: Bool)
    {
        let sql = """
        SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task, api_call_count,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
               estimated_cost_usd, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        FROM session_model_usage
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return ([], false)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [SMURow] = []
        var validRows = true
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            do {
                try budget.chargeRow()
            } catch ScanFailure.exhausted {
                return (rows, false)
            }
            if let sidPtr = sqlite3_column_text(statement, 0),
               let modelPtr = sqlite3_column_text(statement, 1)
            {
                let sessionID = String(cString: sidPtr)
                let model = String(cString: modelPtr)
                let billingProvider = self.columnText(statement, 2)
                let billingBaseURL = self.columnText(statement, 3)
                let billingMode = self.columnText(statement, 4)
                let task = self.columnText(statement, 5)
                let apiCalls = self.nonnegativeInt64(statement, 6)
                guard let inp = self.requiredNonnegativeInt64(statement, 7),
                      let out = self.requiredNonnegativeInt64(statement, 8),
                      let cr = self.requiredNonnegativeInt64(statement, 9),
                      let cw = self.requiredNonnegativeInt64(statement, 10),
                      let reas = self.requiredNonnegativeInt64(statement, 11)
                else {
                    validRows = false
                    stepResult = sqlite3_step(statement)
                    continue
                }
                let est = self.columnDouble(statement, 12)
                let act = self.columnDouble(statement, 13)
                let status = self.columnText(statement, 14)
                let source = self.columnText(statement, 15)
                let fs = self.columnDouble(statement, 16)
                let ls = self.columnDouble(statement, 17)
                if !sessionID.isEmpty, !model.isEmpty {
                    rows.append(SMURow(
                        sessionID: sessionID,
                        model: model,
                        billingProvider: billingProvider,
                        billingBaseURL: billingBaseURL,
                        billingMode: billingMode,
                        task: task,
                        apiCallCount: apiCalls,
                        inputTokens: inp,
                        outputTokens: out,
                        cacheReadTokens: cr,
                        cacheWriteTokens: cw,
                        reasoningTokens: reas,
                        estimatedCostUSD: est,
                        actualCostUSD: act,
                        costStatus: status,
                        costSource: source,
                        firstSeen: fs,
                        lastSeen: ls))
                }
            }
            stepResult = sqlite3_step(statement)
        }
        return (rows, stepResult == SQLITE_DONE && validRows)
    }

    private static func readSessionRows(
        database: OpaquePointer,
        budget: Budget) throws -> (rows: [SessionRow], complete: Bool)
    {
        let sql = """
        SELECT id, model, billing_provider, started_at, last_activity_at,
               api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
               reasoning_tokens, estimated_cost_usd, actual_cost_usd, cost_status, cost_source
        FROM sessions
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return ([], false)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [SessionRow] = []
        var validRows = true
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            do {
                try budget.chargeRow()
            } catch ScanFailure.exhausted {
                return (rows, false)
            }
            if let idPtr = sqlite3_column_text(statement, 0) {
                let id = String(cString: idPtr)
                let model = self.columnText(statement, 1)
                let provider = self.columnText(statement, 2)
                guard let startedAt = self.requiredFiniteDouble(statement, 3) else {
                    validRows = false
                    stepResult = sqlite3_step(statement)
                    continue
                }
                let lastActivityAt = self.columnDouble(statement, 4)
                let apiCalls = self.nonnegativeInt64(statement, 5)
                guard let inp = self.requiredNonnegativeInt64(statement, 6),
                      let out = self.requiredNonnegativeInt64(statement, 7),
                      let cr = self.requiredNonnegativeInt64(statement, 8),
                      let cw = self.requiredNonnegativeInt64(statement, 9),
                      let reas = self.requiredNonnegativeInt64(statement, 10)
                else {
                    validRows = false
                    stepResult = sqlite3_step(statement)
                    continue
                }
                let est = self.columnDouble(statement, 11)
                let act = self.columnDouble(statement, 12)
                let status = self.columnText(statement, 13)
                let source = self.columnText(statement, 14)
                if !id.isEmpty {
                    rows.append(SessionRow(
                        id: id,
                        model: model,
                        billingProvider: provider,
                        startedAt: startedAt,
                        lastActivityAt: lastActivityAt,
                        apiCallCount: apiCalls,
                        inputTokens: inp,
                        outputTokens: out,
                        cacheReadTokens: cr,
                        cacheWriteTokens: cw,
                        reasoningTokens: reas,
                        estimatedCostUSD: est,
                        actualCostUSD: act,
                        costStatus: status,
                        costSource: source))
                }
            }
            stepResult = sqlite3_step(statement)
        }
        return (rows, stepResult == SQLITE_DONE && validRows)
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: ptr)
    }

    private static func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_INTEGER || type == SQLITE_FLOAT else { return nil }
        let val = sqlite3_column_double(statement, index)
        return val.isFinite ? val : nil
    }

    private static func nonnegativeInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        return value >= 0 ? value : nil
    }

    private static func requiredNonnegativeInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return self.nonnegativeInt64(statement, index)
    }

    private static func requiredFiniteDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return self.columnDouble(statement, index)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif

    private static func costValue(
        actual: Double?,
        estimated: Double?,
        status: String?,
        source: String?) -> CostValue
    {
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let validActual = actual.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let validEstimated = estimated.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

        if normalizedStatus.contains("unknown")
            || normalizedStatus.contains("unavailable")
            || normalizedStatus.contains("unpriced")
            || normalizedStatus == "n/a"
        {
            return CostValue(amount: nil, kind: .unknown)
        }
        if normalizedStatus.contains("included")
            || normalizedStatus.contains("free")
            || normalizedStatus.contains("zero")
        {
            return CostValue(amount: 0, kind: .included)
        }
        if normalizedStatus.contains("actual")
            || normalizedStatus.contains("metered")
            || normalizedStatus.contains("billed")
            || normalizedStatus.contains("vendor")
        {
            return CostValue(amount: validActual, kind: validActual == nil ? .unknown : .actual)
        }
        if normalizedStatus.contains("estimate")
            || normalizedStatus.contains("list")
            || normalizedStatus.contains("price")
        {
            return CostValue(amount: validEstimated, kind: validEstimated == nil ? .unknown : .estimated)
        }
        if normalizedSource.contains("metered") || normalizedSource.contains("actual") {
            return CostValue(amount: validActual, kind: validActual == nil ? .unknown : .actual)
        }
        if normalizedSource.contains("included") || normalizedSource.contains("free") {
            return CostValue(amount: 0, kind: .included)
        }
        if normalizedSource.contains("estimate")
            || normalizedSource.contains("list")
            || normalizedSource.contains("price")
        {
            return CostValue(amount: validEstimated, kind: validEstimated == nil ? .unknown : .estimated)
        }
        // Older Hermes rows did not persist a status. A positive amount is still unambiguous;
        // a zero with no status is intentionally unknown because SQLite's schema default is 0.
        if let validActual, validActual > 0 {
            return CostValue(amount: validActual, kind: .actual)
        }
        if let validEstimated, validEstimated > 0 {
            return CostValue(amount: validEstimated, kind: .estimated)
        }
        return CostValue(amount: nil, kind: .unknown)
    }

    private static func mergedCostKind(_ lhs: CostKind?, _ rhs: CostKind) -> CostKind {
        guard let lhs else { return rhs }
        guard lhs != rhs else { return lhs }
        return .mixed
    }

    // MARK: - Aggregation

    private struct DayAccumulator {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var reasoning: Int64 = 0
        var totalTokens: Int64 = 0
        var cost: Double = 0.0
        var hasCost: Bool = false
        var requestCount: Int = 0
        var requestCountKnown: Bool = true
        var pricedRequestCount: Int = 0
        var sawPricedCost = false
        var unpricedRequestCount: Int = 0
        var unmeteredRequestCount: Int = 0
        var estimatedRequestCount: Int = 0
        var sawEstimatedCost = false
        var sawUnpricedCost = false
        var sawUnmeteredCost = false
        var modelBreakdowns: [String: ModelAccumulator] = [:]
    }

    private struct ModelAccumulator {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var reasoning: Int64 = 0
        var totalTokens: Int64 = 0
        var cost: Double = 0.0
        var hasCost: Bool = false
        var requestCount: Int = 0
        var requestCountKnown: Bool = true
        var pricedRequestCount: Int = 0
        var sawPricedCost = false
        var unpricedRequestCount: Int = 0
        var unmeteredRequestCount: Int = 0
        var estimatedRequestCount: Int = 0
        var sawEstimatedCost = false
        var sawUnpricedCost = false
        var sawUnmeteredCost = false
    }

    private static func updateCoverage(_ accumulator: inout ModelAccumulator, item: UsageItem) -> Bool {
        let units = self.coverageUnits(for: item)
        switch item.costKind {
        case .actual:
            accumulator.sawPricedCost = true
            let (next, overflow) = accumulator.pricedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.pricedRequestCount = next
        case .estimated:
            accumulator.sawEstimatedCost = true
            let (next, overflow) = accumulator.estimatedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.estimatedRequestCount = next
        case .included:
            accumulator.sawUnmeteredCost = true
            let (next, overflow) = accumulator.unmeteredRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.unmeteredRequestCount = next
        case .unknown, .mixed:
            accumulator.sawUnpricedCost = true
            let (next, overflow) = accumulator.unpricedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.unpricedRequestCount = next
        }
        return true
    }

    private static func coverageUnits(for item: UsageItem) -> Int {
        guard let apiCalls = item.apiCalls else { return 1 }
        return Int(exactly: apiCalls) ?? 0
    }

    private static func updateCoverage(_ accumulator: inout DayAccumulator, item: UsageItem) -> Bool {
        let units = self.coverageUnits(for: item)
        switch item.costKind {
        case .actual:
            accumulator.sawPricedCost = true
            let (next, overflow) = accumulator.pricedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.pricedRequestCount = next
        case .estimated:
            accumulator.sawEstimatedCost = true
            let (next, overflow) = accumulator.estimatedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.estimatedRequestCount = next
        case .included:
            accumulator.sawUnmeteredCost = true
            let (next, overflow) = accumulator.unmeteredRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.unmeteredRequestCount = next
        case .unknown, .mixed:
            accumulator.sawUnpricedCost = true
            let (next, overflow) = accumulator.unpricedRequestCount.addingReportingOverflow(units)
            guard !overflow else { return false }
            accumulator.unpricedRequestCount = next
        }
        return true
    }

    private static func normalizedTimestamp(_ timestamp: Double?) -> Double? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        return timestamp > 1e12 ? timestamp / 1000.0 : timestamp
    }

    /// Hermes profiles can retain cumulative copies of the same session route. Prefer the
    /// newest observation; if two databases captured it at the same instant, keep the copy
    /// with the larger cumulative counters instead of depending on database discovery order.
    private static func shouldPrefer(_ candidate: UsageItem, over current: UsageItem) -> Bool {
        let candidateTimestamp = self.normalizedTimestamp(candidate.timestamp)
        let currentTimestamp = self.normalizedTimestamp(current.timestamp)
        if candidateTimestamp != currentTimestamp {
            return (candidateTimestamp ?? -.infinity) > (currentTimestamp ?? -.infinity)
        }
        if candidate.totalTokens != current.totalTokens {
            return candidate.totalTokens > current.totalTokens
        }
        if candidate.apiCalls != current.apiCalls {
            return (candidate.apiCalls ?? -1) > (current.apiCalls ?? -1)
        }
        if candidate.costUSD != current.costUSD {
            return (candidate.costUSD ?? -.infinity) > (current.costUSD ?? -.infinity)
        }
        return false
    }

    /// A stale session-only residual from one Hermes profile must not survive when a newer
    /// profile contains model rows that already cover the same cumulative counters. Keep the
    /// source path on each item so a legitimate residual within one database is not suppressed.
    private static func suppressCoveredResiduals(_ itemsByDedupKey: inout [String: UsageItem]) {
        let values = Array(itemsByDedupKey.values)
        let modelItemsBySession = Dictionary(grouping: values.filter { $0.dedupKey.hasPrefix("hermes:smu:") }) {
            $0.sessionID
        }
        for residual in values where residual.dedupKey.hasPrefix("hermes:res:") {
            let candidates = (modelItemsBySession[residual.sessionID] ?? []).filter { candidate in
                guard candidate.sourceDatabase != residual.sourceDatabase else { return false }
                guard let candidateTimestamp = self.normalizedTimestamp(candidate.timestamp) else { return false }
                guard let residualTimestamp = self.normalizedTimestamp(residual.timestamp) else { return true }
                return candidateTimestamp >= residualTimestamp
            }
            guard !candidates.isEmpty else { continue }
            let tokenTotal = candidates.reduce(into: Int64(0)) { total, candidate in
                let (next, overflow) = total.addingReportingOverflow(max(0, candidate.totalTokens))
                total = overflow ? Int64.max : next
            }
            let sessionTokenTotal = max(0, residual.sessionTotalTokens ?? residual.totalTokens)
            guard tokenTotal >= sessionTokenTotal else { continue }

            let candidateCalls = candidates.compactMap(\.apiCalls)
            let candidateCallsAreComplete = candidateCalls.count == candidates.count
            // A token-complete profile is not enough to discard a residual when the newer model
            // rows omit call counts. Keep the residual request count in that case.
            if residual.sessionTotalApiCalls != nil, !candidateCallsAreComplete, residual.apiCalls != nil {
                continue
            }
            let unmatchedResidualCalls: Int64? = {
                guard let sessionCalls = residual.sessionTotalApiCalls, candidateCallsAreComplete else {
                    return residual.apiCalls
                }
                let candidateCallTotal = candidateCalls.reduce(into: Int64(0)) { total, calls in
                    let (next, overflow) = total.addingReportingOverflow(max(0, calls))
                    total = overflow ? Int64.max : next
                }
                return max(0, sessionCalls - candidateCallTotal)
            }()

            // If the session-level cost and request count are already represented by the newer
            // model rows, remove the residual entirely. Otherwise keep a cost/request-only
            // residual so authoritative coverage is not lost while token counters remain
            // de-duplicated.
            let residualCost = residual.costUSD
            let matchingCost = candidates
                .filter { $0.costKind == residual.costKind }
                .compactMap(\.costUSD)
                .reduce(0.0, +)
            // Model rows from a newer profile may carry only part of the authoritative session
            // cost. Subtract their same-provenance amount from the retained residual instead of
            // adding the entire stale session total beside those rows.
            let unmatchedResidualCost = residualCost.map { max(0.0, $0 - matchingCost) }
            let hasUnmatchedCost = unmatchedResidualCost.map { $0 > 0 } == true
            let hasUnmatchedCalls = unmatchedResidualCalls.map { $0 > 0 } == true
            if !hasUnmatchedCost, !hasUnmatchedCalls {
                itemsByDedupKey.removeValue(forKey: residual.dedupKey)
            } else {
                itemsByDedupKey[residual.dedupKey] = UsageItem(
                    sessionID: residual.sessionID,
                    sourceDatabase: residual.sourceDatabase,
                    model: residual.model,
                    billingProvider: residual.billingProvider,
                    task: residual.task,
                    timestamp: residual.timestamp,
                    apiCalls: unmatchedResidualCalls,
                    input: 0,
                    output: 0,
                    cacheRead: 0,
                    cacheWrite: 0,
                    reasoning: 0,
                    totalTokens: 0,
                    costUSD: unmatchedResidualCost,
                    costKind: residual.costKind,
                    dedupKey: residual.dedupKey,
                    sessionTotalTokens: residual.sessionTotalTokens,
                    sessionTotalApiCalls: residual.sessionTotalApiCalls)
            }
        }
    }

    // swiftlint:disable function_body_length
    // swiftlint:disable:next cyclomatic_complexity
    private static func aggregate(
        items: [UsageItem],
        calendar: Calendar,
        isComplete: Bool,
        budget: Budget,
        checkBudget: Bool) throws -> DailyReportResult
    {
        var itemsByDedupKey: [String: UsageItem] = [:]
        for item in items {
            if checkBudget {
                try budget.check()
            }
            if let current = itemsByDedupKey[item.dedupKey] {
                if self.shouldPrefer(item, over: current) {
                    itemsByDedupKey[item.dedupKey] = item
                }
            } else {
                itemsByDedupKey[item.dedupKey] = item
            }
        }
        self.suppressCoveredResiduals(&itemsByDedupKey)

        var dayMap: [String: DayAccumulator] = [:]
        var aggregationComplete = isComplete

        for item in itemsByDedupKey.values.sorted(by: { $0.dedupKey < $1.dedupKey }) {
            if checkBudget {
                try budget.check()
            }
            guard let timestamp = item.timestamp, timestamp.isFinite, timestamp > 0 else {
                aggregationComplete = false
                continue
            }
            let date = if timestamp > 1e12 {
                Date(timeIntervalSince1970: timestamp / 1000.0)
            } else {
                Date(timeIntervalSince1970: timestamp)
            }
            let dayKey = CostUsageLocalDay.key(from: date, calendar: calendar)
            var accum = dayMap[dayKey] ?? DayAccumulator()

            let itemCalls = item.apiCalls.flatMap { Int(exactly: $0) }
            guard item.apiCalls == nil || itemCalls != nil else {
                aggregationComplete = false
                continue
            }
            let nextCalls: Int? = if let itemCalls {
                self.checkedAdd(accum.requestCount, itemCalls)
            } else {
                accum.requestCount
            }
            guard let nextInp = self.checkedAdd(accum.input, item.input),
                  let nextOut = self.checkedAdd(accum.output, item.output),
                  let nextCr = self.checkedAdd(accum.cacheRead, item.cacheRead),
                  let nextCw = self.checkedAdd(accum.cacheWrite, item.cacheWrite),
                  let nextReas = self.checkedAdd(accum.reasoning, item.reasoning),
                  let nextTotal = self.checkedAdd(accum.totalTokens, item.totalTokens),
                  let nextCalls
            else {
                aggregationComplete = false
                continue
            }
            accum.input = nextInp
            accum.output = nextOut
            accum.cacheRead = nextCr
            accum.cacheWrite = nextCw
            accum.reasoning = nextReas
            accum.totalTokens = nextTotal
            accum.requestCount = nextCalls
            if item.apiCalls == nil {
                accum.requestCountKnown = false
            }

            if let cost = item.costUSD, cost.isFinite, cost >= 0 {
                let nextCost = accum.cost + cost
                guard nextCost.isFinite else {
                    aggregationComplete = false
                    continue
                }
                accum.cost = nextCost
                accum.hasCost = true
            }
            guard self.updateCoverage(&accum, item: item) else {
                aggregationComplete = false
                continue
            }

            var modelAccum = accum.modelBreakdowns[item.model] ?? ModelAccumulator()
            let mNextCalls: Int? = if let itemCalls {
                self.checkedAdd(modelAccum.requestCount, itemCalls)
            } else {
                modelAccum.requestCount
            }
            guard let mNextInp = self.checkedAdd(modelAccum.input, item.input),
                  let mNextOut = self.checkedAdd(modelAccum.output, item.output),
                  let mNextCr = self.checkedAdd(modelAccum.cacheRead, item.cacheRead),
                  let mNextCw = self.checkedAdd(modelAccum.cacheWrite, item.cacheWrite),
                  let mNextReas = self.checkedAdd(modelAccum.reasoning, item.reasoning),
                  let mNextTotal = self.checkedAdd(modelAccum.totalTokens, item.totalTokens),
                  let mNextCalls
            else {
                aggregationComplete = false
                continue
            }
            modelAccum.input = mNextInp
            modelAccum.output = mNextOut
            modelAccum.cacheRead = mNextCr
            modelAccum.cacheWrite = mNextCw
            modelAccum.reasoning = mNextReas
            modelAccum.totalTokens = mNextTotal
            modelAccum.requestCount = mNextCalls
            if item.apiCalls == nil {
                modelAccum.requestCountKnown = false
            }
            if let cost = item.costUSD, cost.isFinite, cost >= 0 {
                let nextCost = modelAccum.cost + cost
                guard nextCost.isFinite else {
                    aggregationComplete = false
                    continue
                }
                modelAccum.cost = nextCost
                modelAccum.hasCost = true
            }
            guard self.updateCoverage(&modelAccum, item: item) else {
                aggregationComplete = false
                continue
            }
            accum.modelBreakdowns[item.model] = modelAccum
            dayMap[dayKey] = accum
        }

        var entries: [CostUsageDailyReport.Entry] = []
        for (dayKey, accum) in dayMap {
            let inputTokens: Int? = accum.input > 0 ? Int(exactly: accum.input) : nil
            let outputTokens: Int? = accum.output > 0 ? Int(exactly: accum.output) : nil
            let cacheReadTokens: Int? = accum.cacheRead > 0 ? Int(exactly: accum.cacheRead) : nil
            let cacheCreationTokens: Int? = accum.cacheWrite > 0 ? Int(exactly: accum.cacheWrite) : nil
            let reasoningTokens: Int? = accum.reasoning > 0 ? Int(exactly: accum.reasoning) : nil
            let totalTokensInt: Int? = accum.totalTokens > 0 ? Int(exactly: accum.totalTokens) : nil
            let requestCount: Int? = accum.requestCountKnown && accum.requestCount > 0 ? accum.requestCount : nil
            let costUSD: Double? = accum.hasCost ? accum.cost : nil

            var breakdowns: [CostUsageDailyReport.ModelBreakdown]?
            if !accum.modelBreakdowns.isEmpty {
                breakdowns = accum.modelBreakdowns.map { model, mAccum in
                    let bCost: Double? = mAccum.hasCost ? mAccum.cost : nil
                    let bTokens: Int? = mAccum.totalTokens > 0 ? Int(exactly: mAccum.totalTokens) : nil
                    let bInput: Int? = mAccum.input > 0 ? Int(exactly: mAccum.input) : nil
                    let bOutput: Int? = mAccum.output > 0 ? Int(exactly: mAccum.output) : nil
                    let bCr: Int? = mAccum.cacheRead > 0 ? Int(exactly: mAccum.cacheRead) : nil
                    let bCw: Int? = mAccum.cacheWrite > 0 ? Int(exactly: mAccum.cacheWrite) : nil
                    let bReas: Int? = mAccum.reasoning > 0 ? Int(exactly: mAccum.reasoning) : nil
                    return CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: bCost,
                        totalTokens: bTokens,
                        requestCount: mAccum.requestCountKnown && mAccum.requestCount > 0
                            ? mAccum.requestCount : nil,
                        inputTokens: bInput,
                        outputTokens: bOutput,
                        cacheReadTokens: bCr,
                        cacheCreationTokens: bCw,
                        reasoningTokens: bReas)
                }.sorted { $0.modelName < $1.modelName }
            }

            let entry = CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                reasoningTokens: reasoningTokens,
                totalTokens: totalTokensInt,
                requestCount: requestCount,
                costUSD: costUSD,
                modelsUsed: breakdowns?.map(\.modelName).sorted(),
                modelBreakdowns: breakdowns,
                unpricedRequestCount: accum.sawUnpricedCost ? accum.unpricedRequestCount : nil,
                unmeteredRequestCount: accum.sawUnmeteredCost ? accum.unmeteredRequestCount : nil,
                estimatedRequestCount: accum.sawEstimatedCost ? accum.estimatedRequestCount : nil,
                pricedRequestCount: accum.sawPricedCost ? accum.pricedRequestCount : nil)
            entries.append(entry)
        }
        entries.sort { $0.date < $1.date }

        var totalTokensSum = 0
        var totalTokensOverflowed = false
        for value in entries.compactMap(\.totalTokens) {
            let (next, overflow) = totalTokensSum.addingReportingOverflow(value)
            if overflow {
                totalTokensOverflowed = true
                break
            }
            totalTokensSum = next
        }
        var totalCostSum = 0.0
        var totalCostOverflowed = false
        for value in entries.compactMap(\.costUSD) {
            let next = totalCostSum + value
            if !next.isFinite {
                totalCostOverflowed = true
                break
            }
            totalCostSum = next
        }
        let hasTokens = !entries.compactMap(\.totalTokens).isEmpty
        let hasCost = !entries.compactMap(\.costUSD).isEmpty
        if totalTokensOverflowed || totalCostOverflowed {
            aggregationComplete = false
        }
        let summary: CostUsageDailyReport.Summary? = entries.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: hasTokens && !totalTokensOverflowed ? totalTokensSum : nil,
            totalCostUSD: hasCost && !totalCostOverflowed ? totalCostSum : nil)

        return DailyReportResult(
            report: CostUsageDailyReport(data: entries, summary: summary),
            coverage: aggregationComplete ? .complete : .partial,
            statistics: budget.statistics)
    }
    // swiftlint:enable function_body_length
}

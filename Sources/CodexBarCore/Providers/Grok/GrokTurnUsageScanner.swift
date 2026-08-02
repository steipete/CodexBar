import Foundation

/// Scans local Grok session logs for per-turn API usage (`turn_completed` in `updates.jsonl`).
///
/// Maps into the shared `CostUsageDailyReport` shape so Grok reuses the same Cost menu UI as Codex.
public enum GrokTurnUsageScanner {
    /// 1 USD = 10^10 ticks (matches Grok headless `total_cost_usd_ticks`).
    public static let costUsdTicksPerDollar: Double = 10_000_000_000

    public struct Options: Sendable {
        public var sessionsRoot: URL?
        /// Where per-file parse results are persisted so deferred archives catch up later.
        public var cacheRoot: URL?
        public var environment: [String: String]
        /// Not Sendable; kept only for local filesystem reads (same pattern as other scanners).
        public nonisolated(unsafe) var fileManager: FileManager
        /// Skip any single `updates.jsonl` larger than this (0 = unlimited). Default 256 MiB.
        public var maxSessionFileBytes: Int64
        /// Soft budget for newly-read session bytes in one refresh (0 = unlimited). Default 512 MiB.
        public var maxScanBytesPerRefresh: Int64
        /// Prefer newest session files first so recent usage lands before catch-up work.
        public var preferNewestSessionsFirst: Bool

        public init(
            sessionsRoot: URL? = nil,
            cacheRoot: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            fileManager: FileManager = .default,
            maxSessionFileBytes: Int64 = 256 * 1024 * 1024,
            maxScanBytesPerRefresh: Int64 = 512 * 1024 * 1024,
            preferNewestSessionsFirst: Bool = true)
        {
            self.sessionsRoot = sessionsRoot
            self.cacheRoot = cacheRoot
            self.environment = environment
            self.fileManager = fileManager
            self.maxSessionFileBytes = max(0, maxSessionFileBytes)
            self.maxScanBytesPerRefresh = max(0, maxScanBytesPerRefresh)
            self.preferNewestSessionsFirst = preferNewestSessionsFirst
        }
    }

    /// Per-refresh work limiter (mirrors Codex cost scan protection).
    final class ScanBudget: @unchecked Sendable {
        let maxFileBytes: Int64
        let maxBytesPerRefresh: Int64
        private(set) var bytesConsumed: Int64 = 0
        private(set) var skippedOversizedFileCount = 0
        private(set) var deferredByBudgetFileCount = 0
        private(set) var skippedStaleFileCount = 0
        private(set) var cacheHitFileCount = 0
        private(set) var freshlyScannedFileCount = 0

        init(maxFileBytes: Int64, maxBytesPerRefresh: Int64) {
            self.maxFileBytes = max(0, maxFileBytes)
            self.maxBytesPerRefresh = max(0, maxBytesPerRefresh)
        }

        func markCacheHit() {
            self.cacheHitFileCount += 1
        }

        func markFreshScan() {
            self.freshlyScannedFileCount += 1
        }

        enum Admission {
            case allow(Int64)
            case skipOversized
            case deferBudget
        }

        func admit(fileBytes: Int64) -> Admission {
            let work = max(0, fileBytes)
            if self.maxFileBytes > 0, work > self.maxFileBytes {
                self.skippedOversizedFileCount += 1
                return .skipOversized
            }
            // Whole-file admission only: partial mid-file reads would drop newer tail turns.
            if self.maxBytesPerRefresh > 0 {
                let remaining = max(0, self.maxBytesPerRefresh - self.bytesConsumed)
                if work > remaining {
                    self.deferredByBudgetFileCount += 1
                    return .deferBudget
                }
            }
            return .allow(work)
        }

        func consume(workBytes: Int64) {
            self.bytesConsumed += max(0, workBytes)
        }

        func markSkippedStale() {
            self.skippedStaleFileCount += 1
        }
    }

    /// Per-model usage nested under a turn's `modelUsage` map.
    struct ModelUsage: Sendable, Equatable {
        let modelName: String
        /// Uncached input tokens (full input − cache read) for this model.
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
        let modelCalls: Int
        let costUSD: Double?

        init(
            modelName: String,
            inputTokens: Int,
            cacheReadTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            totalTokens: Int,
            modelCalls: Int,
            costUSD: Double?)
        {
            self.modelName = modelName
            self.inputTokens = inputTokens
            self.cacheReadTokens = cacheReadTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.modelCalls = modelCalls
            self.costUSD = costUSD
        }
    }

    struct TurnRecord: Sendable, Equatable {
        let eventID: String
        let sessionID: String
        let dayKey: String
        let timestamp: Date
        let cwd: String?
        /// Uncached input tokens (full input − cache read).
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
        let modelCalls: Int
        let costUSD: Double?
        /// Nested per-model totals from `modelUsage` (empty when the payload only has turn totals).
        let modelUsages: [ModelUsage]

        init(
            eventID: String,
            sessionID: String,
            dayKey: String,
            timestamp: Date,
            cwd: String?,
            inputTokens: Int,
            cacheReadTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            totalTokens: Int,
            modelCalls: Int,
            costUSD: Double?,
            modelUsages: [ModelUsage])
        {
            self.eventID = eventID
            self.sessionID = sessionID
            self.dayKey = dayKey
            self.timestamp = timestamp
            self.cwd = cwd
            self.inputTokens = inputTokens
            self.cacheReadTokens = cacheReadTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.modelCalls = modelCalls
            self.costUSD = costUSD
            self.modelUsages = modelUsages
        }

        var models: [String] {
            self.modelUsages.map(\.modelName)
        }
    }

    // MARK: - Public

    public struct ScanBundle: Sendable {
        public let daily: CostUsageDailyReport
        public let sessions: [CostUsageSessionBreakdown]
        public let projects: [CostUsageProjectBreakdown]
    }

    /// Single-pass scan used by the Cost pipeline (daily + sessions + projects).
    public static func loadScanBundle(
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: (() throws -> Void)? = nil) throws -> ScanBundle
    {
        _ = now
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
        let turns = try self.scanTurns(
            since: since,
            until: until,
            options: options,
            checkCancellation: checkCancellation)
        let inRange = turns.filter {
            CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: $0.dayKey,
                since: range.sinceKey,
                until: range.untilKey)
        }
        return ScanBundle(
            daily: self.dailyReport(from: inRange),
            sessions: self.sessionBreakdowns(from: inRange),
            projects: self.projectBreakdowns(from: inRange))
    }

    public static func loadDailyReport(
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: (() throws -> Void)? = nil) throws -> CostUsageDailyReport
    {
        try self.loadScanBundle(
            since: since,
            until: until,
            now: now,
            options: options,
            checkCancellation: checkCancellation).daily
    }

    public static func loadSessionBreakdowns(
        since: Date,
        until: Date,
        options: Options = Options(),
        checkCancellation: (() throws -> Void)? = nil) throws -> [CostUsageSessionBreakdown]
    {
        try self.loadScanBundle(
            since: since,
            until: until,
            options: options,
            checkCancellation: checkCancellation).sessions
    }

    public static func loadProjectBreakdowns(
        since: Date,
        until: Date,
        options: Options = Options(),
        checkCancellation: (() throws -> Void)? = nil) throws -> [CostUsageProjectBreakdown]
    {
        try self.loadScanBundle(
            since: since,
            until: until,
            options: options,
            checkCancellation: checkCancellation).projects
    }

    /// Resolve `~/.grok/sessions` (or `GROK_HOME/sessions`).
    public static func sessionsRoot(options: Options = Options()) -> URL {
        if let override = options.sessionsRoot {
            return override
        }
        return GrokCredentialsStore.grokHomeURL(env: options.environment, fileManager: options.fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Scan

    private struct SessionLogFile {
        let url: URL
        let sessionID: String
        let size: Int64
        let modifiedAt: Date
    }

    static func scanTurns(
        since: Date = Date.distantPast,
        until: Date = Date.distantFuture,
        options: Options,
        checkCancellation: (() throws -> Void)?,
        budget: ScanBudget? = nil) throws -> [TurnRecord]
    {
        let root = self.sessionsRoot(options: options)
        let fileManager = options.fileManager
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let activeBudget = budget ?? ScanBudget(
            maxFileBytes: options.maxSessionFileBytes,
            maxBytesPerRefresh: options.maxScanBytesPerRefresh)

        var candidates = try self.listSessionLogFiles(
            root: root,
            fileManager: fileManager,
            checkCancellation: checkCancellation)
        if options.preferNewestSessionsFirst {
            candidates.sort { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.url.path < rhs.url.path
            }
        } else {
            candidates.sort { $0.url.path < $1.url.path }
        }

        // Files that have not been touched since before the window cannot contain in-range turns.
        let staleCutoff = since
        var byEventID: [String: TurnRecord] = [:]
        var cwdBySession: [String: String] = [:]
        var cache = GrokTurnUsageCacheIO.load(cacheRoot: options.cacheRoot)
        var nextCache = GrokTurnUsageCache(version: cache.version)
        var cacheDirty = false

        for file in candidates {
            try checkCancellation?()
            if file.modifiedAt < staleCutoff {
                activeBudget.markSkippedStale()
                // Drop stale entries so the cache does not grow without bound.
                if cache.files[file.url.path] != nil {
                    cacheDirty = true
                }
                continue
            }

            let mtimeMs = Int64((file.modifiedAt.timeIntervalSince1970 * 1000).rounded())
            if let cached = cache.files[file.url.path],
               cached.size == file.size,
               cached.mtimeUnixMs == mtimeMs
            {
                // Unchanged file: reuse parse results without spending refresh budget.
                activeBudget.markCacheHit()
                nextCache.files[file.url.path] = cached
                for turn in cached.turns {
                    let record = turn.asTurnRecord()
                    if byEventID[record.eventID] == nil {
                        byEventID[record.eventID] = record
                    }
                }
                continue
            }

            switch activeBudget.admit(fileBytes: file.size) {
            case .skipOversized:
                // Keep any prior good parse for this path if present (best-effort).
                if let prior = cache.files[file.url.path] {
                    nextCache.files[file.url.path] = prior
                    for turn in prior.turns {
                        let record = turn.asTurnRecord()
                        if byEventID[record.eventID] == nil {
                            byEventID[record.eventID] = record
                        }
                    }
                }
                continue
            case .deferBudget:
                // Persist prior results for deferred files so history is not permanently lost.
                if let prior = cache.files[file.url.path] {
                    nextCache.files[file.url.path] = prior
                    for turn in prior.turns {
                        let record = turn.asTurnRecord()
                        if byEventID[record.eventID] == nil {
                            byEventID[record.eventID] = record
                        }
                    }
                }
                continue
            case let .allow(allowedBytes):
                if cwdBySession[file.sessionID] == nil {
                    cwdBySession[file.sessionID] = self.readCwd(
                        sessionDirectory: file.url.deletingLastPathComponent(),
                        fileManager: fileManager)
                }
                let cwd = cwdBySession[file.sessionID]
                var scanned: [TurnRecord] = []
                let readBytes = try self.scanSessionLogFile(
                    url: file.url,
                    sessionID: file.sessionID,
                    cwd: cwd,
                    maxBytesToRead: allowedBytes,
                    until: until,
                    checkCancellation: checkCancellation)
                { record in
                    scanned.append(record)
                    if byEventID[record.eventID] == nil {
                        byEventID[record.eventID] = record
                    }
                }
                activeBudget.consume(workBytes: readBytes)
                activeBudget.markFreshScan()
                nextCache.files[file.url.path] = GrokTurnUsageCachedFile(
                    mtimeUnixMs: mtimeMs,
                    size: file.size,
                    sessionID: file.sessionID,
                    cwd: cwd,
                    turns: scanned.map(GrokTurnUsageCachedTurn.init(from:)))
                cacheDirty = true
            }
        }

        // Persist parse results / drop deleted paths so later refreshes can catch up.
        if nextCache != cache || cacheDirty {
            GrokTurnUsageCacheIO.save(cache: nextCache, cacheRoot: options.cacheRoot)
        }

        return byEventID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.eventID < rhs.eventID
        }
    }

    private static func listSessionLogFiles(
        root: URL,
        fileManager: FileManager,
        checkCancellation: (() throws -> Void)?) throws -> [SessionLogFile]
    {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var files: [SessionLogFile] = []
        for case let url as URL in enumerator {
            try checkCancellation?()
            guard url.lastPathComponent == "updates.jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            let sessionID = url.deletingLastPathComponent().lastPathComponent
            files.append(SessionLogFile(
                url: url,
                sessionID: sessionID,
                size: size,
                modifiedAt: modifiedAt))
        }
        return files
    }

    /// Stream-read a session log up to `maxBytesToRead` without loading the whole file into memory.
    @discardableResult
    private static func scanSessionLogFile(
        url: URL,
        sessionID: String,
        cwd: String?,
        maxBytesToRead: Int64,
        until: Date,
        checkCancellation: (() throws -> Void)?,
        onRecord: (TurnRecord) -> Void) throws -> Int64
    {
        guard maxBytesToRead > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var bytesRead: Int64 = 0
        var pending = Data()
        pending.reserveCapacity(16 * 1024)
        var reachedEOF = false

        func consumeLine(_ lineData: Data) throws {
            try checkCancellation?()
            guard let line = String(data: lineData, encoding: .utf8) else { return }
            guard line.contains("turn_completed") else { return }
            guard let record = self.parseTurnLine(line, sessionID: sessionID, cwd: cwd) else { return }
            // Drop turns clearly after the window (defensive; normal scans set until=now).
            if record.timestamp > until { return }
            onRecord(record)
        }

        while bytesRead < maxBytesToRead {
            try checkCancellation?()
            let remaining = maxBytesToRead - bytesRead
            let chunkSize = min(256 * 1024, Int(remaining))
            guard chunkSize > 0 else { break }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            bytesRead += Int64(chunk.count)
            pending.append(chunk)

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                try consumeLine(lineData)
            }
        }
        // Flush trailing line only when the whole file fit in budget (avoid partial last line).
        if reachedEOF, !pending.isEmpty {
            try consumeLine(pending)
        }
        return bytesRead
    }

    // MARK: - Parse

    static func parseTurnLine(_ line: String, sessionID: String, cwd: String?) -> TurnRecord? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let params = root["params"] as? [String: Any] ?? [:]
        let update = params["update"] as? [String: Any] ?? [:]
        guard (update["sessionUpdate"] as? String) == "turn_completed" else { return nil }

        let usage = update["usage"] as? [String: Any] ?? [:]
        guard !usage.isEmpty else { return nil }

        let inputFull = self.intValue(usage["inputTokens"]) ?? 0
        let cacheRead = self.intValue(usage["cachedReadTokens"]) ?? 0
        let output = self.intValue(usage["outputTokens"]) ?? 0
        let reasoning = self.intValue(usage["reasoningTokens"]) ?? 0
        let total = self.intValue(usage["totalTokens"]) ?? (inputFull + output)
        let modelCalls = self.intValue(usage["modelCalls"]) ?? 1
        let uncached = max(inputFull - cacheRead, 0)

        let costUSD: Double? = {
            guard let ticks = self.intValue(usage["costUsdTicks"]) else { return nil }
            return Double(ticks) / self.costUsdTicksPerDollar
        }()

        let modelUsages = self.parseModelUsages(from: usage["modelUsage"] as? [String: Any])

        let meta = params["_meta"] as? [String: Any] ?? [:]
        let promptID = update["prompt_id"] as? String
        let eventID: String = {
            if let id = meta["eventId"] as? String, !id.isEmpty { return id }
            let ts = root["timestamp"].map { "\($0)" } ?? "0"
            return "\(sessionID):\(promptID ?? "unknown"):\(ts)"
        }()

        let resolvedSessionID = (params["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionID
        let timestamp = self.parseTimestamp(root: root, meta: meta) ?? Date.distantPast
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: timestamp)

        return TurnRecord(
            eventID: eventID,
            sessionID: resolvedSessionID,
            dayKey: dayKey,
            timestamp: timestamp,
            cwd: cwd,
            inputTokens: uncached,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            reasoningTokens: reasoning,
            totalTokens: total,
            modelCalls: modelCalls,
            costUSD: costUSD,
            modelUsages: modelUsages)
    }

    /// Parse nested `modelUsage` entries so multi-model turns keep separate token/cost totals.
    private static func parseModelUsages(from modelUsage: [String: Any]?) -> [ModelUsage] {
        guard let modelUsage, !modelUsage.isEmpty else { return [] }
        return modelUsage.keys.sorted().compactMap { name in
            guard let payload = modelUsage[name] as? [String: Any] else {
                // Key present without nested fields — treat as a named model with zero usage.
                return ModelUsage(
                    modelName: name,
                    inputTokens: 0,
                    cacheReadTokens: 0,
                    outputTokens: 0,
                    reasoningTokens: 0,
                    totalTokens: 0,
                    modelCalls: 0,
                    costUSD: nil)
            }
            let inputFull = self.intValue(payload["inputTokens"]) ?? 0
            let cacheRead = self.intValue(payload["cachedReadTokens"]) ?? 0
            let output = self.intValue(payload["outputTokens"]) ?? 0
            let reasoning = self.intValue(payload["reasoningTokens"]) ?? 0
            let total = self.intValue(payload["totalTokens"]) ?? (inputFull + output)
            let calls = self.intValue(payload["modelCalls"]) ?? 1
            let costUSD: Double? = {
                guard let ticks = self.intValue(payload["costUsdTicks"]) else { return nil }
                return Double(ticks) / self.costUsdTicksPerDollar
            }()
            return ModelUsage(
                modelName: name,
                inputTokens: max(inputFull - cacheRead, 0),
                cacheReadTokens: cacheRead,
                outputTokens: output,
                reasoningTokens: reasoning,
                totalTokens: total,
                modelCalls: calls,
                costUSD: costUSD)
        }
    }

    /// Attribute nested model totals when present; otherwise fall back to whole-turn totals.
    private static func modelContributions(for turn: TurnRecord)
        -> [(name: String, tokens: Int, cost: Double?, requests: Int)]
    {
        if turn.modelUsages.isEmpty {
            return [(
                name: "unknown",
                tokens: turn.totalTokens,
                cost: turn.costUSD,
                requests: max(turn.modelCalls, 1))]
        }
        return turn.modelUsages.map { usage in
            (
                name: usage.modelName,
                tokens: usage.totalTokens,
                cost: usage.costUSD,
                requests: max(usage.modelCalls, 1))
        }
    }

    private static func parseTimestamp(root: [String: Any], meta: [String: Any]) -> Date? {
        if let ms = self.intValue(meta["agentTimestampMs"]) {
            if ms > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }
            return Date(timeIntervalSince1970: TimeInterval(ms))
        }
        if let ts = root["timestamp"] as? Double {
            if ts > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: ts / 1000)
            }
            return Date(timeIntervalSince1970: ts)
        }
        if let ts = root["timestamp"] as? Int {
            if ts > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            }
            return Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return nil
    }

    private static func readCwd(sessionDirectory: URL, fileManager: FileManager) -> String? {
        let summaryURL = sessionDirectory.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let info = json["info"] as? [String: Any],
           let cwd = info["cwd"] as? String,
           !cwd.isEmpty
        {
            return cwd
        }
        if let cwd = json["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let v as Int: v
        case let v as Int64: Int(v)
        case let v as Double: Int(v)
        case let v as NSNumber: v.intValue
        case let v as String: Int(v)
        default: nil
        }
    }

    // MARK: - Aggregate

    static func dailyReport(from turns: [TurnRecord]) -> CostUsageDailyReport {
        struct DayBucket {
            var input = 0
            var cache = 0
            var output = 0
            var total = 0
            var requests = 0
            var cost: Double = 0
            var sawCost = false
            var models: Set<String> = []
            var modelTotals: [String: (tokens: Int, cost: Double, sawCost: Bool, requests: Int)] = [:]
        }

        var days: [String: DayBucket] = [:]
        for turn in turns {
            var bucket = days[turn.dayKey] ?? DayBucket()
            bucket.input += turn.inputTokens
            bucket.cache += turn.cacheReadTokens
            bucket.output += turn.outputTokens
            bucket.total += turn.totalTokens
            bucket.requests += max(turn.modelCalls, 1)
            if let cost = turn.costUSD {
                bucket.cost += cost
                bucket.sawCost = true
            }
            for contribution in self.modelContributions(for: turn) {
                bucket.models.insert(contribution.name)
                var m = bucket.modelTotals[contribution.name] ?? (0, 0, false, 0)
                m.tokens += contribution.tokens
                m.requests += contribution.requests
                if let cost = contribution.cost {
                    m.cost += cost
                    m.sawCost = true
                }
                bucket.modelTotals[contribution.name] = m
            }
            days[turn.dayKey] = bucket
        }

        let entries: [CostUsageDailyReport.Entry] = days.keys.sorted().map { day in
            let b = days[day]!
            let breakdowns = b.modelTotals.keys.sorted().map { name in
                let m = b.modelTotals[name]!
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: m.sawCost ? m.cost : nil,
                    totalTokens: m.tokens,
                    requestCount: m.requests)
            }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cache,
                cacheCreationTokens: nil,
                totalTokens: b.total,
                requestCount: b.requests,
                costUSD: b.sawCost ? b.cost : nil,
                modelsUsed: b.models.sorted(),
                modelBreakdowns: breakdowns)
        }

        let costs = entries.compactMap(\.costUSD)
        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: entries.compactMap(\.inputTokens).reduce(0, +),
            totalOutputTokens: entries.compactMap(\.outputTokens).reduce(0, +),
            cacheReadTokens: entries.compactMap(\.cacheReadTokens).reduce(0, +),
            cacheCreationTokens: nil,
            totalTokens: entries.compactMap(\.totalTokens).reduce(0, +),
            totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +))

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    static func sessionBreakdowns(from turns: [TurnRecord]) -> [CostUsageSessionBreakdown] {
        struct SessionBucket {
            var lastActivity = Date.distantPast
            var input = 0
            var cache = 0
            var output = 0
            var total = 0
            var requests = 0
            var cost: Double = 0
            var sawCost = false
            var modelTotals: [String: (tokens: Int, cost: Double, sawCost: Bool, requests: Int)] = [:]
        }

        var sessions: [String: SessionBucket] = [:]
        for turn in turns {
            var b = sessions[turn.sessionID] ?? SessionBucket()
            b.lastActivity = max(b.lastActivity, turn.timestamp)
            b.input += turn.inputTokens
            b.cache += turn.cacheReadTokens
            b.output += turn.outputTokens
            b.total += turn.totalTokens
            b.requests += max(turn.modelCalls, 1)
            if let cost = turn.costUSD {
                b.cost += cost
                b.sawCost = true
            }
            for contribution in self.modelContributions(for: turn) {
                var m = b.modelTotals[contribution.name] ?? (0, 0, false, 0)
                m.tokens += contribution.tokens
                m.requests += contribution.requests
                if let cost = contribution.cost {
                    m.cost += cost
                    m.sawCost = true
                }
                b.modelTotals[contribution.name] = m
            }
            sessions[turn.sessionID] = b
        }

        return sessions.map { sessionID, b in
            let breakdowns = b.modelTotals.keys.sorted().map { name in
                let m = b.modelTotals[name]!
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: m.sawCost ? m.cost : nil,
                    totalTokens: m.tokens,
                    requestCount: m.requests)
            }
            return CostUsageSessionBreakdown(
                sessionID: sessionID,
                lastActivity: b.lastActivity,
                inputTokens: b.input,
                cachedInputTokens: b.cache,
                outputTokens: b.output,
                totalTokens: b.total,
                requestCount: b.requests,
                costUSD: b.sawCost ? b.cost : nil,
                modelBreakdowns: breakdowns)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    static func projectBreakdowns(from turns: [TurnRecord]) -> [CostUsageProjectBreakdown] {
        struct ProjectBucket {
            var path: String?
            var total = 0
            var cost: Double = 0
            var sawCost = false
            var dayTurns: [TurnRecord] = []
            var modelTotals: [String: (tokens: Int, cost: Double, sawCost: Bool, requests: Int)] = [:]
        }

        var projects: [String: ProjectBucket] = [:]
        for turn in turns {
            let key = turn.cwd ?? CostUsageProjectBreakdown.unknownProjectName
            var b = projects[key] ?? ProjectBucket(path: turn.cwd)
            b.path = turn.cwd
            b.total += turn.totalTokens
            if let cost = turn.costUSD {
                b.cost += cost
                b.sawCost = true
            }
            b.dayTurns.append(turn)
            for contribution in self.modelContributions(for: turn) {
                var m = b.modelTotals[contribution.name] ?? (0, 0, false, 0)
                m.tokens += contribution.tokens
                m.requests += contribution.requests
                if let cost = contribution.cost {
                    m.cost += cost
                    m.sawCost = true
                }
                b.modelTotals[contribution.name] = m
            }
            projects[key] = b
        }

        return projects.map { key, b in
            let name: String = {
                if let path = b.path, !path.isEmpty {
                    return URL(fileURLWithPath: path).lastPathComponent
                }
                return key
            }()
            let daily = self.dailyReport(from: b.dayTurns).data
            let breakdowns = b.modelTotals.keys.sorted().map { modelName in
                let m = b.modelTotals[modelName]!
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: m.sawCost ? m.cost : nil,
                    totalTokens: m.tokens,
                    requestCount: m.requests)
            }
            return CostUsageProjectBreakdown(
                name: name,
                path: b.path,
                totalTokens: b.total,
                totalCostUSD: b.sawCost ? b.cost : nil,
                daily: daily,
                modelBreakdowns: breakdowns,
                sources: [
                    CostUsageProjectSourceBreakdown(
                        name: name,
                        path: b.path,
                        totalTokens: b.total,
                        totalCostUSD: b.sawCost ? b.cost : nil,
                        daily: daily,
                        modelBreakdowns: breakdowns),
                ])
        }
        .sorted { ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) }
    }
}

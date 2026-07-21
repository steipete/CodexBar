import Foundation

/// Scans local Grok session logs for per-turn API usage (`turn_completed` in `updates.jsonl`).
///
/// Maps into the shared `CostUsageDailyReport` shape so Grok reuses the same Cost menu UI as Codex.
public enum GrokTurnUsageScanner {
    /// 1 USD = 10^10 ticks (matches Grok headless `total_cost_usd_ticks`).
    public static let costUsdTicksPerDollar: Double = 10_000_000_000

    public struct Options: Sendable {
        public var sessionsRoot: URL?
        public var environment: [String: String]
        /// Not Sendable; kept only for local filesystem reads (same pattern as other scanners).
        nonisolated(unsafe) public var fileManager: FileManager

        public init(
            sessionsRoot: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            fileManager: FileManager = .default)
        {
            self.sessionsRoot = sessionsRoot
            self.environment = environment
            self.fileManager = fileManager
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
        let models: [String]
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
        let turns = try self.scanTurns(options: options, checkCancellation: checkCancellation)
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

    static func scanTurns(
        options: Options,
        checkCancellation: (() throws -> Void)?) throws -> [TurnRecord]
    {
        let root = self.sessionsRoot(options: options)
        let fileManager = options.fileManager
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var byEventID: [String: TurnRecord] = [:]
        var cwdBySession: [String: String] = [:]

        for case let url as URL in enumerator {
            try checkCancellation?()
            guard url.lastPathComponent == "updates.jsonl" else { continue }

            let sessionID = url.deletingLastPathComponent().lastPathComponent
            if cwdBySession[sessionID] == nil {
                cwdBySession[sessionID] = self.readCwd(
                    sessionDirectory: url.deletingLastPathComponent(),
                    fileManager: fileManager)
            }

            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                try checkCancellation?()
                guard line.contains("turn_completed") else { continue }
                guard let record = self.parseTurnLine(
                    String(line),
                    sessionID: sessionID,
                    cwd: cwdBySession[sessionID])
                else { continue }
                if byEventID[record.eventID] == nil {
                    byEventID[record.eventID] = record
                }
            }
        }

        return byEventID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.eventID < rhs.eventID
        }
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

        var models: [String] = []
        if let modelUsage = usage["modelUsage"] as? [String: Any] {
            models = modelUsage.keys.sorted()
        }

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
            models: models)
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
            let primaryModel = turn.models.first ?? "unknown"
            bucket.models.insert(primaryModel)
            var m = bucket.modelTotals[primaryModel] ?? (0, 0, false, 0)
            m.tokens += turn.totalTokens
            m.requests += max(turn.modelCalls, 1)
            if let cost = turn.costUSD {
                m.cost += cost
                m.sawCost = true
            }
            bucket.modelTotals[primaryModel] = m
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
            let model = turn.models.first ?? "unknown"
            var m = b.modelTotals[model] ?? (0, 0, false, 0)
            m.tokens += turn.totalTokens
            m.requests += max(turn.modelCalls, 1)
            if let cost = turn.costUSD {
                m.cost += cost
                m.sawCost = true
            }
            b.modelTotals[model] = m
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
            let model = turn.models.first ?? "unknown"
            var m = b.modelTotals[model] ?? (0, 0, false, 0)
            m.tokens += turn.totalTokens
            m.requests += max(turn.modelCalls, 1)
            if let cost = turn.costUSD {
                m.cost += cost
                m.sawCost = true
            }
            b.modelTotals[model] = m
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

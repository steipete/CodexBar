import Foundation

/// Reads Muse token usage from the durable session logs the CLI writes locally.
///
/// The Meta Model API publishes no usage or billing endpoint, and its documented `x-ratelimit-*`
/// headers ride only on billed inference responses. Muse Code does, however, record every model turn
/// to `~/.local/share/muse/sessions/<YYYY>/<MM>/<DD>/<session>/session.jsonl`, which gives CodexBar the
/// same local token history it already derives for Claude and Codex — with no network call, no
/// credential, and no Keychain access.
///
/// Token semantics were verified against 1,431 recorded events: `reasoning_tokens` is a subset of
/// `output_tokens`, and `cached_tokens`/`cache_read_tokens` are subsets of `input_tokens` (and are
/// always equal to each other). A turn therefore totals `input_tokens + output_tokens`; adding the
/// cache or reasoning counters would double-count, in one sampled turn by 41,201 tokens against a
/// 41,231-token input. The `automated_review_completed` shape carries its own `total_tokens`, which
/// matched `input + output` in every observed event.
enum MuseLocalUsageReader {
    enum Coverage: Sendable {
        case complete
        case partial
        case unavailable
    }

    struct DailyReportResult: Sendable {
        let report: CostUsageDailyReport
        let coverage: Coverage

        var isAvailable: Bool {
            self.coverage != .unavailable
        }

        var isComplete: Bool {
            self.coverage == .complete
        }
    }

    struct Context: Sendable {
        let sessionsRoot: URL

        init(environment: [String: String]) {
            let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".local/share", isDirectory: true)
            self.sessionsRoot = dataHome.appendingPathComponent("muse/sessions", isDirectory: true)
        }

        init(sessionsRoot: URL) {
            self.sessionsRoot = sessionsRoot
        }
    }

    struct Limits: Sendable {
        var files = 20000
        var lineBytes = 4 * 1024 * 1024
        var fileBytes = 256 * 1024 * 1024
        var totalBytes = 2 * 1024 * 1024 * 1024
        /// The bulk of a session log is `resource_usage_sampled` telemetry rather than model turns, so a
        /// busy tree reaches hundreds of megabytes. Day pruning and the file cache keep the usual scan
        /// far inside this ceiling; a first scan that does exhaust it keeps the files it finished, so
        /// the next refresh resumes instead of restarting.
        var duration: TimeInterval = 30
    }

    enum ScanFailure: Error {
        case exhausted
    }

    /// One budget per executor job, so a huge session tree degrades to partial coverage instead of
    /// blocking a refresh. The tree is routinely gigabytes across thousands of files.
    final class Budget {
        let limits: Limits
        private let cancellation: () throws -> Void
        private let clock: () -> TimeInterval
        private let started: TimeInterval
        private(set) var files = 0
        private(set) var bytes = 0

        init(
            limits: Limits,
            clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            cancellation: @escaping () throws -> Void)
        {
            self.limits = limits
            self.clock = clock
            self.started = clock()
            self.cancellation = cancellation
        }

        func check() throws {
            try self.cancellation()
            guard self.clock() - self.started < self.limits.duration else { throw ScanFailure.exhausted }
        }

        func chargeFile(_ count: Int) throws {
            try self.check()
            self.files += 1
            guard self.files <= self.limits.files else { throw ScanFailure.exhausted }
            let (total, overflow) = self.bytes.addingReportingOverflow(count)
            self.bytes = overflow ? Int.max : total
            guard self.bytes <= self.limits.totalBytes else { throw ScanFailure.exhausted }
        }
    }

    /// One recorded model turn.
    struct Event: Equatable {
        let id: String
        let recordedAt: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
    }

    /// Event kinds that carry a `usage` object. Only the two inference kinds are counted.
    ///
    /// `resource_usage_sampled` reuses the `usage` key for CPU and RSS telemetry, and
    /// `workflow_child_lifecycle` reports a child workflow's rollup whose turns are recorded on their
    /// own; counting either would corrupt the totals. Any other kind carrying token counts is unknown
    /// drift and downgrades coverage rather than being silently dropped.
    private static let countedKinds: Set<String> = ["model_completed", "automated_review_completed"]
    private static let ignoredKinds: Set<String> = ["resource_usage_sampled", "workflow_child_lifecycle"]

    /// Byte pattern every token-bearing record carries, used to skip JSON parsing on lines that
    /// cannot hold token counts.
    ///
    /// Session logs are dominated by `resource_usage_sampled` telemetry, whose `usage` object holds CPU
    /// and RSS gauges and no `input_tokens`: on a sampled 883 MB tree, 4,393 such records accompanied
    /// only 1,235 model turns. Filtering on the token field rather than on the known kinds keeps an
    /// unrecognized future kind reaching the parser, so drift still downgrades coverage.
    private static let tokenFieldPattern = Data("\"input_tokens\"".utf8)

    static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        sinceDayKey: String? = nil,
        cacheRoot: URL? = nil,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        var cache = MuseLocalUsageCacheIO.load(cacheRoot: cacheRoot, calendar: calendar)
        var isComplete = true
        var scannedPaths = Set<String>()
        var seenEventIDs = Set<String>()
        var days: [String: MuseLocalUsageCache.DayTotals] = [:]

        do {
            let discovery = try self.discoverSessionLogs(
                root: context.sessionsRoot, sinceDayKey: sinceDayKey, budget: budget)
            guard !discovery.urls.isEmpty || !discovery.isComplete else {
                return DailyReportResult(report: .init(data: [], summary: nil), coverage: .unavailable)
            }
            isComplete = discovery.isComplete

            for url in discovery.urls {
                try budget.check()
                scannedPaths.insert(url.path)
                let entry = try self.fileEntry(url: url, cache: cache, calendar: calendar, budget: budget)
                cache.files[url.path] = entry
                if !entry.isComplete { isComplete = false }
                self.accumulate(entry: entry, into: &days, seenEventIDs: &seenEventIDs)
            }
        } catch ScanFailure.exhausted {
            // Keep what was aggregated before the budget ran out; discarding it would report a busy
            // tree as "no usage" rather than as incomplete usage. The cache keeps the finished files so
            // the next refresh resumes instead of restarting.
            isComplete = false
        }

        // Drop files that disappeared, but only when the scan actually completed; a budget stop leaves
        // paths unvisited and must not evict them.
        if isComplete {
            for path in cache.files.keys where !scannedPaths.contains(path) {
                cache.files.removeValue(forKey: path)
            }
        }
        MuseLocalUsageCacheIO.save(cache: cache, cacheRoot: cacheRoot, calendar: calendar)
        return self.result(days: days, isComplete: isComplete)
    }

    /// Reuses a cached entry when the file's size and modification time both match, otherwise reparses.
    private static func fileEntry(
        url: URL,
        cache: MuseLocalUsageCache,
        calendar: Calendar,
        budget: Budget) throws -> MuseLocalUsageCache.FileEntry
    {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modifiedAtMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? -1
        if let cached = cache.files[url.path], cached.size == size, cached.modifiedAtMs == modifiedAtMs {
            return cached
        }

        let parsed = try self.parseSessionLog(url: url, budget: budget)
        let events = parsed.events.map { event in
            MuseLocalUsageCache.Event(
                id: event.id,
                day: CostUsageLocalDay.key(from: event.recordedAt, calendar: calendar),
                model: event.model,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens,
                cacheWriteTokens: event.cacheWriteTokens,
                reasoningTokens: event.reasoningTokens,
                totalTokens: event.totalTokens)
        }
        return MuseLocalUsageCache.FileEntry(
            size: size,
            modifiedAtMs: modifiedAtMs,
            events: events,
            isComplete: parsed.isComplete)
    }

    /// Adds a file's turns, skipping only the individual ids another log already contributed.
    private static func accumulate(
        entry: MuseLocalUsageCache.FileEntry,
        into days: inout [String: MuseLocalUsageCache.DayTotals],
        seenEventIDs: inout Set<String>)
    {
        for event in entry.events {
            // The record id is unique per durable event, so a turn copied into a second log is counted
            // once while that log's other turns still count.
            guard seenEventIDs.insert(event.id).inserted else { continue }
            var totals = days[event.day] ?? MuseLocalUsageCache.DayTotals()
            totals.inputTokens += event.inputTokens
            totals.outputTokens += event.outputTokens
            totals.cacheReadTokens += event.cacheReadTokens
            totals.cacheWriteTokens += event.cacheWriteTokens
            totals.reasoningTokens += event.reasoningTokens
            totals.totalTokens += event.totalTokens
            totals.requestCount += 1
            totals.models[event.model, default: 0] += event.totalTokens
            days[event.day] = totals
        }
    }

    private static func result(
        days: [String: MuseLocalUsageCache.DayTotals],
        isComplete: Bool) -> DailyReportResult
    {
        let daily = days.map { date, totals in
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheCreationTokens: totals.cacheWriteTokens,
                reasoningTokens: totals.reasoningTokens,
                totalTokens: totals.totalTokens,
                requestCount: totals.requestCount,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: totals.models.keys.sorted().map { model in
                    .init(modelName: model, costUSD: nil, totalTokens: totals.models[model], requestCount: nil)
                })
        }.sorted { $0.date < $1.date }
        return DailyReportResult(
            report: .init(
                data: daily,
                summary: daily.isEmpty ? nil : .init(
                    totalInputTokens: self.checkedSum(daily.compactMap(\.inputTokens)),
                    totalOutputTokens: self.checkedSum(daily.compactMap(\.outputTokens)),
                    totalTokens: self.checkedSum(daily.compactMap(\.totalTokens)),
                    totalCostUSD: nil)),
            coverage: isComplete ? .complete : .partial)
    }

    // MARK: - Discovery

    private struct Discovery {
        var urls: [URL] = []
        var isComplete = true
    }

    /// Enumerates `<root>/<YYYY>/<MM>/<DD>/<session>/session.jsonl`.
    ///
    /// Only the date-partitioned tree is walked. Sibling stores such as `.msp-view-v1` hold snapshots
    /// and indexes, never a session log, so skipping dot directories cannot lose a turn.
    private static func discoverSessionLogs(
        root: URL,
        sinceDayKey: String?,
        budget: Budget) throws -> Discovery
    {
        var discovery = Discovery()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return discovery
        }

        func children(of url: URL) throws -> [URL] {
            try budget.check()
            let contents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            guard let contents else {
                discovery.isComplete = false
                return []
            }
            return contents.sorted { $0.path < $1.path }
        }

        for year in try children(of: root) {
            for month in try children(of: year) {
                for day in try children(of: month) {
                    // The tree is partitioned as YYYY/MM/DD, so whole days outside the requested
                    // history window are skipped without opening a single log.
                    if let sinceDayKey, let dayKey = Self.dayKey(
                        year: year.lastPathComponent,
                        month: month.lastPathComponent,
                        day: day.lastPathComponent),
                        dayKey < sinceDayKey
                    {
                        continue
                    }
                    for session in try children(of: day) {
                        try budget.check()
                        let log = session.appendingPathComponent("session.jsonl", isDirectory: false)
                        if fileManager.fileExists(atPath: log.path) {
                            discovery.urls.append(log)
                        }
                    }
                }
            }
        }
        return discovery
    }

    /// Rebuilds the `YYYY-MM-DD` key from the tree's path components, or nil when they are not the
    /// expected numeric segments (in which case the directory is scanned rather than skipped).
    static func dayKey(year: String, month: String, day: String) -> String? {
        guard year.count == 4, month.count == 2, day.count == 2,
              year.allSatisfy(\.isNumber), month.allSatisfy(\.isNumber), day.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return "\(year)-\(month)-\(day)"
    }

    // MARK: - Parsing

    private struct ParsedLog {
        var events: [Event] = []
        var isComplete = true
    }

    private static func parseSessionLog(url: URL, budget: Budget) throws -> ParsedLog {
        var parsed = ParsedLog()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= budget.limits.fileBytes else {
            parsed.isComplete = false
            return parsed
        }
        try budget.chargeFile(size)

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            parsed.isComplete = false
            return parsed
        }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            try budget.check()
            guard line.count <= budget.limits.lineBytes else {
                parsed.isComplete = false
                continue
            }
            let lineData = Data(line)
            guard Self.mayContainTokenCounts(lineData) else { continue }
            switch self.parseLine(lineData) {
            case let .event(event):
                parsed.events.append(event)
            case .ignored:
                continue
            case .unrecognized:
                parsed.isComplete = false
            }
        }
        return parsed
    }

    /// Cheap rejection for lines that cannot carry token counts.
    static func mayContainTokenCounts(_ data: Data) -> Bool {
        data.range(of: self.tokenFieldPattern) != nil
    }

    enum LineResult: Equatable {
        case event(Event)
        case ignored
        case unrecognized
    }

    static func parseLine(_ data: Data) -> LineResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unrecognized
        }
        // Fail closed on a schema the shapes below were not verified against.
        guard object["schema_version"] as? Int == 1,
              object["record_type"] as? String == "event",
              object["payload_type"] as? String == "runtime.session",
              object["payload_schema_version"] as? Int == 1
        else {
            return .ignored
        }
        guard let payload = object["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              let usage = event["usage"] as? [String: Any]
        else {
            return .ignored
        }

        let kind = event["kind"] as? String ?? ""
        if self.ignoredKinds.contains(kind) { return .ignored }
        guard self.countedKinds.contains(kind) else {
            // An unknown kind with token counts is drift worth surfacing as partial coverage.
            return usage["input_tokens"] is Int ? .unrecognized : .ignored
        }

        guard let id = object["id"] as? String, !id.isEmpty,
              let recordedAt = object["recorded_at"] as? Int,
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int,
              input >= 0, output >= 0,
              let total = self.checkedAdd(input, output)
        else {
            return .unrecognized
        }

        // `model` is a plain id for a model turn and a descriptor object for an automated review.
        let model: String = if let name = event["model"] as? String {
            name
        } else if let descriptor = event["model"] as? [String: Any],
                  let name = descriptor["model_id"] as? String
        {
            name
        } else {
            "unknown"
        }

        // Recorded in microseconds since the epoch.
        let timestamp = Date(timeIntervalSince1970: Double(recordedAt) / 1_000_000)
        let cacheRead = max(0, usage["cache_read_tokens"] as? Int ?? usage["cached_input_tokens"] as? Int ?? 0)
        return .event(Event(
            id: id,
            recordedAt: timestamp,
            model: self.normalizeModelID(model),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: max(0, usage["cache_write_tokens"] as? Int ?? 0),
            reasoningTokens: max(0, usage["reasoning_tokens"] as? Int ?? 0),
            totalTokens: total))
    }

    // MARK: - Aggregation

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard let next = self.checkedAdd(total, value) else { return nil }
            total = next
        }
        return total
    }
}

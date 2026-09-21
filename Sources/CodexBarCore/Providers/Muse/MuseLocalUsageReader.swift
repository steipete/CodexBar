import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads Muse token usage from the durable session logs the CLI writes locally.
///
/// The subscription quota response contains no historical token counts or billing amounts.
/// Muse Code records model turns
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
            self.coverage == .complete || !self.report.data.isEmpty
        }

        var isComplete: Bool {
            self.coverage == .complete
        }
    }

    struct Context: Sendable {
        let sessionsRoot: URL
        let defaultCacheRoot: URL

        init(environment: [String: String]) {
            let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".local/share", isDirectory: true)
            let override = environment["MUSE_SESSIONS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sessionsRoot = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? dataHome.appendingPathComponent("muse/sessions", isDirectory: true)
            #if os(macOS)
            let defaultCache = home.appendingPathComponent("Library/Caches", isDirectory: true)
            #else
            let defaultCache = home.appendingPathComponent(".cache", isDirectory: true)
            #endif
            self.defaultCacheRoot = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .map { $0.appendingPathComponent("CodexBar", isDirectory: true) }
                ?? defaultCache.appendingPathComponent("CodexBar", isDirectory: true)
        }

        init(sessionsRoot: URL) {
            self.sessionsRoot = sessionsRoot
            self.defaultCacheRoot = sessionsRoot.appendingPathComponent(".codexbar-cache", isDirectory: true)
        }
    }

    struct Limits: Sendable {
        var files = 20000
        var lineBytes = 4 * 1024 * 1024
        var fileBytes = 256 * 1024 * 1024
        var totalBytes = 2 * 1024 * 1024 * 1024
        var retainedEventBytes = 16 * 1024 * 1024
        /// The bulk of a session log is `resource_usage_sampled` telemetry rather than model turns, so a
        /// busy tree reaches hundreds of megabytes. Completed files are cached between scans;
        /// interrupted files restart on the next refresh rather than claiming within-file progress.
        var duration: TimeInterval = 30
    }

    enum ScanFailure: Error {
        case exhausted
    }

    private struct DayRange {
        let since: String?
        let until: String?

        func contains(_ day: String) -> Bool {
            (self.since.map { day >= $0 } ?? true) && (self.until.map { day <= $0 } ?? true)
        }
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
        private var retainedEventBytes = 0

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

        func chargeEvent(id: String, model: String) throws {
            try self.check()
            let strings = id.utf8.count.addingReportingOverflow(model.utf8.count)
            let escaped = strings.partialValue.multipliedReportingOverflow(by: 6)
            let event = escaped.partialValue.addingReportingOverflow(512)
            let retained = self.retainedEventBytes.addingReportingOverflow(event.partialValue)
            guard !strings.overflow, !escaped.overflow, !event.overflow, !retained.overflow,
                  retained.partialValue <= self.limits.retainedEventBytes
            else { throw ScanFailure.exhausted }
            self.retainedEventBytes = retained.partialValue
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
    private static let ignoredKinds: Set<String> = [
        "resource_usage_sampled", "workflow_child_lifecycle", "goal_usage_attribution",
    ]

    /// Unknown event kinds with token fields indicate schema drift even when their usage shape changed.
    private static let tokenFieldPatterns = [
        "input_tokens", "output_tokens", "total_tokens", "cache_read_tokens", "cached_input_tokens", "cached_tokens",
        "cache_write_tokens", "reasoning_tokens",
    ].map { Data("\"\($0)\"".utf8) }

    static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil,
        cacheRoot: URL,
        forceRescan: Bool = false,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        let range = DayRange(since: sinceDayKey, until: untilDayKey)
        var cache = MuseLocalUsageCacheIO.load(
            sessionsRoot: context.sessionsRoot,
            cacheRoot: cacheRoot,
            calendar: calendar,
            sinceDayKey: sinceDayKey,
            untilDayKey: untilDayKey)
        if forceRescan { cache.files = [:] }
        var isComplete = true
        var scannedPaths = Set<String>()
        var seenEvents: [String: MuseLocalUsageCache.Event] = [:]
        var days: [String: MuseLocalUsageCache.DayTotals] = [:]

        do {
            let discovery = try self.discoverSessionLogs(root: context.sessionsRoot, budget: budget) { url in
                scannedPaths.insert(url.path)
                let entry = try self.fileEntry(
                    url: url,
                    cache: cache,
                    calendar: calendar,
                    budget: budget,
                    range: range)
                cache.files[url.path] = entry
                if !entry.isComplete { isComplete = false }
                if !self.accumulate(
                    entry: entry,
                    range: range,
                    into: &days,
                    seenEvents: &seenEvents)
                {
                    isComplete = false
                }
            }
            guard discovery.fileCount > 0 || !discovery.isComplete else {
                return DailyReportResult(report: .init(data: [], summary: nil), coverage: .unavailable)
            }
            isComplete = isComplete && discovery.isComplete
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
        MuseLocalUsageCacheIO.save(
            cache: cache,
            sessionsRoot: context.sessionsRoot,
            cacheRoot: cacheRoot,
            calendar: calendar,
            sinceDayKey: sinceDayKey,
            untilDayKey: untilDayKey)
        return self.result(days: days, isComplete: isComplete)
    }

    /// Reuses only completed files whose identity and precise metadata still match.
    private static func fileEntry(
        url: URL,
        cache: MuseLocalUsageCache,
        calendar: Calendar,
        budget: Budget,
        range: DayRange) throws -> MuseLocalUsageCache.FileEntry
    {
        guard let stamp = MuseLocalUsageCache.FileStamp.read(at: url) else {
            return .init(stamp: nil, events: [], isComplete: false)
        }
        if let cached = cache.files[url.path], cached.stamp == stamp, cached.isComplete,
           cached.events.allSatisfy(\.isValid)
        {
            return cached
        }

        let parsed = try self.parseSessionLog(
            url: url,
            stamp: stamp,
            budget: budget,
            calendar: calendar,
            range: range)
        guard MuseLocalUsageCache.FileStamp.read(at: url) == stamp else {
            return .init(stamp: nil, events: [], isComplete: false)
        }
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
            stamp: stamp,
            events: events,
            isComplete: parsed.isComplete)
    }

    /// Adds a file's turns, skipping only the individual ids another log already contributed.
    private static func accumulate(
        entry: MuseLocalUsageCache.FileEntry,
        range: DayRange,
        into days: inout [String: MuseLocalUsageCache.DayTotals],
        seenEvents: inout [String: MuseLocalUsageCache.Event]) -> Bool
    {
        var complete = true
        for event in entry.events {
            guard range.contains(event.day) else { continue }
            // The record id is unique per durable event, so a turn copied into a second log is counted
            // once while that log's other turns still count.
            if let previous = seenEvents[event.id] {
                if previous != event { complete = false }
                continue
            }
            seenEvents[event.id] = event
            var totals = days[event.day] ?? MuseLocalUsageCache.DayTotals()
            guard let input = self.checkedAdd(totals.inputTokens, event.inputTokens),
                  let output = self.checkedAdd(totals.outputTokens, event.outputTokens),
                  let cacheRead = self.checkedAdd(totals.cacheReadTokens, event.cacheReadTokens),
                  let cacheWrite = self.checkedAdd(totals.cacheWriteTokens, event.cacheWriteTokens),
                  let reasoning = self.checkedAdd(totals.reasoningTokens, event.reasoningTokens),
                  let total = self.checkedAdd(totals.totalTokens, event.totalTokens),
                  let requests = self.checkedAdd(totals.requestCount, 1),
                  let model = self.checkedAdd(totals.models[event.model, default: 0], event.totalTokens)
            else {
                complete = false
                continue
            }
            totals.inputTokens = input
            totals.outputTokens = output
            totals.cacheReadTokens = cacheRead
            totals.cacheWriteTokens = cacheWrite
            totals.reasoningTokens = reasoning
            totals.totalTokens = total
            totals.requestCount = requests
            totals.models[event.model] = model
            days[event.day] = totals
        }
        return complete
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
        let input = self.checkedSum(daily.compactMap(\.inputTokens))
        let output = self.checkedSum(daily.compactMap(\.outputTokens))
        let total = self.checkedSum(daily.compactMap(\.totalTokens))
        let complete = isComplete && input != nil && output != nil && total != nil
        return DailyReportResult(
            report: .init(
                data: daily,
                summary: daily.isEmpty ? nil : .init(
                    totalInputTokens: input,
                    totalOutputTokens: output,
                    totalTokens: total,
                    totalCostUSD: nil)),
            coverage: complete ? .complete : .partial)
    }

    // MARK: - Discovery

    private struct Discovery {
        var fileCount = 0
        var isComplete = true
    }

    /// Enumerates `<root>/<YYYY>/<MM>/<DD>/<session>/session.jsonl`.
    ///
    /// Only the date-partitioned tree is walked. Sibling stores such as `.msp-view-v1` hold snapshots
    /// and indexes, never a session log, so skipping dot directories cannot lose a turn.
    private static func discoverSessionLogs(
        root: URL,
        budget: Budget,
        visit: (URL) throws -> Void) throws -> Discovery
    {
        var discovery = Discovery()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return discovery
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in discovery.isComplete = false; return true })
        else { return Discovery(isComplete: false) }
        while let url = enumerator.nextObject() as? URL {
            try budget.check()
            let depth = enumerator.level
            if depth >= 5 { enumerator.skipDescendants() }
            guard depth == 5, url.lastPathComponent == "session.jsonl" else { continue }
            discovery.fileCount += 1
            // Process immediately so a discovery timeout preserves completed work. Only parsing
            // uncached files consumes the file budget; a warm scan can reach later sessions.
            try visit(url)
        }
        return discovery
    }

    // MARK: - Parsing

    private struct ParsedLog {
        var events: [Event] = []
        var isComplete = true
    }

    private static func parseSessionLog(
        url: URL,
        stamp: MuseLocalUsageCache.FileStamp,
        budget: Budget,
        calendar: Calendar,
        range: DayRange) throws -> ParsedLog
    {
        guard stamp.size <= budget.limits.fileBytes, let size = Int(exactly: stamp.size) else {
            return ParsedLog(isComplete: false)
        }
        try budget.chargeFile(size)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) }
        guard descriptor >= 0 else { return ParsedLog(isComplete: false) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard MuseLocalUsageCache.FileStamp.read(descriptor: descriptor) == stamp else {
            return ParsedLog(isComplete: false)
        }
        var parsed = ParsedLog()
        var line = Data()
        var oversized = false
        var consumed = 0
        func consumeLine() throws {
            defer { line.removeAll(keepingCapacity: true); oversized = false }
            guard !oversized else { parsed.isComplete = false; return }
            guard !line.isEmpty else { return }
            switch self.parseLine(line) {
            case let .event(event):
                let day = CostUsageLocalDay.key(from: event.recordedAt, calendar: calendar)
                guard range.contains(day) else { return }
                try budget.chargeEvent(id: event.id, model: event.model)
                parsed.events.append(event)
            case .ignored: break
            case .unrecognized: parsed.isComplete = false
            }
        }
        while true {
            try budget.check()
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(65536, size - consumed + 1)) ?? Data()
            } catch {
                return ParsedLog(isComplete: false)
            }
            if chunk.isEmpty { break }
            consumed += chunk.count
            guard consumed <= size else { return ParsedLog(isComplete: false) }
            for byte in chunk {
                if byte == 10 {
                    try consumeLine()
                } else if line.count < budget.limits.lineBytes {
                    line.append(byte)
                } else {
                    oversized = true
                }
            }
        }
        if !line.isEmpty || oversized { try consumeLine() }
        guard consumed == size else { return ParsedLog(isComplete: false) }
        return parsed
    }

    /// Detects token fields on otherwise unknown event kinds.
    static func mayContainTokenCounts(_ data: Data) -> Bool {
        self.tokenFieldPatterns.contains { data.range(of: $0) != nil }
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
        guard self.integer(object["schema_version"]) == 1,
              object["record_type"] as? String == "event",
              object["payload_type"] as? String == "runtime.session",
              self.integer(object["payload_schema_version"]) == 1
        else {
            return .unrecognized
        }
        guard let payload = object["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any]
        else {
            return .unrecognized
        }

        let kind = event["kind"] as? String ?? ""
        if self.ignoredKinds.contains(kind) { return .ignored }
        guard self.countedKinds.contains(kind) else {
            // An unknown kind with token counts is drift worth surfacing as partial coverage.
            return self.mayContainTokenCounts(data) ? .unrecognized : .ignored
        }
        guard let usage = event["usage"] as? [String: Any] else { return .unrecognized }

        guard let id = object["id"] as? String, !id.isEmpty,
              let recordedAt = self.integer(object["recorded_at"]),
              recordedAt > 0, recordedAt <= 253_402_300_799_999_999,
              let input = self.integer(usage["input_tokens"]),
              let output = self.integer(usage["output_tokens"]),
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
        guard let cacheRead = self.counter(usage, keys: ["cache_read_tokens", "cached_input_tokens", "cached_tokens"]),
              let cacheWrite = self.counter(usage, keys: ["cache_write_tokens"]),
              let reasoning = self.counter(usage, keys: ["reasoning_tokens"]),
              cacheRead <= input, cacheWrite <= input, reasoning <= output,
              usage["total_tokens"] == nil || self.integer(usage["total_tokens"]) == total
        else { return .unrecognized }
        return .event(Event(
            id: id,
            recordedAt: timestamp,
            model: self.normalizeModelID(model),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            totalTokens: total))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func counter(_ usage: [String: Any], keys: [String]) -> Int? {
        var value: Int?
        for key in keys {
            guard let raw = usage[key] else { continue }
            guard let parsed = self.integer(raw), parsed >= 0, value == nil || value == parsed else { return nil }
            value = parsed
        }
        return value ?? 0
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

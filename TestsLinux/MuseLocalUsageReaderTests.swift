import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Muse records every model turn to `~/.local/share/muse/sessions/<Y>/<M>/<D>/<session>/session.jsonl`.
/// These fixtures mirror the record shapes observed in real logs, including the two `usage` payloads
/// that must never be counted.
struct MuseLocalUsageReaderTests {
    // MARK: - Fixtures

    private static func record(
        id: String,
        recordedAt: Int,
        kind: String,
        usage: String,
        model: String? = "\"muse-example-model\"") -> String
    {
        let modelField = model.map { "\"model\":\($0)," } ?? ""
        return """
        {"schema_version":1,"id":"\(id)","stream":{"kind":"session","id":"s1"},"sequence":1,\
        "recorded_at":\(recordedAt),"record_type":"event","durability":"durable",\
        "payload_type":"runtime.session","payload_schema_version":1,\
        "payload":{"kind":"run","run_id":"r1","event":{"kind":"\(kind)",\(modelField)"usage":\(usage)}}}
        """
    }

    private static let modelTurnUsage = """
    {"input_tokens":34893,"output_tokens":229,"cached_tokens":0,"cache_write_tokens":0,\
    "cache_read_tokens":0,"reasoning_tokens":52}
    """

    /// A real turn where the cache counters nearly equal the input; summing them would double-count.
    private static let cachedTurnUsage = """
    {"input_tokens":41231,"output_tokens":100,"cached_tokens":41201,"cache_write_tokens":0,\
    "cache_read_tokens":41201,"reasoning_tokens":44}
    """

    private static let resourceSampleUsage = """
    {"cpu_children_ms":12,"cpu_self_ms":8,"fds_open":30,"procs_live":2,\
    "rss_self_bytes":123456,"rss_tree_bytes":234567,"unified_exec_live_sessions":1}
    """

    /// 2026-08-31 12:00:00 UTC in microseconds.
    private static let baseMicros = 1_788_177_600_000_000

    private static func makeTree(
        _ logs: [(day: String, session: String, lines: [String])]) throws -> URL
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-reader-tests-\(UUID().uuidString)", isDirectory: true)
        for log in logs {
            let parts = log.day.split(separator: "-").map(String.init)
            let dir = root
                .appendingPathComponent(parts[0], isDirectory: true)
                .appendingPathComponent(parts[1], isDirectory: true)
                .appendingPathComponent(parts[2], isDirectory: true)
                .appendingPathComponent(log.session, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try log.lines.joined(separator: "\n").write(
                to: dir.appendingPathComponent("session.jsonl"),
                atomically: true,
                encoding: .utf8)
        }
        return root
    }

    private static func read(
        root: URL,
        sinceDayKey: String? = nil,
        cacheRoot: URL? = nil) throws -> MuseLocalUsageReader.DailyReportResult
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root),
            calendar: calendar,
            sinceDayKey: sinceDayKey,
            cacheRoot: cacheRoot ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("muse-cache-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: - Token semantics

    /// Verified across 1,431 recorded events: reasoning is a subset of output and the cache counters
    /// are subsets of input, so a turn totals input + output.
    @Test
    func `a turn totals input plus output without double-counting cache or reasoning`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [Self.record(
                id: "e1",
                recordedAt: Self.baseMicros,
                kind: "model_completed",
                usage: Self.cachedTurnUsage)])])
        let result = try Self.read(root: root)

        #expect(result.coverage == .complete)
        let entry = try #require(result.report.data.first)
        #expect(entry.date == "2026-08-31")
        #expect(entry.inputTokens == 41231)
        #expect(entry.outputTokens == 100)
        // 41,231 + 100 — not 41,231 + 100 + 41,201 + 44.
        #expect(entry.totalTokens == 41331)
        // The cache and reasoning counters are still reported, just never added to the total.
        #expect(entry.cacheReadTokens == 41201)
        #expect(entry.reasoningTokens == 44)
        #expect(entry.requestCount == 1)
        #expect(entry.costUSD == nil)
    }

    /// `resource_usage_sampled` reuses the `usage` key for CPU and RSS telemetry.
    @Test
    func `resource telemetry is never counted as tokens`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [
                Self.record(
                    id: "e1",
                    recordedAt: Self.baseMicros,
                    kind: "model_completed",
                    usage: Self.modelTurnUsage),
                Self.record(
                    id: "e2",
                    recordedAt: Self.baseMicros,
                    kind: "resource_usage_sampled",
                    usage: Self.resourceSampleUsage,
                    model: nil),
            ])])
        let result = try Self.read(root: root)

        #expect(result.coverage == .complete)
        let entry = try #require(result.report.data.first)
        #expect(entry.requestCount == 1)
        #expect(entry.totalTokens == 35122)
    }

    /// A child workflow's rollup repeats turns that are recorded on their own.
    @Test
    func `child workflow rollups are not counted twice`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [
                Self.record(
                    id: "e1",
                    recordedAt: Self.baseMicros,
                    kind: "model_completed",
                    usage: Self.modelTurnUsage),
                Self.record(
                    id: "e2",
                    recordedAt: Self.baseMicros,
                    kind: "workflow_child_lifecycle",
                    usage: Self.modelTurnUsage,
                    model: nil),
            ])])
        let result = try Self.read(root: root)
        #expect(result.report.data.first?.requestCount == 1)
    }

    @Test
    func `automated review turns are counted and use their descriptor model id`() throws {
        let usage = """
        {"input_tokens":900,"output_tokens":100,"cached_input_tokens":300,\
        "non_cached_input_tokens":600,"reasoning_tokens":40,"total_tokens":1000}
        """
        let model = """
        {"provider_id":"meta","model_id":"muse-example-model","reasoning_effort":"low"}
        """
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [Self.record(
                id: "e1",
                recordedAt: Self.baseMicros,
                kind: "automated_review_completed",
                usage: usage,
                model: model)])])
        let result = try Self.read(root: root)

        let entry = try #require(result.report.data.first)
        #expect(entry.totalTokens == 1000)
        #expect(entry.cacheReadTokens == 300)
        #expect(entry.modelBreakdowns?.first?.modelName == "muse-example-model")
    }

    // MARK: - Identity and drift

    @Test
    func `a turn copied into a second log is counted once`() throws {
        let line = Self.record(
            id: "shared-event",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.modelTurnUsage)
        let root = try Self.makeTree([
            (day: "2026-08-31", session: "sess-1", lines: [line]),
            (day: "2026-08-31", session: "sess-2", lines: [line]),
        ])
        let result = try Self.read(root: root)
        #expect(result.report.data.first?.requestCount == 1)
    }

    /// A second log may hold one already-counted turn alongside unique ones. Dropping the whole file
    /// on that overlap would silently under-report; only the repeated id may be skipped.
    @Test
    func `a partially overlapping log keeps its unique turns`() throws {
        let shared = Self.record(
            id: "shared-event",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.modelTurnUsage)
        let unique = Self.record(
            id: "unique-event",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.cachedTurnUsage)
        let root = try Self.makeTree([
            (day: "2026-08-31", session: "sess-1", lines: [shared]),
            (day: "2026-08-31", session: "sess-2", lines: [shared, unique]),
        ])
        let result = try Self.read(root: root)

        let entry = try #require(result.report.data.first)
        // The shared turn counts once; the second log's unique turn is still counted.
        #expect(entry.requestCount == 2)
        #expect(entry.totalTokens == 76453)
    }

    @Test
    func `an unknown token bearing schema reports incomplete history`() throws {
        let line = Self.record(
            id: "e1",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.modelTurnUsage)
            .replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
        let root = try Self.makeTree([(day: "2026-08-31", session: "sess-1", lines: [line])])
        let result = try Self.read(root: root)
        #expect(result.report.data.isEmpty)
        #expect(result.coverage == .partial)
        #expect(!result.isAvailable)
    }

    /// An unrecognized kind carrying token counts is drift, and must downgrade coverage instead of
    /// silently vanishing from the totals.
    @Test
    func `an unknown token-bearing kind downgrades coverage`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [
                Self.record(
                    id: "e1",
                    recordedAt: Self.baseMicros,
                    kind: "model_completed",
                    usage: Self.modelTurnUsage),
                Self.record(
                    id: "e2",
                    recordedAt: Self.baseMicros,
                    kind: "future_inference_kind",
                    usage: Self.modelTurnUsage),
            ])])
        let result = try Self.read(root: root)
        #expect(result.coverage == .partial)
        #expect(result.report.data.first?.requestCount == 1)
    }

    @Test
    func `an absent sessions tree reports unavailable rather than zero usage`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-missing-\(UUID().uuidString)", isDirectory: true)
        let result = try Self.read(root: root)
        #expect(result.coverage == .unavailable)
        #expect(!result.isAvailable)
    }

    // MARK: - Windowing and cache

    @Test
    func `days outside the requested window are skipped`() throws {
        let root = try Self.makeTree([
            (day: "2026-08-20", session: "old", lines: [Self.record(
                id: "old-1",
                recordedAt: Self.baseMicros - 950_400_000_000,
                kind: "model_completed",
                usage: Self.modelTurnUsage)]),
            (day: "2026-08-31", session: "new", lines: [Self.record(
                id: "new-1",
                recordedAt: Self.baseMicros,
                kind: "model_completed",
                usage: Self.modelTurnUsage)]),
        ])
        let result = try Self.read(root: root, sinceDayKey: "2026-08-25")
        #expect(result.report.data.map(\.date) == ["2026-08-31"])
    }

    @Test
    func `a continuing session in an old directory contributes its current event date`() throws {
        let root = try Self.makeTree([(
            day: "2025-01-01", session: "long-lived", lines: [Self.record(
                id: "current", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)])])
        let result = try Self.read(root: root, sinceDayKey: "2026-08-25")
        #expect(result.coverage == .complete)
        #expect(result.report.data.map(\.date) == ["2026-08-31"])
        #expect(result.report.summary?.totalTokens == 35122)
    }

    @Test
    func `boolean fractional and contradictory counters are rejected`() {
        for usage in [
            #"{"input_tokens":true,"output_tokens":2}"#,
            #"{"input_tokens":1.5,"output_tokens":2}"#,
            #"{"input_tokens":10,"output_tokens":2,"cached_tokens":true}"#,
            #"{"input_tokens":10,"output_tokens":2,"cached_tokens":3,"cache_read_tokens":4}"#,
            #"{"input_tokens":10,"output_tokens":2,"reasoning_tokens":3}"#,
            #"{"input_tokens":10,"output_tokens":2,"total_tokens":20}"#,
        ] {
            let line = Self.record(id: "invalid", recordedAt: Self.baseMicros, kind: "model_completed", usage: usage)
            #expect(MuseLocalUsageReader.parseLine(Data(line.utf8)) == .unrecognized)
        }
    }

    @Test
    func `overflow preserves a known subtotal with partial coverage`() throws {
        let usage = "{\"input_tokens\":\(Int.max),\"output_tokens\":0}"
        let root = try Self.makeTree([(
            day: "2026-08-31", session: "huge", lines: [
                Self.record(id: "first", recordedAt: Self.baseMicros, kind: "model_completed", usage: usage),
                Self.record(id: "second", recordedAt: Self.baseMicros, kind: "model_completed", usage: usage),
            ])])
        let result = try Self.read(root: root)
        #expect(result.coverage == .partial)
        #expect(result.report.data.first?.totalTokens == Int.max)
        #expect(result.report.data.first?.costUSD == nil)
        #expect(result.report.summary?.totalCostUSD == nil)
    }

    @Test
    func `same size and modification time rotation invalidates the file cache`() throws {
        let line = Self.record(
            id: "first", recordedAt: Self.baseMicros, kind: "model_completed",
            usage: #"{"input_tokens":10,"output_tokens":20}"#)
        let root = try Self.makeTree([(day: "2026-08-31", session: "rotate", lines: [line])])
        let cache = root.appendingPathComponent("cache")
        let url = root.appendingPathComponent("2026/08/31/rotate/session.jsonl")
        let before = try Self.read(root: root, cacheRoot: cache)
        let modified = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
        let replacement = line.replacingOccurrences(of: "\"input_tokens\":10", with: "\"input_tokens\":50")
        #expect(replacement.utf8.count == line.utf8.count)
        try replacement.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let after = try Self.read(root: root, cacheRoot: cache)
        #expect(before.report.summary?.totalTokens == 30)
        #expect(after.report.summary?.totalTokens == 70)
    }

    @Test
    func `cache scope follows the selected session root`() throws {
        let first = try Self.makeTree([(day: "2026-08-31", session: "a", lines: [Self.record(
            id: "same-id", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)])])
        let second = try Self.makeTree([(day: "2026-08-31", session: "a", lines: [Self.record(
            id: "same-id", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.cachedTurnUsage)])])
        let cache = first.appendingPathComponent("cache")
        #expect(try Self.read(root: first, cacheRoot: cache).report.summary?.totalTokens == 35122)
        #expect(try Self.read(root: second, cacheRoot: cache).report.summary?.totalTokens == 41331)
        #expect(try Self.read(root: first, cacheRoot: cache).report.summary?.totalTokens == 35122)
    }

    /// A second scan must reuse the cache and still report the same totals.
    @Test
    func `a warm scan reproduces the cold scan totals`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [
                Self.record(
                    id: "e1",
                    recordedAt: Self.baseMicros,
                    kind: "model_completed",
                    usage: Self.modelTurnUsage),
                Self.record(
                    id: "e2",
                    recordedAt: Self.baseMicros,
                    kind: "model_completed",
                    usage: Self.cachedTurnUsage),
            ])])
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-cache-\(UUID().uuidString)", isDirectory: true)

        let cold = try Self.read(root: root, cacheRoot: cacheRoot)
        let warm = try Self.read(root: root, cacheRoot: cacheRoot)

        #expect(cold.coverage == .complete)
        #expect(warm.coverage == .complete)
        #expect(cold.report.data.first?.totalTokens == 76453)
        #expect(warm.report.data.first?.totalTokens == cold.report.data.first?.totalTokens)
        #expect(warm.report.data.first?.requestCount == 2)
    }

    /// Appending to a log changes its size and mtime, so the cached entry must be replaced.
    @Test
    func `an appended log is rescanned rather than served from cache`() throws {
        let root = try Self.makeTree([(
            day: "2026-08-31",
            session: "sess-1",
            lines: [Self.record(
                id: "e1",
                recordedAt: Self.baseMicros,
                kind: "model_completed",
                usage: Self.modelTurnUsage)])])
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-cache-\(UUID().uuidString)", isDirectory: true)
        let cold = try Self.read(root: root, cacheRoot: cacheRoot)
        #expect(cold.report.data.first?.requestCount == 1)

        let log = root.appendingPathComponent("2026/08/31/sess-1/session.jsonl")
        let appended = try String(contentsOf: log, encoding: .utf8) + "\n" + Self.record(
            id: "e2",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.cachedTurnUsage)
        try appended.write(to: log, atomically: true, encoding: .utf8)

        let warm = try Self.read(root: root, cacheRoot: cacheRoot)
        #expect(warm.report.data.first?.requestCount == 2)
        #expect(warm.report.data.first?.totalTokens == 76453)
    }

    @Test
    func `unknown token bearing kinds can be recognized as drift`() {
        #expect(MuseLocalUsageReader.mayContainTokenCounts(Data(#"{"usage":{"input_tokens":1}}"#.utf8)))
        #expect(MuseLocalUsageReader.mayContainTokenCounts(
            Data(#"{"kind":"future_kind","usage":{"input_tokens":1}}"#.utf8)))
        #expect(!MuseLocalUsageReader.mayContainTokenCounts(
            Data(#"{"usage":{"cpu_self_ms":8,"rss_self_bytes":1}}"#.utf8)))
    }

    @Test(arguments: ["text", "null", "string", "array", "missing", "moved", "payload", "event"])
    func `corrupt or changed usage stays unavailable and preserves valid subtotals`(shape: String) async throws {
        let valid = Self.record(
            id: "valid", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)
        var object = try #require(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        var event = try #require(payload["event"] as? [String: Any])
        switch shape {
        case "null": event["usage"] = NSNull()
        case "string": event["usage"] = "changed"
        case "array": event["usage"] = try [#require(event["usage"])]
        case "missing": event.removeValue(forKey: "usage")
        case "moved": event["metrics"] = event.removeValue(forKey: "usage")
        default: break
        }
        payload["event"] = shape == "event" ? [event] : event
        object["payload"] = shape == "payload" ? [payload] : payload
        let malformed = try shape == "text" ? "not JSON" : String(
            decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        for knownUsage in [false, true] {
            let root = try Self.makeTree([(
                day: "2026-08-31", session: "fixture", lines: (knownUsage ? [valid] : []) + [malformed])])
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = root.appendingPathComponent("cache")
            let report = try Self.read(root: root, cacheRoot: cache)
            #expect(report.coverage == .partial)
            #expect(report.isAvailable == knownUsage)
            #expect(report.report.summary?.totalTokens == (knownUsage ? 35122 : nil))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .muse, environment: ["HOME": root.path, "MUSE_SESSIONS_DIR": root.path],
                now: Date(timeIntervalSince1970: Double(Self.baseMicros) / 1_000_000), historyDays: 1,
                scannerOptions: .init(cacheRoot: cache, calendar: calendar),
                modelsDevClient: ModelsDevClient(transport: RejectMusePricingTransport()))
            #expect(snapshot.sessionTokens == (knownUsage ? 35122 : nil))
            #expect(snapshot.sessionCostUSD == nil)
            #expect(snapshot.last30DaysCostUSD == nil)
            #expect(snapshot.meteredCostUSD == nil)
        }
    }

    @Test
    func `completed files do not consume later refresh file budgets`() throws {
        let root = try Self.makeTree(["a", "b", "c"].map { name in
            (day: "2026-08-31", session: name, lines: [Self.record(
                id: name, recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)])
        })
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        var limits = MuseLocalUsageReader.Limits()
        limits.files = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache, limits: limits)
        let second = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache, limits: limits)
        #expect(first.coverage == .partial)
        #expect(first.report.summary?.totalTokens == 70244)
        #expect(second.coverage == .complete)
        #expect(second.report.summary?.totalTokens == 105_366)
    }

    @Test
    func `timezone changes rebucket cached turns and truncation removes old totals`() throws {
        let timestamp = Self.baseMicros - 9 * 60 * 60 * 1_000_000
        let first = Self.record(
            id: "first", recordedAt: timestamp, kind: "model_completed", usage: Self.modelTurnUsage)
        let second = Self.record(
            id: "second", recordedAt: timestamp, kind: "model_completed", usage: Self.modelTurnUsage)
        let root = try Self.makeTree([(day: "2026-08-31", session: "session", lines: [first, second])])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let utc = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache)
        #expect(utc.report.data.first?.date == "2026-08-31")
        #expect(utc.report.summary?.totalTokens == 70244)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let local = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache)
        #expect(local.report.data.first?.date == "2026-08-30")
        try first.write(
            to: root.appendingPathComponent("2026/08/31/session/session.jsonl"), atomically: false, encoding: .utf8)
        let truncated = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache)
        #expect(truncated.coverage == .complete)
        #expect(truncated.report.summary?.totalTokens == 35122)
        #expect(truncated.report.data.first?.date == "2026-08-30")
    }

    @Test
    func `validated events without token usage establish an empty history`() throws {
        let root = try Self.makeTree([(day: "2026-08-31", session: "session", lines: [
            Self.record(id: "start", recordedAt: Self.baseMicros, kind: "session_started", usage: "{}"),
            Self.record(id: "sample", recordedAt: Self.baseMicros, kind: "resource_usage_sampled", usage: "{}"),
        ])])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try Self.read(root: root)
        #expect(result.coverage == .complete)
        #expect(result.isAvailable)
        #expect(result.report.data.isEmpty)
    }

    @Test
    func `dense event retention stops before allocating an unbounded scan cache`() throws {
        let root = try Self.makeTree(["a", "b"].map { name in
            (day: "2026-08-31", session: name, lines: [Self.record(
                id: name, recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)])
        })
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = MuseLocalUsageReader.Limits()
        limits.retainedEventBytes = 800
        let cacheRoot = root.appendingPathComponent("cache")
        let result = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), cacheRoot: cacheRoot, limits: limits)
        #expect(result.coverage == .partial)
        #expect(result.report.summary?.totalTokens == 35122)
        let resumed = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), cacheRoot: cacheRoot, limits: limits)
        #expect(resumed.coverage == .complete)
        #expect(resumed.report.summary?.totalTokens == 70244)
    }

    @Test
    func `out of range history does not exhaust retention and a wider view rescans`() throws {
        let old = (0..<25).map { index in
            Self.record(
                id: "old-\(index)",
                recordedAt: Self.baseMicros - 35 * 86400 * 1_000_000,
                kind: "model_completed",
                usage: Self.modelTurnUsage)
        }
        let current = Self.record(
            id: "current", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)
        let root = try Self.makeTree([(day: "2026-07-27", session: "long-lived", lines: old + [current])])
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var limits = MuseLocalUsageReader.Limits()
        limits.retainedEventBytes = 800
        let scoped = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root),
            calendar: calendar,
            sinceDayKey: "2026-08-31",
            untilDayKey: "2026-08-31",
            cacheRoot: cacheRoot,
            limits: limits)
        #expect(scoped.coverage == .complete)
        #expect(scoped.report.summary?.totalTokens == 35122)
        let expanded = try Self.read(root: root, cacheRoot: cacheRoot)
        #expect(expanded.coverage == .complete)
        #expect(expanded.report.summary?.totalTokens == 26 * 35122)
    }

    @Test
    func `oversized cache preflight preserves the previous atomic cache file`() throws {
        let root = try Self.makeTree([(day: "2026-08-31", session: "session", lines: [Self.record(
            id: "first", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)])])
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache")
        _ = try Self.read(root: root, cacheRoot: cacheRoot)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let cache = MuseLocalUsageCacheIO.load(sessionsRoot: root, cacheRoot: cacheRoot, calendar: calendar)
        let url = MuseLocalUsageCacheIO.cacheFileURL(cacheRoot: cacheRoot)
        let original = try Data(contentsOf: url)
        #expect(MuseLocalUsageCacheIO.fitsEncodingBudget(cache))
        #expect(!MuseLocalUsageCacheIO.fitsEncodingBudget(cache, maximumBytes: 1024))
        MuseLocalUsageCacheIO.save(
            cache: cache, sessionsRoot: root, cacheRoot: cacheRoot, calendar: calendar, maximumBytes: 1024)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: ["valid", "empty", "missing"])
    func `local fetch and CLI preserve tokens and unavailable dollars without pricing requests`(
        source: String) async throws
    {
        let root = try Self.makeTree([(
            day: "2026-08-31", session: "fixture", lines: source == "valid" ? [Self.record(
                id: "usage", recordedAt: Self.baseMicros, kind: "model_completed", usage: Self.modelTurnUsage)] : [])])
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = source == "missing" ? root.appendingPathComponent("absent") : root
        let cache = root.appendingPathComponent("cache")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .muse,
            environment: ["HOME": root.path, "MUSE_SESSIONS_DIR": sessions.path],
            now: Date(timeIntervalSince1970: Double(Self.baseMicros) / 1_000_000),
            historyDays: 1,
            scannerOptions: .init(cacheRoot: cache, calendar: calendar),
            modelsDevClient: ModelsDevClient(transport: RejectMusePricingTransport()))
        let expected: Int? = source == "valid" ? 35122 : source == "empty" ? 0 : nil
        #expect(snapshot.sessionTokens == expected)
        #expect(snapshot.last30DaysTokens == expected)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.meteredCostUSD == nil)
        #expect(snapshot.historyCoverageIsEstablished == (source != "missing"))
        let payload = CodexBarCLI.makeCostPayload(provider: .muse, snapshot: snapshot, error: nil, calendar: calendar)
        #expect(payload.provider == "muse")
        #expect(payload.source == "local")
        #expect(payload.last30DaysTokens == expected)
        #expect(payload.last30DaysCostUSD == nil)
        let text = CodexBarCLI.renderCostText(provider: .muse, snapshot: snapshot, useColor: false)
        #expect(text.contains("Muse Code Token History"))
        #expect(!text.contains("$"))
        #expect(!text.contains("API-rate estimate"))
        #expect(CodexBarCLI.costProviders(from: .single(.muse)) == [.muse])
    }

    @Test
    func `completed file caching advances a byte limited scan`() throws {
        let line = Self.record(
            id: "first",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.modelTurnUsage)
        let root = try Self.makeTree([
            (day: "2026-08-31", session: "a", lines: [line]),
            (day: "2026-08-31", session: "b", lines: [line.replacingOccurrences(of: "first", with: "other")]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        var limits = MuseLocalUsageReader.Limits()
        limits.totalBytes = line.utf8.count + 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache, limits: limits)
        let second = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: .init(sessionsRoot: root), calendar: calendar, cacheRoot: cache, limits: limits)
        #expect(first.coverage == .partial)
        #expect(first.report.summary?.totalTokens == 35122)
        #expect(second.coverage == .complete)
        #expect(second.report.summary?.totalTokens == 70244)
    }
}

private struct RejectMusePricingTransport: ModelsDevHTTPTransport {
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        Issue.record("Token-only Muse history must not fetch pricing or call a provider service")
        throw URLError(.unsupportedURL)
    }
}

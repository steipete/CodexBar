import Foundation
import Testing
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
        model: String? = "\"muse-spark-1.2\"") -> String
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
        {"provider_id":"meta","model_id":"muse-spark-1.2","reasoning_effort":"low"}
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
        #expect(entry.modelBreakdowns?.first?.modelName == "muse-spark-1.2")
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

    @Test
    func `an unknown schema version is ignored rather than guessed at`() throws {
        let line = Self.record(
            id: "e1",
            recordedAt: Self.baseMicros,
            kind: "model_completed",
            usage: Self.modelTurnUsage)
            .replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
        let root = try Self.makeTree([(day: "2026-08-31", session: "sess-1", lines: [line])])
        let result = try Self.read(root: root)
        #expect(result.report.data.isEmpty)
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
    func `day keys come from the tree's own path components`() {
        #expect(MuseLocalUsageReader.dayKey(year: "2026", month: "08", day: "31") == "2026-08-31")
        #expect(MuseLocalUsageReader.dayKey(year: "2026", month: "8", day: "31") == nil)
        #expect(MuseLocalUsageReader.dayKey(year: "abcd", month: "08", day: "31") == nil)
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

    /// The pre-filter keys on the token field, not on the known kinds, so an unrecognized future kind
    /// still reaches the parser and downgrades coverage.
    @Test
    func `lines without token counts are rejected before parsing`() {
        #expect(MuseLocalUsageReader.mayContainTokenCounts(Data(#"{"usage":{"input_tokens":1}}"#.utf8)))
        #expect(MuseLocalUsageReader.mayContainTokenCounts(
            Data(#"{"kind":"future_kind","usage":{"input_tokens":1}}"#.utf8)))
        #expect(!MuseLocalUsageReader.mayContainTokenCounts(
            Data(#"{"usage":{"cpu_self_ms":8,"rss_self_bytes":1}}"#.utf8)))
    }
}

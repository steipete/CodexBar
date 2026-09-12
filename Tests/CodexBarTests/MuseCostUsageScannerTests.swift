import Foundation
import Testing
@testable import CodexBarCore

struct MuseCostUsageScannerTests {
    @Test
    func `scans JSON session file correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionJSON = """
        {
            "id": "session-1",
            "model": "muse-spark-1.3",
            "messages": [
                {
                    "timestamp": "2026-09-08T12:00:00Z",
                    "model": "muse-spark-1.3",
                    "usage": {
                        "input_tokens": 1000,
                        "output_tokens": 200,
                        "cached_tokens": 100
                    }
                },
                {
                    "timestamp": "2026-09-08T12:05:00Z",
                    "model": "muse-spark-1.3",
                    "usage": {
                        "input_tokens": 2000,
                        "output_tokens": 400,
                        "cache_read_input_tokens": 200
                    }
                }
            ]
        }
        """
        let fileURL = sessionsDir.appendingPathComponent("session-1.json")
        try sessionJSON.write(to: fileURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)

        #expect(report.data.count == 1)

        let entry = report.data[0]
        #expect(entry.inputTokens == 3000)
        #expect(entry.outputTokens == 600)
        #expect(entry.cacheReadTokens == 300)
        #expect(entry.totalTokens == 3600)
        #expect(entry.modelsUsed?.contains("muse-spark-1.3") == true)
        #expect((entry.costUSD ?? 0) > 0)
    }

    @Test
    func `scans JSONL session file correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let line1 = """
        {"timestamp":"2026-09-09T10:00:00Z","model":"muse-code",\
        "usage":{"input_tokens":500,"output_tokens":100,"cached_tokens":50}}
        """
        let line2 = """
        {"timestamp":"2026-09-09T10:30:00Z","model":"muse-code",\
        "usage":{"prompt_tokens":1500,"completion_tokens":300,"cache_read_tokens":100}}
        """
        let fileURL = sessionsDir.appendingPathComponent("session-2.jsonl")
        try "\(line1)\n\(line2)\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)

        #expect(report.data.count == 1)

        let entry = report.data[0]
        #expect(entry.inputTokens == 2000)
        #expect(entry.outputTokens == 400)
        #expect(entry.cacheReadTokens == 150)
        #expect(entry.totalTokens == 2400)
        #expect(entry.modelsUsed?.contains("muse-code") == true)
    }

    @Test
    func `multi-day sessions aggregate and compute costs correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let day1Session = """
        {
            "timestamp": "2026-09-01T15:00:00Z",
            "model": "muse-spark-1.3",
            "input_tokens": 10000,
            "output_tokens": 2000
        }
        """
        let day2Session = """
        {
            "timestamp": "2026-09-02T15:00:00Z",
            "model": "muse-code",
            "input_tokens": 20000,
            "output_tokens": 4000
        }
        """

        try day1Session.write(to: sessionsDir.appendingPathComponent("day1.json"), atomically: true, encoding: .utf8)
        try day2Session.write(to: sessionsDir.appendingPathComponent("day2.json"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)

        #expect(report.data.count == 2)
        let dates = report.data.map(\.date).sorted()
        #expect(dates == ["2026-09-01", "2026-09-02"])
    }

    @Test
    func `handles corrupt or empty files gracefully`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "".write(to: sessionsDir.appendingPathComponent("empty.json"), atomically: true, encoding: .utf8)
        try "{ corrupted json".write(
            to: sessionsDir.appendingPathComponent("corrupt.json"),
            atomically: true,
            encoding: .utf8)
        try "not json at all\nline 2".write(
            to: sessionsDir.appendingPathComponent("corrupt.jsonl"),
            atomically: true,
            encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)

        #expect(report.data.isEmpty)
    }

    @Test
    func `real Muse CLI runtime log counts model_completed once and keeps model name`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions/2026/09/08/session-a", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 2026-09-08T12:00:00Z in microseconds, as written by Muse Code 1.1.x.
        let recordedAt = 1_788_868_800_000_000
        let lines = [
            Self.runtimeEvent(recordedAt: recordedAt, event: """
            {"kind":"goal_usage_attribution","record":{"usage_family":"provider","quantity":{"unit":"tokens",\
            "reported":true,"input_tokens":1000,"output_tokens":200,"cached_tokens":100,"reasoning_tokens":5}}}
            """),
            Self.runtimeEvent(recordedAt: recordedAt + 10, event: """
            {"kind":"model_completed","usage":{"input_tokens":1000,"output_tokens":200,"cached_tokens":100,\
            "cache_write_tokens":0,"cache_read_tokens":100,"reasoning_tokens":5},"duration_ms":10,\
            "finish_reason":"stop","model":"muse-spark-1.2"}
            """),
            Self.runtimeEvent(recordedAt: recordedAt + 20, event: """
            {"kind":"goal_usage_attribution","record":{"usage_family":"tool","quantity":{"unit":"tokens",\
            "reported":false,"input_tokens":0,"output_tokens":0,"cached_tokens":0}}}
            """),
        ]
        try lines.joined(separator: "\n").write(
            to: sessionsDir.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [root.appendingPathComponent("sessions", isDirectory: true)],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)

        #expect(report.data.count == 1)
        let day = try #require(report.data.first)
        #expect(day.date == "2026-09-08")
        #expect(day.inputTokens == 1000)
        #expect(day.outputTokens == 200)
        #expect(day.cacheReadTokens == 100)
        #expect(day.modelsUsed == ["muse-spark-1.2"])
        let expected = (900.0 * 1.25e-6) + (100.0 * 0.125e-6) + (200.0 * 4.25e-6)
        #expect(abs((day.costUSD ?? 0) - expected) < 1e-9)
    }

    @Test
    func `contributor tier prices sessions at contributor rates and keeps its own cache`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-09-08T12:00:00Z","model":"muse-spark-1.3","input_tokens":1000000,"output_tokens":0}
        """.write(to: sessionsDir.appendingPathComponent("s.json"), atomically: true, encoding: .utf8)

        var standard = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir], museIsContributor: false, cacheRoot: cacheDir)
        standard.refreshMinIntervalSeconds = 0
        var contributor = standard
        contributor.museIsContributor = true

        let standardReport = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: standard)
        let contributorReport = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: contributor)

        #expect(abs((standardReport.data.first?.costUSD ?? 0) - 1.25) < 1e-9)
        #expect(abs((contributorReport.data.first?.costUSD ?? 0) - 0.10) < 1e-9)
        #expect(FileManager.default.fileExists(
            atPath: CostUsageMuseCacheIO.cacheFileURL(cacheRoot: cacheDir, isContributor: false).path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageMuseCacheIO.cacheFileURL(cacheRoot: cacheDir, isContributor: true).path))
    }

    @Test
    func `corrupt token counts are rejected instead of trapping`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-09-08T12:00:00Z","model":"muse-code","input_tokens":10000000000000000,"output_tokens":1}
        {"timestamp":"2026-09-08T12:01:00Z","model":"muse-code","input_tokens":9223372036854775807,"output_tokens":1}
        {"timestamp":"2026-09-08T12:02:00Z","model":"muse-code","input_tokens":-5,"output_tokens":1}
        {"timestamp":"2026-09-08T12:03:00Z","model":"muse-code","input_tokens":1.5,"output_tokens":1}
        {"timestamp":"2026-09-08T12:04:00Z","model":"muse-code","input_tokens":100,"output_tokens":10}
        """.write(to: sessionsDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir], museIsContributor: false, cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)
        let day = try #require(report.data.first)
        #expect(day.inputTokens == 100)
        #expect(day.outputTokens == 10)
    }

    @Test
    func `warm cache reuses unchanged files and rescans changed ones`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = sessionsDir.appendingPathComponent("s.json")
        try """
        {"timestamp":"2026-09-08T12:00:00Z","model":"muse-spark-1.3","input_tokens":1000,"output_tokens":100}
        """.write(to: file, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir], museIsContributor: false, cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let fresh = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow, options: options)
        #expect(fresh.data.first?.inputTokens == 1000)

        // Within the refresh interval the cached artifact answers without touching the file.
        var throttled = options
        throttled.refreshMinIntervalSeconds = 3600
        try FileManager.default.removeItem(at: file)
        let warm = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow.addingTimeInterval(1), options: throttled)
        #expect(warm.data.first?.inputTokens == 1000)

        // A later refresh notices the deleted file and a rewritten one with new content.
        try """
        {"timestamp":"2026-09-08T13:00:00Z","model":"muse-spark-1.3","input_tokens":5000,"output_tokens":500}
        """.write(to: file, atomically: true, encoding: .utf8)
        let rescanned = try CostUsageScanner.loadMuseDaily(now: Self.fixedNow.addingTimeInterval(2), options: options)
        #expect(rescanned.data.first?.inputTokens == 5000)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Wraps one runtime event the way Muse Code 1.1.x writes it to `session.jsonl`.
    private static func runtimeEvent(recordedAt: Int, event: String) -> String {
        """
        {"schema_version":1,"recorded_at":\(recordedAt),"record_type":"event","payload_type":"runtime.session",\
        "payload":{"kind":"run","run_id":"r1","event":\(event)}}
        """
    }

    private static let fixedNow: Date = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!
}

import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexCostReportTests {
    private static let dailyHelp = "--summary-only --daily-summary --bucket-time-zone <zone>"
    private static let calendar = CostUsageBucketTimeZone.calendar(identifier: "GMT")

    private static func daily() throws -> CodexCostDailySummary {
        try CodexCostDailySummary(snapshot: .init(
            sessionTokens: 100,
            sessionCostUSD: 0.5,
            last30DaysTokens: 100,
            last30DaysCostUSD: 0.5,
            historyScanIsPartial: true,
            costProvenance: .listPriceEstimate,
            daily: [.init(
                date: "2026-08-31", inputTokens: nil, outputTokens: nil,
                totalTokens: 100, costUSD: 0.5, modelsUsed: nil, modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_788_177_600)), calendar: self.calendar)
    }

    private static func summary(tokens: Int? = 0, cost: Double? = 0) -> CodexCostSummary {
        CodexCostSummary(
            snapshot: .init(
                sessionTokens: tokens,
                sessionCostUSD: cost,
                last30DaysTokens: tokens,
                last30DaysCostUSD: cost,
                historyCoverageIsEstablished: false,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 1_788_177_600)),
            calendar: CostUsageBucketTimeZone.calendar(identifier: "Asia/Tokyo"))
    }

    private static func wire(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try String(decoding: encoder.encode([value]), as: UTF8.self)
    }

    @Test(arguments: [false, true])
    func `capability selection runs one scan and preserves selected metadata`(capable: Bool) async throws {
        let daily = try Self.daily()
        let summary = Self.summary()
        let fixture = try Fixture(
            help: capable ? Self.dailyHelp : "--summary-only",
            output: capable ? Self.wire(daily) : Self.wire(summary))
        defer { fixture.remove() }
        let result = try await fixture.fetcher().fetchReport(
            host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT", force: true)
        #expect(result == (capable ? .daily(daily) : .summary(summary)))
        let calls = try fixture.calls()
        #expect(calls.count == 2)
        #expect(calls.first == "cost --help")
        #expect(calls.last?.contains(capable ? "--daily-summary" : "--summary-only") == true)
        #expect(calls.last?.contains("--refresh") == true)
        #expect(calls.last?.contains("--bucket-time-zone GMT") == capable)
    }

    @Test(arguments: [
        "--daily-summary-extra --bucket-time-zone --summary-only",
        "--daily-summary --bucket-time-zone-extra --summary-only",
    ])
    func `capability flags require exact tokens before selecting daily`(help: String) async throws {
        let summary = Self.summary()
        let fixture = try Fixture(help: help, output: Self.wire(summary))
        defer { fixture.remove() }
        #expect(try await fixture.fetcher().fetchReport(
            host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT") == .summary(summary))
        #expect(try fixture.calls().last?.contains("--summary-only") == true)
    }

    @Test(arguments: ["empty", "prefix", "oversized", "trailingNewlines", "failed"])
    func `unsupported oversized or failed capability never scans`(mode: String) async throws {
        let help = mode == "oversized"
            ? String(repeating: "x", count: RemoteCodexCostFetcher.maximumOutputBytes + 1)
            : mode == "trailingNewlines" ? "--summary-only" + String(repeating: "\n", count: 20000)
            : mode == "prefix" ? "--summary-only-extra --daily-summary-extra --bucket-time-zone-extra"
            : mode == "failed" ? Self.dailyHelp : ""
        let fixture = try Fixture(help: help, output: Self.wire(Self.summary()), helpExit: mode == "failed" ? 2 : 0)
        defer { fixture.remove() }
        await #expect(throws: RemoteCodexCostError.self) {
            try await fixture.fetcher().fetchReport(host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT")
        }
        #expect(try fixture.calls() == ["cost --help"])
    }

    @Test(arguments: [
        "scanFailed",
        "malformed",
        "oversized",
        "wrongKind",
        "missingKind",
        "aggregateWithKind",
        "aggregateAfterDaily",
    ])
    func `daily failure never starts a summary scan or decodes daily as aggregate`(mode: String) async throws {
        var object = try #require((JSONSerialization.jsonObject(
            with: Data(Self.wire(Self.daily()).utf8)) as? [[String: Any]])?.first)
        if mode == "wrongKind" { object["kind"] = "summary" }
        if mode == "missingKind" { object.removeValue(forKey: "kind") }
        if mode == "aggregateWithKind" || mode == "aggregateAfterDaily" {
            object = try #require((JSONSerialization.jsonObject(
                with: Data(Self.wire(Self.summary()).utf8)) as? [[String: Any]])?.first)
            if mode == "aggregateWithKind" { object["kind"] = "daily" }
        }
        let output = mode == "malformed" ? "{invalid"
            : mode == "oversized" ? String(repeating: " ", count: RemoteCodexCostFetcher.maximumDailyOutputBytes + 1)
            : try String(decoding: JSONSerialization.data(withJSONObject: [object]), as: UTF8.self)
        let fixture = try Fixture(help: Self.dailyHelp, output: output, scanExit: mode == "scanFailed" ? 2 : 0)
        defer { fixture.remove() }
        await #expect(throws: RemoteCodexCostError.self) {
            try await fixture.fetcher().fetchReport(host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT")
        }
        let calls = try fixture.calls()
        #expect(calls.count == 2)
        #expect(calls.last?.contains("--daily-summary") == true)
        #expect(calls.last?.contains("--summary-only") == false)
    }

    @Test(arguments: [false, true])
    func `aggregate receiver keeps unknown and zero distinct within its smaller limit`(unknown: Bool) async throws {
        let expected = Self.summary(tokens: unknown ? nil : 0, cost: unknown ? nil : 0)
        let wire = try Self.wire(expected)
        let fetcher = RemoteCodexCostFetcher(boundedRunner: { _, _, limit in
            #expect(limit == RemoteCodexCostFetcher.maximumDailyOutputBytes)
            return .init(stdout: wire, stderr: RemoteCodexCostFetcher.summaryReportMarker + "\n")
        })
        #expect(try await fetcher.fetchReport(
            host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT") == .summary(expected))
        let oversized = RemoteCodexCostFetcher(boundedRunner: { _, _, _ in
            .init(
                stdout: wire + String(repeating: " ", count: RemoteCodexCostFetcher.maximumOutputBytes),
                stderr: RemoteCodexCostFetcher.summaryReportMarker + "\n")
        })
        await #expect(throws: RemoteCodexCostError.self) {
            try await oversized.fetchReport(host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT")
        }
    }

    @Test
    func `cancellation before a late selected result stays cancellation`() async throws {
        let wire = try Self.wire(Self.summary())
        let gate = Gate()
        let fetcher = RemoteCodexCostFetcher(boundedRunner: { _, _, _ in
            await gate.load()
            return .init(stdout: wire, stderr: RemoteCodexCostFetcher.summaryReportMarker + "\n")
        })
        let task = Task {
            try await fetcher.fetchReport(host: "fixture-host", historyDays: 30, bucketTimeZone: "GMT")
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private struct Fixture {
        let directory: URL

        init(help: String, output: String, helpExit: Int = 0, scanExit: Int = 0) throws {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try help.write(to: self.directory.appendingPathComponent("help"), atomically: true, encoding: .utf8)
            try output.write(to: self.directory.appendingPathComponent("output"), atomically: true, encoding: .utf8)
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls"
            if [ "$2" = --help ]; then cat "$FIXTURE_ROOT/help"; exit \(helpExit); fi
            cat "$FIXTURE_ROOT/output"
            exit \(scanExit)
            """
            let cli = self.directory.appendingPathComponent("codexbar")
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }

        func fetcher() -> RemoteCodexCostFetcher {
            RemoteCodexCostFetcher(boundedRunner: { arguments, environment, limit in
                #expect(arguments.filter { $0 == "fixture-host" }.count == 1)
                #expect(environment["UNRELATED_TOKEN"] == nil)
                let command = try #require(arguments.last)
                return try await SubprocessRunner.run(
                    binary: "/bin/sh", arguments: ["-c", String(command.dropFirst().dropLast())],
                    environment: ["PATH": self.directory.path + ":/usr/bin:/bin", "FIXTURE_ROOT": self.directory.path],
                    timeout: 5, maxOutputBytes: limit, standardInput: FileHandle.nullDevice,
                    label: "fixture capability")
            })
        }

        func calls() throws -> [String] {
            try String(contentsOf: self.directory.appendingPathComponent("calls"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: self.directory) }
    }

    private actor Gate {
        private var result: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func load() async {
            await withCheckedContinuation { continuation in
                self.result = continuation
                self.started?.resume()
                self.started = nil
            }
        }

        func waitUntilStarted() async {
            guard self.result == nil else { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func release() {
            self.result?.resume()
            self.result = nil
        }
    }
}

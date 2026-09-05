import Foundation
import Testing
@testable import CodexBarCore

struct GrokBuildLocalScannerTests {
    private let timestampMs: Int64 = 1_700_000_000_000

    @Test
    func `parses timestamped usage totals without inventing requests`() throws {
        let fixture = try self.makeFixture("structured")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 100, output: 50, models: ["grok-beta", "grok-fast"]),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        let bucket = try #require(summary.daily.first)
        #expect(summary.totalTokens == 150)
        #expect(bucket.totalTokens == 150)
        #expect(Set(bucket.models) == ["grok-beta", "grok-fast"])
        #expect(summary.toCostUsageTokenSnapshot(historyDays: 30).daily.first?.requestCount == nil)
        #expect(!GrokProviderDescriptor.descriptor.tokenCost.showsRequestHistory)
    }

    @Test
    func `deduplicates replayed usage event IDs`() throws {
        let fixture = try self.makeFixture("duplicate")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 30, output: 20, models: ["grok-a"], eventID: "reused"),
            self.usageLine(input: 30, output: 20, models: ["grok-b"], eventID: "reused"),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 50)
        #expect(summary.historyCoverageIsEstablished)
    }

    @Test
    func `ignores out-of-window rows with invalid tokens without marking incomplete`() throws {
        let fixture = try self.makeFixture("window-external-invalid")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 100, output: 50, eventID: "current"),
            #"{"params":{"update":{"usage":{"inputTokens":10}}},"_meta":{"eventId":"old-bad",""# +
                #"agentTimestampMs":1600000000000}}"#,
            #"{"params":{"update":{"usage":{"inputTokens":10}}},"_meta":{"eventId":"future-bad",""# +
                #"agentTimestampMs":1800000000000}}"#,
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 150)
        #expect(summary.historyCoverageIsEstablished)
    }

    @Test
    func `counts a current row sharing an ID with an out-of-window row`() throws {
        let fixture = try self.makeFixture("window-external-id")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            #"{"params":{"update":{"usage":{"inputTokens":30,"outputTokens":20,"totalTokens":50}}},"# +
                #""_meta":{"eventId":"shared","agentTimestampMs":1600000000000}}"#,
            self.usageLine(input: 100, output: 50, eventID: "shared"),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 150)
        #expect(summary.historyCoverageIsEstablished)
    }

    @Test
    func `counts a later valid row when the first row with its event ID is invalid`() throws {
        let fixture = try self.makeFixture("dedup-invalid-first")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 30, output: 20, timestamp: nil, eventID: "reused"),
            self.usageLine(input: 30, output: 20, eventID: "reused"),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 50)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `retains valid usage before a damaged tail`() throws {
        let fixture = try self.makeFixture("damaged-tail")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 50, output: 50),
            #"{"params":{"update":{"usage":{"incomplete":}"#,
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 100)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `rejects overflowing component totals`() throws {
        let fixture = try self.makeFixture("overflow")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: Int.max, output: 1, includeReportedTotal: false),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `fails soft when valid rows overflow their daily total`() throws {
        let fixture = try self.makeFixture("aggregate-overflow")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: Int.max, output: 0, eventID: "first"),
            self.usageLine(input: 1, output: 0, eventID: "second"),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == Int.max)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `rejects totals inconsistent with their components`() throws {
        let fixture = try self.makeFixture("inconsistent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 100, output: 50, reportedTotal: 100),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `rejects undated usage instead of using file time`() throws {
        let fixture = try self.makeFixture("undated")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 100, output: 50, timestamp: nil),
        ], to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `accepts ISO timestamps`() throws {
        let fixture = try self.makeFixture("iso-time")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([
            self.usageLine(input: 10, output: 5, timestamp: "2023-11-14T22:13:20Z"),
        ], to: fixture.session)

        #expect(self.scan(fixture.root).totalTokens == 15)
    }

    @Test
    func `bounds updates reads before parsing`() throws {
        let fixture = try self.makeFixture("bounded")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oversized = Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: fixture.session.appendingPathComponent("updates.jsonl"))

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `falls back to legacy signals when updates contain no usage`() throws {
        let fixture = try self.makeFixture("signals-fallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([#"{"params":{"update":{"status":"ready"}}}"#], to: fixture.session)
        try self.writeSignals(tokens: 40, timestamp: self.timestampMs, to: fixture.session)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 40)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `filters legacy signals by producer timestamp`() throws {
        let fixture = try self.makeFixture("signals-window")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeSignals(tokens: 40, timestamp: 1_600_000_000_000, to: fixture.session)
        let signals = fixture.session.appendingPathComponent("signals.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
            ofItemAtPath: signals.path)

        let summary = self.scan(fixture.root)
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `respects the supplied calendar timezone`() throws {
        let fixture = try self.makeFixture("timezone")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([self.usageLine(input: 10, output: 10)], to: fixture.session)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))

        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            calendar: calendar)
        #expect(summary.daily.first?.date == "2023-11-15")
    }

    @Test
    func `stops reading when the shared byte budget is exhausted`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-a", isDirectory: true)
        let second = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for session in [first, second] {
            try JSONSerialization.data(withJSONObject: [
                "contextTokensUsed": 7,
                "totalTokensBeforeCompaction": 0,
                "primaryModelId": "grok-build",
                "modelsUsed": ["grok-build"],
                "timestamp": 1_700_000_000_000,
            ]).write(to: session.appendingPathComponent("signals.json"))
        }
        let firstSize = try self.fileSize(at: first.appendingPathComponent("signals.json"))
        let secondSize = try self.fileSize(at: second.appendingPathComponent("signals.json"))

        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            byteBudget: firstSize + secondSize / 2)
        #expect(summary.totalTokens == 7)
        #expect(!summary.historyCoverageIsEstablished)
    }

    private func fileSize(at url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Records every bounded read requested through the production wiring.
    private final class RecordingGrokReader {
        struct Request {
            let url: URL
            let limit: Int
            let bytes: Int
        }

        private(set) var requests: [Request] = []

        func reader() -> GrokBoundedReader {
            GrokBoundedReader { url, limit in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit)
                self.requests.append(Request(url: url, limit: limit, bytes: data?.count ?? 0))
                return data
            }
        }
    }

    @Test
    func `reads recent candidates before stale ones under a tight budget`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-recency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/a-archive", isDirectory: true)
        let active = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/z-active", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try self.writeUpdates([self.usageLine(input: 10, output: 10, eventID: "old")], to: archive)
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "new")], to: active)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: archive.appendingPathComponent("updates.jsonl").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_004)],
            ofItemAtPath: active.appendingPathComponent("updates.jsonl").path)
        let activeSize = try self.fileSize(at: active.appendingPathComponent("updates.jsonl"))

        func scan() -> GrokLocalSessionSummary {
            GrokLocalSessionScanner.summarize(
                env: ["GROK_HOME": root.path],
                lookbackDays: 30,
                now: Date(timeIntervalSince1970: 1_700_000_005),
                byteBudget: activeSize + 10)
        }
        let first = scan()
        #expect(first.totalTokens == 150)
        #expect(!first.historyCoverageIsEstablished)
        #expect(scan().totalTokens == first.totalTokens)
    }

    @Test
    func `orders equal recency deterministically by path`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-recency-tie-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-a", isDirectory: true)
        let second = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "a")], to: first)
        try self.writeUpdates([self.usageLine(input: 30, output: 20, eventID: "b")], to: second)
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_004)
        for session in [first, second] {
            try FileManager.default.setAttributes(
                [.modificationDate: sharedDate],
                ofItemAtPath: session.appendingPathComponent("updates.jsonl").path)
        }
        let firstSize = try self.fileSize(at: first.appendingPathComponent("updates.jsonl"))

        func scan() -> GrokLocalSessionSummary {
            GrokLocalSessionScanner.summarize(
                env: ["GROK_HOME": root.path],
                lookbackDays: 30,
                now: Date(timeIntervalSince1970: 1_700_000_005),
                byteBudget: firstSize + 10)
        }
        #expect(scan().totalTokens == 150)
        #expect(scan().totalTokens == 150)
    }

    @Test
    func `counts current events from stale files when the budget allows`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-stale-mtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "ev-1")], to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: session.appendingPathComponent("updates.jsonl").path)

        let summary = self.scan(root)
        #expect(summary.totalTokens == 150)
        #expect(summary.historyCoverageIsEstablished)
    }

    @Test
    func `caps every read at the remaining budget`() throws {
        let fixture = try self.makeFixture("read-limits")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "ev-1")], to: fixture.session)
        let recording = RecordingGrokReader()
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            byteBudget: 5,
            boundedReader: recording.reader())
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(!recording.requests.isEmpty)
        #expect(recording.requests.allSatisfy { $0.limit <= 5 })
        #expect(recording.requests.reduce(0) { $0 + $1.bytes } <= 5)
    }

    @Test
    func `shares one budget between signals and updates in a directory`() throws {
        let fixture = try self.makeFixture("shared-budget")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "ev-1")], to: fixture.session)
        try self.writeSignals(tokens: 40, timestamp: self.timestampMs, to: fixture.session)
        let signalsSize = try self.fileSize(at: fixture.session.appendingPathComponent("signals.json"))
        let recording = RecordingGrokReader()
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            byteBudget: signalsSize,
            boundedReader: recording.reader())
        #expect(summary.totalTokens == 40)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(recording.requests.map(\.url.lastPathComponent) == ["signals.json"])
    }

    @Test
    func `makes no reads with a zero budget`() throws {
        let fixture = try self.makeFixture("zero-budget")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "ev-1")], to: fixture.session)
        let recording = RecordingGrokReader()
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            byteBudget: 0,
            boundedReader: recording.reader())
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(recording.requests.isEmpty)
    }

    @Test
    func `treats an exact budget fit as complete but later candidates as incomplete`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-exact-fit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-a", isDirectory: true)
        let second = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try self.writeUpdates([self.usageLine(input: 100, output: 50, eventID: "a")], to: first)
        try self.writeUpdates([self.usageLine(input: 30, output: 20, eventID: "b")], to: second)
        for session in [first, second] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_004)],
                ofItemAtPath: session.appendingPathComponent("updates.jsonl").path)
        }
        let firstSize = try self.fileSize(at: first.appendingPathComponent("updates.jsonl"))
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            byteBudget: firstSize)
        #expect(summary.totalTokens == 150)
        #expect(!summary.historyCoverageIsEstablished)
    }

    private func makeFixture(_ name: String) throws -> (root: URL, session: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-\(name)-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return (root, session)
    }

    private func scan(_ root: URL) -> GrokLocalSessionSummary {
        GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 30,
            now: Date(timeIntervalSince1970: 1_700_000_005))
    }

    private func writeUpdates(_ lines: [String], to session: URL) throws {
        try lines.joined(separator: "\n").write(
            to: session.appendingPathComponent("updates.jsonl"),
            atomically: true,
            encoding: .utf8)
    }

    private func usageLine(
        input: Int,
        output: Int,
        reportedTotal: Int? = nil,
        includeReportedTotal: Bool = true,
        timestamp: Any? = 1_700_000_000_000,
        models: [String] = [],
        eventID: String = "event-1") throws -> String
    {
        var usage: [String: Any] = ["inputTokens": input, "outputTokens": output]
        if includeReportedTotal {
            usage["totalTokens"] = reportedTotal ?? (input + output)
        }
        if !models.isEmpty {
            usage["modelUsage"] = Dictionary(uniqueKeysWithValues: models.map { ($0, [:] as [String: Any]) })
        }
        var meta: [String: Any] = ["eventId": eventID]
        if let timestamp {
            meta["agentTimestampMs"] = timestamp
        }
        let object: [String: Any] = [
            "params": ["update": ["usage": usage]],
            "_meta": meta,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func writeSignals(tokens: Int, timestamp: Int64, to session: URL) throws {
        let object: [String: Any] = [
            "contextTokensUsed": tokens,
            "totalTokensBeforeCompaction": 0,
            "primaryModelId": "grok-build",
            "modelsUsed": ["grok-build"],
            "timestamp": timestamp,
        ]
        try JSONSerialization.data(withJSONObject: object).write(
            to: session.appendingPathComponent("signals.json"))
    }
}

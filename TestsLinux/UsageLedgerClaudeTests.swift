import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerClaudeTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test
    func `native copies and streaming chunks export one private usage record`() throws {
        let first = try self.event(output: 10)
        let final = try self.event(output: 20)
        let ledger = try self.load([
            "project-a/session.jsonl": first + "\n" + final + "\n",
            "project-b/copied.jsonl": final + "\n",
        ])
        let record = try #require(ledger.records.first)
        #expect(ledger.records.count == 1)
        #expect(ledger.conflictingRecordIDs == nil)
        #expect(record.identity == .request)
        #expect(record.totalTokens == 200)
        #expect(record.cacheWrite1hTokens == 15)
        #expect(record.costProvenance == .listPriceEstimate)
        #expect(try abs(#require(record.costUSD) - 0.00076125) < 0.000000001)
        #expect(ledger.coverageIsEstablished)
        let json = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!json.contains("secret-conversation"))
        #expect(!json.contains("private-message-id"))
        #expect(!json.contains("private-request-id"))
        #expect(!json.contains("private-session-id"))
        #expect(!json.contains("project-a"))
    }

    @Test(arguments: [true, false])
    func `contradictory completed native copies are quarantined against a clean remote copy`(
        hasRequest: Bool) throws
    {
        let request = hasRequest ? "private-request-id" : nil
        let ledger = try self.load([
            "project-a/session.jsonl": self.event(request: request, input: 100) + "\n",
            "project-b/copied.jsonl": self.event(request: request, input: 200) + "\n",
            "project-c/copied-again.jsonl": self.event(request: request, input: 300) + "\n",
        ])
        #expect(ledger.records.count == 2)
        #expect(Set(ledger.records.map(\.id)).count == 1)
        #expect(ledger.conflictingRecordIDs?.count == 1)
        #expect(!ledger.coverageIsEstablished)
        #expect(ledger.warnings.contains { $0.contains("contradictory completed copies") })
        let remote = try self.load(["project/session.jsonl": self.event(request: request, input: 100) + "\n"])
        let merged = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: ledger), .init(host: "remote", ledger: remote)],
            provider: "claude",
            historyDays: 1)
        #expect(merged.combined.conflictCount == 1)
        #expect(merged.combined.totalTokens == 0)
        #expect(merged.combined.costUSD == nil)
        #expect(!merged.combined.coverageIsEstablished)
    }

    @Test
    func `overflowing contradiction retains stable quarantine identity without numeric evidence`() throws {
        let ledger = try self.load([
            "project-a/session.jsonl": self.event() + "\n",
            "project-b/copied.jsonl": self.event(input: Int.max) + "\n",
        ])
        #expect(ledger.records.count == 1)
        #expect(ledger.conflictingRecordIDs == ledger.records.map(\.id))
        #expect(!ledger.coverageIsEstablished)
        let remote = try self.load(["project/session.jsonl": self.event() + "\n"])
        let merged = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: ledger), .init(host: "remote", ledger: remote)],
            provider: "claude",
            historyDays: 1)
        #expect(merged.combined.conflictCount == 1)
        #expect(merged.combined.totalTokens == 0)
    }

    @Test
    func `a completed all zero copy cannot erase contradictory positive usage`() throws {
        let zero = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","#
            + #""sessionId":"private-session-id","requestId":"private-request-id","message":{"#
            + #""id":"private-message-id","model":"claude-sonnet-4-20250514","stop_reason":"end_turn","#
            + #""usage":{"input_tokens":0,"output_tokens":0,"#
            + #""cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        let ledger = try self.load([
            "project-a/session.jsonl": self.event() + "\n",
            "project-b/zero.jsonl": zero + "\n",
        ])
        #expect(ledger.records.count == 2)
        #expect(Set(ledger.records.map(\.totalTokens)) == [0, 190])
        #expect(ledger.conflictingRecordIDs?.count == 1)
        let merged = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: ledger)],
            provider: "claude",
            historyDays: 1)
        #expect(merged.combined.conflictCount == 1)
        #expect(merged.combined.totalTokens == 0)
        #expect(!merged.combined.coverageIsEstablished)
    }

    @Test
    func `model redaction cannot erase native contradiction evidence`() throws {
        let firstModel = "/Users/private-person/first-secret/model"
        let secondModel = "/Users/private-person/second-secret/model"
        let ledger = try self.load([
            "project-a/session.jsonl": self.event(model: firstModel) + "\n",
            "project-b/copied.jsonl": self.event(model: secondModel) + "\n",
        ])
        #expect(ledger.records.count == 2)
        #expect(ledger.records.allSatisfy { $0.model == "unknown" && $0.pricingModel == "unknown" })
        #expect(ledger.conflictingRecordIDs?.count == 1)
        let remote = try self.load(["project/session.jsonl": self.event(model: firstModel) + "\n"])
        let merged = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: ledger), .init(host: "remote", ledger: remote)],
            provider: "claude",
            historyDays: 1)
        #expect(merged.combined.conflictCount == 1)
        #expect(merged.combined.totalTokens == 0)
        let json = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!json.contains("private-person"))
        #expect(!json.contains("first-secret"))
        #expect(!json.contains("second-secret"))
    }

    @Test
    func `a completed copy supersedes incomplete usage without manufacturing a conflict`() throws {
        let incomplete = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","#
            + #""sessionId":"private-session-id","requestId":"private-request-id","message":{"#
            + #""id":"private-message-id","model":"claude-sonnet-4-20250514","stop_reason":null,"#
            + #""usage":{"input_tokens":999,"output_tokens":0}}}"#
        let ledger = try self.load([
            "project-a/partial.jsonl": incomplete + "\n",
            "project-b/completed.jsonl": self.event() + "\n",
        ])
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.totalTokens == 190)
        #expect(ledger.incompleteRequestCount == 0)
        #expect(ledger.conflictingRecordIDs == nil)
        #expect(ledger.coverageIsEstablished)
    }

    @Test(arguments: ["2026-10-09T23:59:59Z", "2026-10-10T16:00:01Z"])
    func `out of window chunks and copies cannot override eligible usage or cause conflicts`(
        timestamp: String) throws
    {
        let outside = try self.event(input: 200, timestamp: timestamp)
        let ledger = try self.load([
            "project-a/session.jsonl": self.event() + "\n" + outside + "\n",
            "project-b/outside.jsonl": outside + "\n",
        ])
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.totalTokens == 190)
        #expect(ledger.conflictingRecordIDs == nil)
        #expect(ledger.coverageIsEstablished)
    }

    @Test
    func `fractional snapshot end uses the same rounded millisecond as the wire window`() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(formatter.date(from: "2026-10-10T16:00:00.000Z"))
            .addingTimeInterval(0.0008)
        let ledger = try self.load([
            "project/session.jsonl": self.event(timestamp: "2026-10-10T16:00:00.001Z") + "\n",
        ], now: now)
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.timestampUnixMs == ledger.windowEndUnixMs)
        try ledger.validate(provider: "claude", historyDays: 1)
    }

    @Test
    func `fractional midnight derives the day window from its canonical wire instant`() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(formatter.date(from: "2026-10-10T23:59:59.999Z"))
            .addingTimeInterval(0.0008)
        let ledger = try self.load([
            "project/session.jsonl": self.event(timestamp: "2026-10-10T12:00:00Z") + "\n"
                + self.event(timestamp: "2026-10-11T00:00:00Z") + "\n",
        ], now: now)
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.totalTokens == 190)
        #expect(ledger.windowStartUnixMs == ledger.windowEndUnixMs)
        #expect(ledger.records.first?.timestampUnixMs == ledger.windowEndUnixMs)
        try ledger.validate(provider: "claude", historyDays: 1)
    }

    @Test
    func `session fallback preserves delimiter boundaries and identity namespaces`() throws {
        let ledger = try self.load([
            "project/session.jsonl": [
                self.event(message: "response", request: nil, session: "session:a"),
                self.event(message: "a:response", request: nil, session: "session"),
                self.event(message: "response", request: "session:a", session: "session:a"),
                self.event(message: "response", request: nil, session: "session:a"),
            ].joined(separator: "\n") + "\n",
        ])
        #expect(ledger.records.count == 3)
        #expect(Set(ledger.records.map(\.id)).count == 3)
        #expect(ledger.records.filter { $0.identity == .request }.count == 1)
        #expect(ledger.records.filter { $0.identity == .legacyEvent }.count == 2)
    }

    @Test
    func `request and session fallback representations are not added across hosts`() throws {
        let strong = try self.load(["project/session.jsonl": self.event() + "\n"])
        let fallback = try self.load(["project/session.jsonl": self.event(request: nil) + "\n"])
        let combined = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: strong), .init(host: "remote", ledger: fallback)],
            provider: "claude",
            historyDays: 1)
        #expect(combined.combined.totalTokens == 190)
        #expect(combined.combined.unidentifiedCount == 1)
        #expect(!combined.combined.coverageIsEstablished)
    }

    @Test(arguments: ["", " \t"])
    func `blank explicit request identities cannot establish a provider request`(blank: String) throws {
        let ledger = try self.load([
            "project/session.jsonl": self.event(request: blank) + "\n"
                + self.event(message: blank, request: "different-request") + "\n",
        ])
        #expect(ledger.records.count == 2)
        #expect(ledger.records.allSatisfy { $0.identity == .unidentified })
    }

    @Test
    func `discarded malformed oversized and metadata missing usage lines clear coverage`() throws {
        let malformed = #"{"type":"assistant","message":{"usage":{"input_tokens":100}}"# + "\n"
        let oversized = try self.event().replacingOccurrences(
            of: "secret-conversation", with: String(repeating: "x", count: 600_000)) + "\n"
        let missingTimestamp = try self.event().replacingOccurrences(
            of: #""timestamp":"2026-10-10T12:00:00Z","#, with: "") + "\n"
        let ledger = try self.load([
            "project/malformed.jsonl": malformed,
            "project/oversized.jsonl": oversized,
            "project/metadata.jsonl": missingTimestamp,
            "project/valid.jsonl": self.event() + "\n",
        ])
        #expect(ledger.records.count == 1)
        #expect(!ledger.coverageIsEstablished)
        #expect(ledger.warnings.contains { $0.contains("3 potentially usage-bearing lines") })
    }

    @Test(arguments: ["/Users/private-person/secret-project/model", "private text", String(repeating: "x", count: 129)])
    func `arbitrary model metadata is redacted from the exported wire format`(model: String) throws {
        let ledger = try self.load(["project/session.jsonl": self.event(model: model) + "\n"])
        let record = try #require(ledger.records.first)
        #expect(record.model == "unknown")
        #expect(record.pricingModel == "unknown")
        let json = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!json.contains(model))
        #expect(!json.contains("private-person"))
        #expect(!json.contains("secret-project"))
        #expect(ledger.warnings.contains { $0.contains("redacted") })
    }

    @Test
    func `explicit scan cancellation reaches native source discovery`() throws {
        #expect(throws: CancellationError.self) {
            try self.load(["project/session.jsonl": self.event() + "\n"], checkCancellation: {
                throw CancellationError()
            })
        }
    }

    @Test
    func `incomplete responses are excluded while unidentified responses remain explicit`() throws {
        let incomplete = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","#
            + #""sessionId":"session","requestId":"partial","message":{"#
            + #""id":"partial","model":"claude-sonnet-4-20250514","stop_reason":null,"#
            + #""usage":{"input_tokens":100,"output_tokens":0}}}"#
        let ledger = try self.load([
            "project/session.jsonl": incomplete + "\n"
                + self.event(message: nil, request: nil, session: nil) + "\n",
        ])
        #expect(ledger.incompleteRequestCount == 1)
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.identity == .unidentified)
        #expect(ledger.records.first?.totalTokens == 190)
        #expect(ledger.warnings.contains { $0.contains("incomplete responses") })
    }

    @Test
    func `partial source reads and overflowing totals cannot establish coverage`() throws {
        let overflow = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","#
            + #""sessionId":"session","requestId":"overflow","message":{"#
            + #""id":"overflow","model":"claude-sonnet-4-20250514","#
            + #""usage":{"input_tokens":9223372036854775807,"output_tokens":1}}}"#
        let ledger = try self.load([
            "project/overflow.jsonl": overflow + "\n",
            "project/partial.jsonl": #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z""#,
        ])
        #expect(ledger.records.isEmpty)
        #expect(!ledger.coverageIsEstablished)
        #expect(ledger.warnings.contains { $0.contains("fully read") })
        #expect(ledger.warnings.contains { $0.contains("overflowing") })
    }

    @Test
    func `requested day window excludes the scanner guard days`() throws {
        let ledger = try self.load([
            "project/session.jsonl": [
                self.event(message: "before", timestamp: "2026-10-09T23:59:59Z"),
                self.event(message: "inside", timestamp: "2026-10-10T00:00:00Z"),
                self.event(message: "after", timestamp: "2026-10-11T00:00:00Z"),
            ].joined(separator: "\n") + "\n",
        ])
        #expect(ledger.records.count == 1)
        #expect(ledger.historyDays == 1)
        #expect(ledger.bucketTimeZone == "GMT")
    }

    private func event(
        message: String? = "private-message-id",
        request: String? = "private-request-id",
        session: String? = "private-session-id",
        output: Int = 10,
        input: Int = 100,
        timestamp: String = "2026-10-10T12:00:00Z",
        model: String = "claude-sonnet-4-20250514") throws -> String
    {
        var messageValue: [String: Any] = [
            "model": model,
            "content": "secret-conversation",
            "usage": [
                "input_tokens": input,
                "cache_read_input_tokens": 50,
                "cache_creation_input_tokens": 30,
                "cache_creation": ["ephemeral_1h_input_tokens": 15],
                "output_tokens": output,
            ],
        ]
        messageValue["id"] = message
        var object: [String: Any] = ["type": "assistant", "timestamp": timestamp, "message": messageValue]
        object["sessionId"] = session
        object["requestId"] = request
        return try #require(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8))
    }

    private func load(
        _ files: [String: String],
        now: Date? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> UsageLedger
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let cache = root.appendingPathComponent("cache")
        for (path, contents) in files {
            let url = projects.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let snapshotNow = now ?? ISO8601DateFormatter().date(from: "2026-10-10T16:00:00Z")!
        let ledger = try UsageLedgerLoader.loadClaude(
            historyDays: 1,
            now: snapshotNow,
            calendar: self.calendar,
            options: .init(claudeProjectsRoots: [projects], cacheRoot: cache, calendar: self.calendar),
            checkCancellation: checkCancellation)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        return ledger
    }
}

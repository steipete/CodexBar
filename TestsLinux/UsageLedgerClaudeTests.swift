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
        let first = self.event(output: 10)
        let final = self.event(output: 20)
        let ledger = try self.load([
            "project-a/session.jsonl": first + "\n" + final + "\n",
            "project-b/copied.jsonl": final + "\n",
        ])
        let record = try #require(ledger.records.first)
        #expect(ledger.records.count == 1)
        #expect(record.identity == .request)
        #expect(record.totalTokens == 200)
        #expect(record.cacheWrite1hTokens == 15)
        #expect(record.costProvenance == .listPriceEstimate)
        #expect(try abs(#require(record.costUSD) - 0.00076125) < 0.000000001)
        #expect(ledger.coverageIsEstablished)
        let json = try String(decoding: JSONEncoder().encode(ledger), as: UTF8.self)
        #expect(!json.contains("secret-conversation"))
        #expect(!json.contains("private-message-id"))
        #expect(!json.contains("private-request-id"))
        #expect(!json.contains("private-session-id"))
        #expect(!json.contains("project-a"))
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
            provider: "claude", historyDays: 1)
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
        let oversized = self.event().replacingOccurrences(
            of: "secret-conversation", with: String(repeating: "x", count: 600_000)) + "\n"
        let missingTimestamp = self.event().replacingOccurrences(
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
        let json = try String(decoding: JSONEncoder().encode(ledger), as: UTF8.self)
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
        let incomplete = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","sessionId":"session","requestId":"partial","message":{"id":"partial","model":"claude-sonnet-4-20250514","stop_reason":null,"usage":{"input_tokens":100,"output_tokens":0}}}"#
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
        let overflow = #"{"type":"assistant","timestamp":"2026-10-10T12:00:00Z","sessionId":"session","requestId":"overflow","message":{"id":"overflow","model":"claude-sonnet-4-20250514","usage":{"input_tokens":9223372036854775807,"output_tokens":1}}}"#
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
        timestamp: String = "2026-10-10T12:00:00Z",
        model: String = "claude-sonnet-4-20250514") -> String
    {
        var messageValue: [String: Any] = [
            "model": model,
            "content": "secret-conversation",
            "usage": [
                "input_tokens": 100,
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
        return String(
            decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self)
    }

    private func load(
        _ files: [String: String],
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
        let now = ISO8601DateFormatter().date(from: "2026-10-10T16:00:00Z")!
        let ledger = try UsageLedgerLoader.loadClaude(
            historyDays: 1, now: now, calendar: self.calendar,
            options: .init(claudeProjectsRoots: [projects], cacheRoot: cache, calendar: self.calendar),
            checkCancellation: checkCancellation)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        return ledger
    }
}

import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerCodexTests {
    static let now = Date(timeIntervalSince1970: 1_786_968_000)
    static let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    static let day = CostUsageLocalDay.key(from: Self.now, calendar: Self.calendar)

    @Test
    func `request identity survives host paths and exposes contradictory token observations`() throws {
        let first = Self.row(response: "response-one")
        var changed = Self.row(response: "response-one", input: 200)
        changed.pricingModel = "synthetic-price-model"
        let local = Self.project(rows: [first], path: "/private/mac/conversation.jsonl")
        let remote = Self.project(rows: [changed], path: "/home/remote/conversation.jsonl")
        let lhs = try #require(local.records.first)
        let rhs = try #require(remote.records.first)
        #expect(lhs.id == rhs.id)
        #expect(lhs.sessionID == rhs.sessionID)
        #expect(lhs.identity == .request)
        #expect(lhs.totalTokens == 110)
        #expect(lhs.cacheReadTokens == 20)
        #expect(lhs.reasoningTokens == 4)
        #expect(lhs != rhs)
        let json = try String(decoding: JSONEncoder().encode(local), as: UTF8.self)
        #expect(!json.contains("/private/mac"))
        #expect(!json.contains("synthetic-session"))
        #expect(!json.contains("response-one"))
        #expect(!json.contains("secret conversation title"))
    }

    @Test
    func `legacy identity retains event provenance and warns about weak evidence`() {
        let first = Self.project(rows: [Self.row()])
        let conflicting = Self.project(rows: [Self.row(input: 200)])
        #expect(first.records.first?.id == conflicting.records.first?.id)
        #expect(first.records.first?.identity == .legacyEvent)
        #expect(first.warnings.contains(where: { $0.contains("lack provider request IDs") }))
        let differentEvent = Self.row(event: 2)
        #expect(first.records.first?.id != Self.project(rows: [differentEvent]).records.first?.id)
        let unidentified = Self.project(rows: [Self.row()], session: nil)
        #expect(unidentified.records.first?.identity == .unidentified)
        #expect(unidentified.warnings.contains(where: { $0.contains("cannot be deduplicated") }))
    }

    @Test
    func `strong response identity without a request timestamp retains partial temporal coverage`() throws {
        let row = CostUsageScanner.CodexUsageRow(
            day: Self.day, model: "gpt-5", turnID: "fixture-turn", eventIndex: 1,
            input: 100, cached: 20, output: 10, responseID: "fixture-response")
        let ledger = Self.project(cache: Self.cache(rows: [row]))
        try ledger.validate(provider: "codex", historyDays: 1)
        #expect(ledger.records.first?.identity == .request)
        #expect(ledger.records.first?.totalTokens == 110)
        #expect(!ledger.coverageIsEstablished)
        #expect(ledger.warnings.contains(where: { $0.contains("only a day bucket") }))
        let combined = try UsageLedgerMerger.merge(
            reports: [.init(host: "fixture-host", ledger: ledger)], provider: "codex", historyDays: 1)
        #expect(combined.combined.totalTokens == 110)
        #expect(!combined.combined.coverageIsEstablished)
    }

    @Test
    func `daily totals never become invented ledger requests`() {
        var cache = Self.cache(rows: [])
        cache.files["/private/source.jsonl"]?.days = [Self.day: ["gpt-5": [100, 20, 10]]]
        cache.days = [Self.day: ["gpt-5": [100, 20, 10]]]
        let ledger = Self.project(cache: cache)
        #expect(ledger.records.isEmpty)
        #expect(!ledger.coverageIsEstablished)
        #expect(ledger.warnings.contains(where: { $0.contains("do not reconcile") }))
    }

    @Test
    func `missing fork parent retains incomplete accounting and authoritative pricing survives`() throws {
        var priced = Self.row(response: "priced-response")
        priced.knownCostNanos = 5_000_000_000
        priced.pricingMode = "priority"
        priced.pricingModel = "/private/model-path-that-must-stay-local"
        let ledger = Self.project(rows: [priced])
        let record = try #require(ledger.records.first)
        #expect(record.costUSD == 5)
        #expect(record.costProvenance == .vendorMetered)
        #expect(record.pricingMode == "priority")
        #expect(record.pricingModel == "unknown")
        let exported = try String(decoding: JSONEncoder().encode(ledger), as: UTF8.self)
        #expect(!exported.contains("model-path-that-must-stay-local"))
        var cache = Self.cache(rows: [])
        cache.files["/private/source.jsonl"]?.forkedFromId = "unavailable-parent"
        cache.files["/private/source.jsonl"]?.forkBaselineDependencyKey = "missing|unavailable-parent"
        let missing = Self.project(cache: cache)
        #expect(missing.records.isEmpty)
        #expect(missing.incompleteRequestCount == 1)
        #expect(!missing.coverageIsEstablished)
        #expect(missing.warnings.contains(where: { $0.contains("unavailable parent baseline") }))
    }

    @Test
    func `native scanner deduplicates copied history and retains resumed requests`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = Self.now.addingTimeInterval(-60).ISO8601Format()
        let tokens = [
            "input_tokens": 100,
            "cached_input_tokens": 20,
            "output_tokens": 10,
            "reasoning_output_tokens": 4,
        ]
        let lines: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "synthetic-session"]],
            [
                "type": "turn_context",
                "timestamp": timestamp,
                "payload": ["turn_id": "turn-one", "model": "gpt-5"],
            ],
            ["type": "token_usage_record", "timestamp": timestamp, "payload": [
                "thread_id": "synthetic-session", "session_id": "synthetic-session",
                "turn_id": "turn-one", "response_id": "response-one", "model": "gpt-5",
                "usage": tokens, "thread_token_usage": tokens,
            ]],
        ]
        let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { result, line in
                result.append(line)
                result.append(10)
            }
        try data.write(to: sessions.appendingPathComponent("original.jsonl"))
        try data.write(to: sessions.appendingPathComponent("copy.jsonl"))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessions, cacheRoot: cacheRoot,
            codexTraceDatabaseURL: root.appendingPathComponent("missing-traces.sqlite"),
            calendar: Self.calendar)
        let ledger = try await UsageLedgerLoader.loadCodex(historyDays: 1, now: Self.now, options: options)
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.identity == .request)
        #expect(ledger.records.first?.totalTokens == 110)
        var extended = data
        var continuation = lines[2]
        var payload = try #require(continuation["payload"] as? [String: Any])
        payload["response_id"] = "response-two"
        payload["thread_token_usage"] = tokens.mapValues { $0 * 2 }
        continuation["payload"] = payload
        continuation["timestamp"] = Self.now.addingTimeInterval(-30).ISO8601Format()
        try extended.append(JSONSerialization.data(withJSONObject: continuation))
        extended.append(10)
        try extended.write(to: sessions.appendingPathComponent("copy.jsonl"))
        let resumed = try await UsageLedgerLoader.loadCodex(historyDays: 1, now: Self.now, options: options)
        #expect(resumed.records.count == 2)
        #expect(Set(resumed.records.map(\.id)).count == 2)
        #expect(resumed.records.reduce(0) { $0 + $1.totalTokens } == 220)
    }

    static func row(
        response: String? = nil,
        input: Int = 100,
        event: Int = 1) -> CostUsageScanner.CodexUsageRow
    {
        .init(
            day: self.day, model: "gpt-5", turnID: "turn-one", eventIndex: event,
            timestampUnixMs: Int64(self.now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
            input: input, cached: 20, output: 10, reasoning: 4, responseID: response)
    }

    static func cache(
        rows: [CostUsageScanner.CodexUsageRow],
        path: String = "/private/source.jsonl",
        session: String? = "synthetic-session") -> CostUsageCache
    {
        var file = CostUsageFileUsage(
            mtimeUnixMs: Int64(Self.now.timeIntervalSince1970 * 1000), size: 0,
            days: [Self.day: ["gpt-5": [
                rows.reduce(0) { $0 + $1.input }, rows.reduce(0) { $0 + $1.cached },
                rows.reduce(0) { $0 + $1.output },
            ]]])
        file.sessionId = session
        file.codexRows = rows
        file.codexScanComplete = true
        file.codexSession = .init(
            sessionId: session, cwd: "/private/secret/project", title: "secret conversation title")
        var cache = CostUsageCache()
        cache.files[path] = file
        cache.days = file.days
        return cache
    }

    static func project(
        rows: [CostUsageScanner.CodexUsageRow],
        path: String = "/private/source.jsonl",
        session: String? = "synthetic-session") -> UsageLedger
    {
        self.project(cache: self.cache(rows: rows, path: path, session: session))
    }

    static func project(cache: CostUsageCache) -> UsageLedger {
        UsageLedgerLoader.codexLedger(
            cache: cache, range: .init(since: self.now, until: self.now, calendar: self.calendar),
            historyDays: 1,
            now: self.now,
            source: (cacheRoot: FileManager.default.temporaryDirectory, coverageIsEstablished: true))
    }
}

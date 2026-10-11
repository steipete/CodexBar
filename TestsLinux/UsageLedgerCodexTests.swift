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
        let json = try #require(String(data: JSONEncoder().encode(local), encoding: .utf8))
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
            day: Self.day,
            model: "gpt-5",
            turnID: "fixture-turn",
            eventIndex: 1,
            input: 100,
            cached: 20,
            output: 10,
            responseID: "fixture-response")
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
        let exported = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
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
            codexSessionsRoot: sessions,
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: root.appendingPathComponent("missing-traces.sqlite"),
            calendar: Self.calendar)
        let ledger = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: Self.now,
            options: options,
            pricingCacheRoot: cacheRoot)
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
        let resumed = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: Self.now,
            options: options,
            pricingCacheRoot: cacheRoot)
        #expect(resumed.records.count == 2)
        #expect(Set(resumed.records.map(\.id)).count == 2)
        #expect(resumed.records.reduce(0) { $0 + $1.totalTokens } == 220)
    }

    @Test(arguments: [
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "model",
        "zero",
    ])
    func `native copied and replayed contradictions remain globally withheld`(field: String) async throws {
        for sameFile in [false, true] {
            let fixture = try NativeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let original = Self.nativeRequest()
            var conflicting = Self.nativeRequest()
            var payload = try #require(conflicting["payload"] as? [String: Any])
            if field == "model" {
                payload["model"] = "/private/model-metadata"
            } else {
                var usage = try #require(payload["usage"] as? [String: Int])
                if field == "zero" {
                    usage = usage.mapValues { _ in 0 }
                } else {
                    usage[field] = (usage[field] ?? 0) + 1
                }
                payload["usage"] = usage
                payload["thread_token_usage"] = usage
            }
            conflicting["payload"] = payload
            try fixture.write(records: sameFile ? [original, conflicting] : [original], name: "original.jsonl")
            if !sameFile { try fixture.write(records: [conflicting], name: "copy.jsonl") }
            let ledger = try await UsageLedgerLoader.loadCodex(
                historyDays: 1,
                now: Self.now,
                options: fixture.options,
                pricingCacheRoot: fixture.options.cacheRoot)
            let id = UsageLedgerRecord.digest(["codex", "request", "synthetic-session", "response-one"])
            #expect(ledger.records.count == 1)
            #expect(ledger.records.first?.sessionID != nil)
            #expect(ledger.conflictingRecordIDs == [id])
            #expect(!ledger.coverageIsEstablished)
            let clean = Self.project(rows: [Self.row(response: "response-one")])
            let combined = try UsageLedgerMerger.merge(
                reports: [.init(host: "local", ledger: ledger), .init(host: "remote", ledger: clean)],
                provider: "codex",
                historyDays: 1)
            #expect(combined.combined.totalTokens == 0)
            #expect(combined.combined.costUSD == nil)
            #expect(combined.combined.conflictCount == 1)
            #expect(!combined.combined.coverageIsEstablished)
            let json = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
            #expect(!json.contains("/private/model-metadata"))
        }
    }

    @Test
    func `native contradiction observer excludes future and earlier window observations`() async throws {
        let fixture = try NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var tokens = Self.nativeTokens
        tokens["input_tokens"] = 200
        try fixture.write(records: [
            Self.nativeRequest(),
            Self.nativeRequest(tokens: tokens, timestamp: Self.now.addingTimeInterval(60)),
            Self.nativeRequest(tokens: tokens, timestamp: Self.now.addingTimeInterval(-86400)),
        ], name: "original.jsonl")
        let ledger = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: Self.now,
            options: fixture.options,
            pricingCacheRoot: fixture.options.cacheRoot)
        #expect(ledger.records.first?.totalTokens == 110)
        #expect(ledger.conflictingRecordIDs == nil)
    }

    @Test
    func `native contradiction observer respects copied prefix ownership`() async throws {
        let fixture = try NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var inherited = Self.nativeRequest()
        var payload = try #require(inherited["payload"] as? [String: Any])
        payload["thread_id"] = "different-parent-thread"
        payload["session_id"] = "different-parent-thread"
        payload["usage"] = Self.nativeTokens.mapValues { $0 * 2 }
        payload["thread_token_usage"] = Self.nativeTokens.mapValues { $0 * 2 }
        inherited["payload"] = payload
        try fixture.write(records: [Self.nativeRequest(), inherited], name: "original.jsonl")
        let ledger = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: Self.now,
            options: fixture.options,
            pricingCacheRoot: fixture.options.cacheRoot)
        #expect(ledger.records.first?.totalTokens == 110)
        #expect(ledger.conflictingRecordIDs == nil)
    }

    @Test
    func `native disposable scan reads installed pricing without modifying its catalog`() async throws {
        let fixture = try NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pricingRoot = fixture.root.appendingPathComponent("installed-pricing", isDirectory: true)
        let pricingJSON = #"{"openai":{"id":"openai","models":{"gpt-5":{"id":"gpt-5","cost":{"#
            + #""input":2,"output":8,"cache_read":0.5}}}}}"#
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(pricingJSON.utf8))
        try #require(ModelsDevCache.save(catalog: catalog, fetchedAt: Self.now, cacheRoot: pricingRoot))
        let catalogURL = ModelsDevCache.cacheFileURL(cacheRoot: pricingRoot)
        let originalCatalog = try Data(contentsOf: catalogURL)
        try fixture.write(records: [Self.nativeRequest(tokens: [
            "input_tokens": 100_000, "cached_input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0,
        ])], name: "original.jsonl")
        let ledger = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: Self.now,
            options: fixture.options,
            pricingCacheRoot: pricingRoot)
        let cost = try #require(ledger.records.first?.costUSD)
        #expect(abs(cost - 0.20) < 0.000000001)
        #expect(ledger.records.first?.costProvenance == .listPriceEstimate)
        #expect(try Data(contentsOf: catalogURL) == originalCatalog)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pricingRoot.path) == ["model-pricing"])
        #expect(!FileManager.default.fileExists(atPath: ModelsDevCache.cacheFileURL(
            cacheRoot: fixture.options.cacheRoot).path))
    }

    @Test
    func `direct native export canonicalizes fractional midnight before choosing its window`() async throws {
        let fixture = try NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let midnight = try #require(Self.calendar.date(
            byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: Self.now)))
        try fixture.write(records: [Self.nativeRequest(timestamp: midnight)], name: "original.jsonl")
        let ledger = try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: midnight.addingTimeInterval(-0.0004),
            options: fixture.options,
            pricingCacheRoot: fixture.options.cacheRoot)
        let expectedEnd = Int64(midnight.timeIntervalSince1970 * 1000)
        #expect(ledger.windowStartUnixMs == expectedEnd)
        #expect(ledger.windowEndUnixMs == expectedEnd)
        #expect(ledger.records.first?.timestampUnixMs == expectedEnd)
        #expect(ledger.records.first?.totalTokens == 110)
    }

    static let nativeTokens = [
        "input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 10, "reasoning_output_tokens": 4,
    ]

    static func nativeRequest(
        tokens: [String: Int] = UsageLedgerCodexTests.nativeTokens,
        timestamp: Date = UsageLedgerCodexTests.now.addingTimeInterval(-60)) -> [String: Any]
    {
        ["type": "token_usage_record", "timestamp": timestamp.ISO8601Format(), "payload": [
            "thread_id": "synthetic-session", "session_id": "synthetic-session",
            "turn_id": "turn-one", "response_id": "response-one", "model": "gpt-5",
            "usage": tokens, "thread_token_usage": tokens,
        ]]
    }

    struct NativeFixture {
        let root: URL
        let sessions: URL
        let options: CostUsageScanner.Options

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.sessions = self.root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: self.sessions, withIntermediateDirectories: true)
            self.options = CostUsageScanner.Options(
                codexSessionsRoot: self.sessions,
                cacheRoot: self.root.appendingPathComponent("scratch-cache", isDirectory: true),
                codexTraceDatabaseURL: self.root.appendingPathComponent("missing-traces.sqlite"),
                calendar: UsageLedgerCodexTests.calendar)
        }

        func write(records: [[String: Any]], name: String) throws {
            let meta: [String: Any] = [
                "type": "session_meta",
                "timestamp": records.first?["timestamp"] ?? UsageLedgerCodexTests.now.ISO8601Format(),
                "payload": ["id": "synthetic-session"],
            ]
            let data = try ([meta] + records).map { try JSONSerialization.data(withJSONObject: $0) }
                .reduce(into: Data()) { result, line in
                    result.append(line)
                    result.append(10)
                }
            try data.write(to: self.sessions.appendingPathComponent(name))
        }
    }

    static func row(
        response: String? = nil,
        input: Int = 100,
        event: Int = 1) -> CostUsageScanner.CodexUsageRow
    {
        .init(
            day: self.day,
            model: "gpt-5",
            turnID: "turn-one",
            eventIndex: event,
            timestampUnixMs: Int64(self.now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
            input: input,
            cached: 20,
            output: 10,
            reasoning: 4,
            responseID: response)
    }

    static func cache(
        rows: [CostUsageScanner.CodexUsageRow],
        path: String = "/private/source.jsonl",
        session: String? = "synthetic-session") -> CostUsageCache
    {
        var file = CostUsageFileUsage(
            mtimeUnixMs: Int64(Self.now.timeIntervalSince1970 * 1000),
            size: 0,
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
            cache: cache,
            range: .init(since: self.now, until: self.now, calendar: self.calendar),
            historyDays: 1,
            now: self.now,
            source: (cacheRoot: FileManager.default.temporaryDirectory, coverageIsEstablished: true))
    }
}

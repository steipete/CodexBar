#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import CodexBarCore

enum CursorJSONTestFixtures {
    static let now = Date(timeIntervalSince1970: 1_794_614_400)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func event(
        id: String? = "synthetic-event-a",
        timestamp: Any = "1794564000000",
        input: Any = 100,
        cents: Any = 12.5,
        charged: Any = 0) -> [String: Any]
    {
        var row: [String: Any] = [
            "conversationId": "synthetic-conversation", "timestamp": timestamp,
            "model": "synthetic-model", "chargedCents": charged,
            "tokenUsage": [
                "inputTokens": input, "outputTokens": 20,
                "cacheReadTokens": 10, "cacheWriteTokens": 5, "totalCents": cents,
            ],
        ]
        row["usageEventId"] = id
        return row
    }

    static func document(_ rows: [Any], owned: Bool = true) -> [String: Any] {
        var document: [String: Any] = ["usageEventsDisplay": rows]
        if owned {
            let account = "synthetic-account-a"
            let generation = "88AA7766-5544-4321-8877-665544332211"
            document["_owner"] = [
                "version": 1,
                "ownerHash": SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined(),
                "generation": generation,
            ]
            document["_tokscale"] = ["version": 1, "accountId": account]
            document["zzTokscaleOwner"] = ["version": 1, "generation": generation]
        }
        return document
    }

    struct Cache {
        let home: URL
        let directory: URL

        init() throws {
            self.home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-json-\(UUID())")
            self.directory = self.home.appendingPathComponent(".config/tokscale/cursor-cache")
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        }

        func write(_ document: [String: Any], name: String = "usage.json") throws {
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: self.directory.appendingPathComponent(name))
        }

        func remove() { try? FileManager.default.removeItem(at: self.home) }

        func load(calendar: Calendar = CursorJSONTestFixtures.calendar) -> CursorLocalJSONReader.Result {
            CursorLocalJSONReader.load(
                home: self.home,
                since: CursorJSONTestFixtures.now.addingTimeInterval(-30 * 86400),
                until: CursorJSONTestFixtures.now,
                calendar: calendar,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }

        func report(calendar: Calendar = CursorJSONTestFixtures.calendar) throws -> CursorLocalJSONReader.Report {
            guard case let .report(report) = self.load(calendar: calendar) else { throw MissingReport.unavailable }
            return report
        }
    }

    private enum MissingReport: Error { case unavailable }
}

struct CursorLocalJSONReaderTests {
    private typealias Fixture = CursorJSONTestFixtures

    @Test(arguments: [false, true])
    func `integer counters above double precision remain exact`(string: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        let count = 9_007_199_254_740_993
        let input: Any = string ? String(count) : count
        try cache.write(Fixture.document([Fixture.event(input: input)]))
        #expect(try cache.report().daily.summary?.totalTokens == count + 35)
    }

    @Test
    func `submillisecond timestamps do not round into the next day`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([Fixture.event(timestamp: "2026-11-13T23:59:59.9996Z")]))
        #expect(try cache.report().daily.data.first?.date == "2026-11-13")
    }

    @Test(arguments: [false, true])
    func `empty positional and object token usage preserve metered only events`(positional: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var row = Fixture.event(charged: 25)
        row["tokenUsage"] = positional ? [] as [Any] : [:] as [String: Any]
        try cache.write(Fixture.document([row]))
        let report = try cache.report()
        #expect(report.isComplete)
        #expect(report.daily.data.isEmpty)
        #expect(report.meteredCostUSD == 0.25)
    }

    @Test
    func `owned cache keeps API rate and metered cost separate`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([Fixture.event()]))
        let report = try cache.report()
        #expect(report.isComplete)
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.daily.summary?.totalCostUSD == 0.125)
        #expect(report.meteredCostUSD == 0)
    }

    @Test(arguments: [
        "1794564000000",
        " 1794564000000 ",
        "2026-11-13T10:00:00Z",
        "2026-11-13T10:00:00.000Z",
        "2026-11-13T12:00:00+02:00",
    ])
    func `numeric and ISO timestamps describe the same event day`(timestamp: String) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([Fixture.event(timestamp: timestamp)]))
        let report = try cache.report()
        #expect(report.daily.data.first?.date == "2026-11-13")
        #expect(report.daily.summary?.totalTokens == 135)
    }

    @Test(arguments: [false, true])
    func `positional rows support object and positional token usage`(positionalTokens: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        let usage: Any = positionalTokens
            ? ["100", 20.0, "10", 5, "12.5"] as [Any]
            : try #require(Fixture.event()["tokenUsage"])
        let row: [Any] = ["synthetic-conversation", 1_794_564_000_000, "synthetic-model", "0", usage]
        try cache.write(Fixture.document([row]))
        let report = try cache.report()
        #expect(report.isComplete)
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.daily.summary?.totalCostUSD == 0.125)
        #expect(report.meteredCostUSD == 0)
    }

    @Test(arguments: [false, true])
    func `largest snapshot wins independently of row order`(reversed: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        let rows = [Fixture.event(input: 40, cents: 5), Fixture.event()]
        try cache.write(Fixture.document(reversed ? rows.reversed().map(\.self) : rows))
        let report = try cache.report()
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.daily.summary?.totalCostUSD == 0.125)
        #expect(report.daily.data.first?.requestCount == 1)
    }

    @Test
    func `equal token snapshots prefer authoritative cost and preserve earliest exact ties`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([
            Fixture.event(cents: 20, charged: 7), Fixture.event(cents: 12.5, charged: 1000),
            Fixture.event(cents: 20, charged: 9),
        ]))
        let report = try cache.report()
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.daily.summary?.totalCostUSD == 0.2)
        #expect(report.meteredCostUSD == 0.07)
    }

    @Test
    func `distinct event IDs preserve otherwise identical requests`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([Fixture.event(), Fixture.event(id: "synthetic-event-b")]))
        let report = try cache.report()
        #expect(report.daily.summary?.totalTokens == 270)
        #expect(report.daily.summary?.totalCostUSD == 0.25)
        #expect(report.daily.data.first?.requestCount == 2)
    }

    @Test(arguments: [false, true])
    func `idless rows retain multiplicity unless matched to an identified event`(identified: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var rows = [Fixture.event(id: nil), Fixture.event(id: nil)]
        if identified { rows.append(Fixture.event()) }
        try cache.write(Fixture.document(rows))
        #expect(try cache.report().daily.summary?.totalTokens == (identified ? 135 : 270))
    }

    @Test
    func `ambiguous idless snapshots join only the smallest identified event`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([
            Fixture.event(id: "b"), Fixture.event(id: nil, input: 200), Fixture.event(id: "a"),
        ]))
        #expect(try cache.report().daily.summary?.totalTokens == 370)
    }

    @Test(arguments: ["timestamp", "model", "negative", "overflow", "fractional", "shape"])
    func `rejected rows retain usable history as partial and withhold metered totals`(invalid: String) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var row = Fixture.event(id: "invalid")
        switch invalid {
        case "timestamp": row["timestamp"] = "not-a-date"
        case "model": row["model"] = "  "
        case "negative": row["tokenUsage"] = ["inputTokens": -1]
        case "overflow": row["tokenUsage"] = ["inputTokens": Int.max, "outputTokens": 1]
        case "fractional": row["tokenUsage"] = ["inputTokens": 0.5]
        default: break
        }
        let bad: Any = invalid == "shape" ? 42 : row
        try cache.write(Fixture.document([Fixture.event(), bad]))
        let report = try cache.report()
        #expect(!report.isComplete)
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.meteredCostUSD == nil)
    }

    @Test(arguments: ["invalid", "negative", "zero", "null", "missing"])
    func `reported amounts retain invalid zero and absent distinctions`(kind: String) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var row = Fixture.event()
        var tokens = try #require(row["tokenUsage"] as? [String: Any])
        switch kind {
        case "invalid": tokens["totalCents"] = "NaN"
        case "negative": tokens["totalCents"] = -1
        case "zero": tokens["totalCents"] = 0
        case "null": tokens["totalCents"] = NSNull()
        default: tokens.removeValue(forKey: "totalCents")
        }
        row["tokenUsage"] = tokens
        try cache.write(Fixture.document([row]))
        let report = try cache.report()
        #expect(report.isComplete)
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.daily.summary?.totalCostUSD == (kind == "zero" ? 0 : nil))
    }

    @Test
    func `window filtering also excludes old and future metered charges`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([
            Fixture.event(),
            Fixture.event(id: "old", timestamp: "2025-11-13T10:00:00Z", charged: 100),
            Fixture.event(id: "future", timestamp: "2027-11-13T10:00:00Z", charged: 100),
        ]))
        let report = try cache.report()
        #expect(report.daily.summary?.totalTokens == 135)
        #expect(report.meteredCostUSD == 0)
    }

    @Test
    func `configured calendar buckets timestamps at UTC plus fourteen`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try cache.write(Fixture.document([Fixture.event()]))
        var calendar = Fixture.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        #expect(try cache.report(calendar: calendar).daily.data.first?.date == "2026-11-14")
    }
}

struct CursorLocalJSONSelectionTests {
    private typealias Fixture = CursorJSONTestFixtures

    @Test(arguments: ["hash", "generation", "version", "footer", "legacy", "account", "null", "uuid"])
    func `inconsistent owner metadata is unavailable`(invalid: String) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var document = Fixture.document([Fixture.event()])
        var owner = try #require(document["_owner"] as? [String: Any])
        switch invalid {
        case "hash": owner["ownerHash"] = String(repeating: "0", count: 64)
        case "generation": owner["generation"] = UUID().uuidString
        case "version": owner["version"] = 2
        case "footer": document.removeValue(forKey: "zzTokscaleOwner")
        case "legacy": document.removeValue(forKey: "_tokscale")
        case "account": document["_tokscale"] = ["version": 1, "accountId": "different-account"]
        case "null": owner["version"] = NSNull()
        default: owner["generation"] = "invalid-uuid"
        }
        document["_owner"] = owner
        try cache.write(document)
        guard case .unavailable = cache.load() else { Issue.record("Invalid owner metadata was accepted"); return }
    }

    @Test(arguments: [false, true])
    func `legacy canonical JSON remains an automatic ambient cache`(hasLegacyOwner: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        var document = Fixture.document([Fixture.event()], owned: false)
        if hasLegacyOwner { document["_tokscale"] = ["version": 1, "accountId": "legacy-account"] }
        try cache.write(document)
        #expect(try cache.report().daily.summary?.totalTokens == 135)
    }

    @Test
    func `inactive account backup and archive caches are not discovered`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        let document = Fixture.document([Fixture.event(input: 9000)])
        for name in ["usage.account-foreign.json", "usage.backup.json"] {
            try cache.write(document, name: name)
        }
        try FileManager.default.createDirectory(
            at: cache.directory.appendingPathComponent("archive"), withIntermediateDirectories: true)
        try cache.write(document, name: "archive/usage.json")
        guard case .absent = cache.load() else { Issue.record("Discovered an inactive cache"); return }
        try cache.write(Fixture.document([Fixture.event()]))
        #expect(try cache.report().daily.summary?.totalTokens == 135)
    }

    @Test(arguments: [false, true])
    func `canonical directories and symbolic links are unavailable`(symlink: Bool) throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        let canonical = cache.directory.appendingPathComponent("usage.json")
        if symlink {
            try cache.write(Fixture.document([Fixture.event()]), name: "usage.account-foreign.json")
            try FileManager.default.createSymbolicLink(
                at: canonical, withDestinationURL: cache.directory.appendingPathComponent("usage.account-foreign.json"))
        } else {
            try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        }
        guard case .unavailable = cache.load() else { Issue.record("Accepted a nonregular canonical cache"); return }
    }

    @Test
    func `malformed canonical JSON is unavailable and empty JSON is not invented usage`() throws {
        let cache = try Fixture.Cache()
        defer { cache.remove() }
        try Data("{".utf8).write(to: cache.directory.appendingPathComponent("usage.json"))
        guard case .unavailable = cache.load() else { Issue.record("Accepted malformed JSON"); return }
        try cache.write(Fixture.document([]))
        let report = try cache.report()
        #expect(report.daily.data.isEmpty)
        #expect(report.meteredCostUSD == nil)
    }
}
#endif

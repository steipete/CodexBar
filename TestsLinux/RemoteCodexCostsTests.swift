import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct RemoteCodexCostsTests {
    private static let now = Date(timeIntervalSince1970: 1_788_177_600)

    private static func summary(
        tokens: Int? = 1500,
        cost: Double? = 0.25,
        complete: Bool = true,
        days: Int = 30,
        updatedAt: Date? = nil,
        timeZone: TimeZone = .gmt) -> CodexCostSummary
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let entry = CostUsageDailyReport.Entry(
            date: "2026-08-31",
            inputTokens: tokens,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(
                modelName: "fixture-model",
                costUSD: cost,
                totalTokens: tokens,
                incompleteRequestCount: 3)])
        return CodexCostSummary(snapshot: .init(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: days,
            historyCoverageIsEstablished: complete,
            costProvenance: .listPriceEstimate,
            daily: [entry],
            updatedAt: updatedAt ?? Self.now), calendar: calendar)
    }

    private static func wire(_ summary: CodexCostSummary) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try String(decoding: encoder.encode([summary]), as: UTF8.self)
    }

    @Test
    func `summary preserves unknown totals incomplete requests and origin metadata`() throws {
        let summary = Self.summary(tokens: nil, cost: nil, complete: false)
        try summary.validate(historyDays: 30)
        #expect(summary.schemaVersion == 1)
        #expect(summary.today.totalTokens == nil)
        #expect(summary.today.costUSD == nil)
        #expect(summary.history.totalTokens == nil)
        #expect(summary.history.costUSD == nil)
        #expect(summary.today.incompleteRequestCount == 3)
        #expect(summary.history.incompleteRequestCount == 3)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(summary.bucketTimeZone == "GMT")
        let wire = try Self.wire(summary)
        #expect(!wire.contains("fixture-model"))
        #expect(!wire.contains("projects"))
        #expect(!wire.contains("sessions"))
        #expect(!wire.contains("account"))
    }

    @Test
    func `measured zero stays distinct from an unavailable summary`() {
        let zero = Self.summary(tokens: 0, cost: 0)
        let text = CodexBarCLI.renderHostCostText(.init(host: "local", source: "local", summary: zero))
        #expect(text.contains("$0.00"))
        #expect(text.contains("0 tokens"))
        #expect(text.contains("Snapshot updated: 2026-08-31T12:00:00Z"))
        let missing = CodexBarCLI.renderHostCostText(.init(
            host: "qa-linux", source: "ssh", summary: Self.summary(tokens: nil, cost: nil, complete: false)))
        #expect(!missing.contains("$0"))
        #expect(missing.contains("Partial history"))
        #expect(missing.contains("3 incomplete requests excluded"))
        #expect(missing.contains("Snapshot updated: 2026-08-31T12:00:00Z"))
    }

    @Test
    func `host text shows each source snapshot timestamp in UTC`() throws {
        let local = try Self.summary(timeZone: #require(TimeZone(identifier: "America/Los_Angeles")))
        let remote = try Self.summary(
            updatedAt: Date(timeIntervalSince1970: 946_684_800),
            timeZone: #require(TimeZone(identifier: "Asia/Tokyo")))
        let localText = CodexBarCLI.renderHostCostText(.init(host: "local", source: "local", summary: local))
        let remoteText = CodexBarCLI.renderHostCostText(.init(host: "qa-linux", source: "ssh", summary: remote))

        #expect(localText.contains("Snapshot updated: 2026-08-31T12:00:00Z"))
        // A retained source snapshot must not acquire this invocation's time or the other host's time.
        #expect(remoteText.contains("Snapshot updated: 2000-01-01T00:00:00Z"))
        #expect(localText.contains("Day boundaries: America/Los_Angeles"))
        #expect(remoteText.contains("Day boundaries: Asia/Tokyo"))
    }

    @Test(arguments: ["local", "ssh"])
    func `failed host text does not invent a snapshot timestamp`(source: String) {
        let text = CodexBarCLI.renderHostCostText(.init(
            host: "qa-linux", source: source, summary: nil, error: "Fixture unavailable."))
        let title = source == "local" ? "This machine" : "qa-linux"
        #expect(text == "\(title): Fixture unavailable.")
    }

    @Test(arguments: ["", "-oProxyCommand=bad", "user@host other", "host,other", "host\nother", "host'", "host;bad"])
    func `unsafe or multiple SSH destinations are rejected`(host: String) {
        #expect(throws: RemoteCodexCostError.self) {
            try RemoteCodexCostFetcher.validateHost(host)
        }
    }

    @Test
    func `SSH preserves username case and executes only one selected scanner`() throws {
        let args = try RemoteCodexCostFetcher.arguments(host: "BuildUser@qa-linux", historyDays: 7, force: true)
        #expect(args.contains("BuildUser@qa-linux"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("RemoteCommand=none"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("-n"))
        let command = try #require(args.last)
        #expect(command.contains("if command -v codexbar"))
        #expect(command.contains("--days 7 --refresh"))
        #expect(command.contains("--summary-only --provider-native-only"))
        #expect(!command.contains("||"))
        #expect(!command.contains("BuildUser"))
        try RemoteCodexCostFetcher.validateHost("qa-linux")
        try RemoteCodexCostFetcher.validateHost("user@[2001:db8::1]")
    }

    @Test
    func `fetch accepts only a versioned summary and excludes unrelated environment secrets`() async throws {
        let expected = Self.summary()
        let wire = try Self.wire(expected)
        let fetcher = RemoteCodexCostFetcher { arguments, environment in
            #expect(arguments.contains("qa-linux"))
            #expect(environment["UNRELATED_TOKEN"] == nil)
            #expect(environment["SSH_AUTH_SOCK"] == "/tmp/synthetic-agent")
            return wire
        }
        let actual = try await fetcher.fetch(
            host: "qa-linux", historyDays: 30,
            environment: ["UNRELATED_TOKEN": "fixture-secret", "SSH_AUTH_SOCK": "/tmp/synthetic-agent"])
        #expect(actual == expected)
    }

    @Test(arguments: [
        "version",
        "provider",
        "days",
        "timezone",
        "currency",
        "negativeTokens",
        "negativeCost",
        "negativeCoverage",
        "coverageOverflow",
        "negativeIncomplete",
        "legacy",
        "multiple",
        "oversized",
    ])
    func `invalid summaries fail closed without a legacy fallback`(mutation: String) async throws {
        let data = try Data(Self.wire(Self.summary()).utf8)
        var rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var row = try #require(rows.first)
        var today = try #require(row["today"] as? [String: Any])
        switch mutation {
        case "version": row["schemaVersion"] = 2
        case "provider": row["provider"] = "claude"
        case "days": row["historyDays"] = 7
        case "timezone": row["bucketTimeZone"] = "invalid/fixture"
        case "currency": row["currencyCode"] = "EUR"
        case "negativeTokens": today["totalTokens"] = -1
        case "negativeCost": today["costUSD"] = -1
        case "negativeCoverage": today["coverage"] = ["priced": -1, "estimated": 0, "unpriced": 0, "unmetered": 0]
        case "coverageOverflow":
            today["coverage"] = ["priced": Int.max, "estimated": 1, "unpriced": 0, "unmetered": 0]
        case "negativeIncomplete": today["incompleteRequestCount"] = -1
        case "legacy": row.removeValue(forKey: "schemaVersion")
        default: break
        }
        row["today"] = today
        rows = mutation == "multiple" ? [row, row] : [row]
        let wire = try mutation == "oversized" ? String(repeating: " ", count: 16385) : String(
            decoding: JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let fetcher = RemoteCodexCostFetcher { _, _ in wire }
        await #expect(throws: RemoteCodexCostError.self) {
            try await fetcher.fetch(host: "qa-linux", historyDays: 30, environment: [:])
        }
    }

    @Test
    func `host collection calls each scanner once and keeps totals separate`() async throws {
        let calls = CostHostCallRecorder()
        let reports = try await CodexBarCLI.collectCodexHostCosts(
            remote: "qa-linux", historyDays: 30,
            local: { await calls.add("local"); return Self.summary(tokens: 100) },
            fetchRemote: { _ in await calls.add("remote"); return Self.summary(tokens: 900) })
        #expect(await calls.values == ["local", "remote"])
        #expect(reports.map(\.summary?.today.totalTokens) == [100, 900])
        #expect(reports.map(\.source) == ["local", "ssh"])
    }

    @Test
    func `remote failure preserves local results without disclosing stderr`() async throws {
        let reports = try await CodexBarCLI.collectCodexHostCosts(
            remote: "qa-linux", historyDays: 30,
            local: { Self.summary() },
            fetchRemote: { _ in throw CostHostFixtureError() })
        #expect(reports.count == 2)
        #expect(reports[0].summary?.today.totalTokens == 1500)
        #expect(reports[1].summary == nil)
        #expect(reports[1].error == RemoteCodexCostError.unavailable.localizedDescription)
        #expect(!reports.map(CodexBarCLI.renderHostCostText).joined().contains("fixture-private-stderr"))
    }

    @Test
    func `cancelled local work never starts SSH`() async {
        await #expect(throws: CancellationError.self) {
            try await CodexBarCLI.collectCodexHostCosts(
                remote: "qa-linux", historyDays: 30,
                local: { throw CancellationError() },
                fetchRemote: { _ in Issue.record("SSH started after cancellation"); return Self.summary() })
        }
    }

    @Test
    func `one day host text shows one today line`() {
        let text = CodexBarCLI.renderHostCostText(.init(
            host: "local", source: "local", summary: Self.summary(days: 1)))
        #expect(text.components(separatedBy: "Today:").count == 2)
        #expect(!text.contains("Last 1 days"))
        #expect(text.components(separatedBy: "Snapshot updated:").count == 2)
        #expect(text.contains("Snapshot updated: 2026-08-31T12:00:00Z"))
    }

    @Test
    func `remote cancellation stays cancellation`() async {
        let fetcher = RemoteCodexCostFetcher { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await fetcher.fetch(host: "qa-linux", historyDays: 30, environment: [:])
        }
    }

    @Test
    func `signal received before task binding still cancels work`() async {
        let state = CodexHostCostCancellation()
        state.request(signal: 15)
        let task = Task { try await Task.sleep(for: .seconds(60)) }
        state.bind { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(state.signal == 15)
    }
}

private actor CostHostCallRecorder {
    private(set) var values: [String] = []
    func add(_ value: String) { self.values.append(value) }
}

private struct CostHostFixtureError: LocalizedError {
    var errorDescription: String? {
        "fixture-private-stderr"
    }
}

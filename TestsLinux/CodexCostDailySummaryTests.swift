import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CodexCostDailySummaryTests {
    private static let now = Date(timeIntervalSince1970: 1_788_177_600)
    private static let calendar = CostUsageBucketTimeZone.calendar(identifier: "GMT")

    private static func entry(
        _ date: String = "2026-08-31",
        tokens: Int? = 100,
        cost: Double? = 0.5,
        incomplete: Int = 2) -> CostUsageDailyReport.Entry
    {
        .init(
            date: date,
            inputTokens: tokens,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: ["private-fixture-model"],
            modelBreakdowns: [.init(
                modelName: "private-fixture-model",
                costUSD: cost,
                incompleteRequestCount: incomplete)],
            unpricedRequestCount: 1,
            pricedRequestCount: 2)
    }

    private static func summary(
        rows: [CostUsageDailyReport.Entry]? = nil,
        days: Int = 30,
        established: Bool = true,
        partial: Bool = false) throws -> CodexCostDailySummary
    {
        try CodexCostDailySummary(
            snapshot: .init(
                sessionTokens: 100,
                sessionCostUSD: 0.5,
                last30DaysTokens: 100,
                last30DaysCostUSD: 0.5,
                historyDays: days,
                historyCoverageIsEstablished: established,
                historyScanIsPartial: partial,
                costProvenance: .listPriceEstimate,
                daily: rows ?? [self.entry()],
                updatedAt: self.now),
            calendar: self.calendar)
    }

    private static func wire(_ summary: CodexCostDailySummary) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode([summary]), encoding: .utf8))
    }

    @Test
    func `daily round trip preserves numeric coverage partial state and source age without details`() async throws {
        let expected = try Self.summary(partial: true)
        let wire = try Self.wire(expected)
        let fetcher = RemoteCodexCostFetcher(boundedRunner: { arguments, environment, limit in
            #expect(limit == 256 * 1024)
            #expect(arguments.last?.contains("--daily-summary --provider-native-only") == true)
            #expect(arguments.last?.contains("--bucket-time-zone \"GMT\"") == true)
            #expect(environment["UNRELATED_TOKEN"] == nil)
            return wire
        })
        let actual = try await fetcher.fetchDaily(
            host: "qa-linux",
            historyDays: 30,
            bucketTimeZone: "GMT",
            environment: ["UNRELATED_TOKEN": "synthetic-secret"])
        let snapshot = try actual.tokenSnapshot()
        #expect(actual == expected)
        #expect(snapshot.updatedAt == Self.now)
        #expect(snapshot.historyScanIsPartial)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(!snapshot.historyIsFullyScanned)
        #expect(snapshot.daily.first?.totalTokens == 100)
        #expect(snapshot.daily.first?.costUSD == 0.5)
        #expect(snapshot.daily.first?.incompleteRequestCount == 2)
        #expect(snapshot.daily.first?.coverageCounts == .init(priced: 2, unpriced: 1))
        #expect(snapshot.summary(forLastDays: 30, calendar: Self.calendar).incompleteRequestCount == 2)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.daily.first?.modelsUsed == nil)
        #expect(snapshot.daily.first?.modelBreakdowns == nil)
        #expect(snapshot.projects.isEmpty && snapshot.sessions.isEmpty && snapshot.hourly.isEmpty)
        #expect(snapshot.quotaSlices.isEmpty)
        for excluded in ["private-fixture", "models", "projects", "sessions", "account", "path", "inputTokens"] {
            #expect(!wire.contains(excluded))
        }
    }

    @Test
    func `unknown values and absent partial days never become measured zero`() throws {
        let unknown = try Self.summary(rows: [Self.entry(tokens: nil, cost: nil)]).tokenSnapshot()
        #expect(unknown.sessionTokens == nil && unknown.sessionCostUSD == nil)
        #expect(unknown.last30DaysTokens == nil && unknown.last30DaysCostUSD == nil)
        let zero = try Self.summary(rows: [Self.entry(tokens: 0, cost: 0)]).tokenSnapshot()
        #expect(zero.sessionTokens == 0 && zero.sessionCostUSD == 0)
        #expect(zero.last30DaysTokens == 0 && zero.last30DaysCostUSD == 0)
        for established in [false, true] {
            for partial in [false, true] {
                let empty = try Self.summary(rows: [], established: established, partial: partial).tokenSnapshot()
                let complete = established && !partial
                #expect(empty.sessionTokens == (complete ? 0 : nil))
                #expect(empty.last30DaysCostUSD == (complete ? 0 : nil))
                let yesterday = try Self.summary(
                    rows: [Self.entry("2026-08-30")], established: established, partial: partial).tokenSnapshot()
                #expect(yesterday.sessionCostUSD == (complete ? 0 : nil))
            }
        }
    }

    @Test
    func `full year daily output fits its separate budget while old summary stays bounded`() async throws {
        let rows = try (0..<365).map { offset in
            let day = try #require(Self.calendar.date(byAdding: .day, value: -offset, to: Self.now))
            return Self.entry(CostUsageLocalDay.key(from: day, calendar: Self.calendar))
        }
        let expected = try Self.summary(rows: rows, days: 365)
        let wire = try Self.wire(expected)
        #expect(wire.utf8.count > RemoteCodexCostFetcher.maximumOutputBytes)
        #expect(wire.utf8.count < RemoteCodexCostFetcher.maximumDailyOutputBytes)
        let fetcher = RemoteCodexCostFetcher { _, _ in wire }
        let received = try await fetcher.fetchDaily(host: "qa-linux", historyDays: 365, bucketTimeZone: "GMT")
        #expect(received.daily.count == 365)
        #expect(try received.tokenSnapshot().last30DaysTokens == 3000)
        await #expect(throws: RemoteCodexCostError.self) {
            try await fetcher.fetch(host: "qa-linux", historyDays: 365)
        }
    }

    @Test(arguments: [
        "version", "kind", "provider", "days", "zone", "currency", "provenance", "date", "timestamp",
        "outside", "duplicate", "unsorted", "tokens", "cost", "incomplete", "coverage", "tokenOverflow",
        "coverageOverflow", "incompleteOverflow", "costOverflow", "extraTop", "extraRow", "extraCoverage",
        "missingPartial", "multiple", "oversized",
    ])
    func `daily schema rejects incompatible unsafe and overflowing payloads`(mutation: String) async throws {
        let data = try Data(Self.wire(Self.summary()).utf8)
        var object = try #require((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        var row = try #require((object["daily"] as? [[String: Any]])?.first)
        var coverage = try #require(row["coverage"] as? [String: Any])
        let metadata: [String: (String, Any)] = [
            "version": ("schemaVersion", 2),
            "kind": ("kind", "summary"),
            "provider": ("provider", "claude"),
            "days": ("historyDays", 31),
            "zone": ("bucketTimeZone", "Asia/Tokyo"),
            "currency": ("currencyCode", "EUR"),
            "provenance": ("costProvenance", "vendorMetered"),
        ]
        if let (key, value) = metadata[mutation] { object[key] = value }
        switch mutation {
        case "date": row["date"] = "2026-02-30"
        case "timestamp": object["updatedAt"] = "1969-12-31T00:00:00Z"
        case "outside": row["date"] = "2026-09-01"
        case "tokens": row["totalTokens"] = -1
        case "cost": row["costUSD"] = -1
        case "incomplete": row["incompleteRequestCount"] = -1
        case "coverage": coverage["unpriced"] = -1
        case "tokenOverflow": row["totalTokens"] = Int.max
        case "coverageOverflow": coverage["priced"] = Int.max
        case "incompleteOverflow": row["incompleteRequestCount"] = Int.max
        case "costOverflow": row["costUSD"] = Double.greatestFiniteMagnitude
        case "extraTop": object["sessions"] = ["private"]
        case "extraRow": row["path"] = "/private/fixture"
        case "extraCoverage": coverage["identity"] = "private"
        case "missingPartial": object.removeValue(forKey: "historyScanIsPartial")
        default: break
        }
        row["coverage"] = coverage
        object["daily"] = [row]
        if ["tokenOverflow", "incompleteOverflow", "costOverflow", "unsorted"].contains(mutation) {
            var yesterday = row
            yesterday["date"] = "2026-08-30"
            object["daily"] = mutation == "unsorted" ? [row, yesterday] : [yesterday, row]
        }
        if mutation == "duplicate" { object["daily"] = [row, row] }
        let objects = mutation == "multiple" ? [object, object] : [object]
        let wire = try mutation == "oversized"
            ? String(repeating: " ", count: RemoteCodexCostFetcher.maximumDailyOutputBytes + 1)
            : #require(String(data: JSONSerialization.data(withJSONObject: objects), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher { _, _ in wire }
        await #expect(throws: RemoteCodexCostError.self) {
            try await fetcher.fetchDaily(host: "qa-linux", historyDays: 30, bucketTimeZone: "GMT")
        }
    }

    @Test(arguments: ["", "invalid/fixture", "GMT';bad", "$(bad)", "UTC\n", " UTC", "UTC;bad"])
    func `invalid timezone is rejected before transport`(zone: String) async {
        let fetcher = RemoteCodexCostFetcher { _, _ in
            Issue.record("transport started for invalid timezone")
            return "[]"
        }
        await #expect(throws: RemoteCodexCostError.self) {
            try await fetcher.fetchDaily(host: "qa-linux", historyDays: 30, bucketTimeZone: zone)
        }
    }

    @Test
    func `cancellation propagates and transport failure hides sensitive diagnostics`() async {
        let cancelled = RemoteCodexCostFetcher { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await cancelled.fetchDaily(host: "qa-linux", historyDays: 30, bucketTimeZone: "GMT")
        }
        let failed = RemoteCodexCostFetcher { _, _ in throw NSError(domain: "/private/stderr", code: 1) }
        do {
            _ = try await failed.fetchDaily(host: "qa-linux", historyDays: 30, bucketTimeZone: "GMT")
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription == RemoteCodexCostError.unavailable.localizedDescription)
        }
    }

    @Test
    func `direct incomplete counts round trip while legacy model counts and wire remain unchanged`() throws {
        let legacy = Self.entry(incomplete: 3)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyObject["incompleteRequestCount"] == nil)
        #expect(try JSONDecoder().decode(CostUsageDailyReport.Entry.self, from: legacyData).incompleteRequestCount == 3)
        let aggregate = try Self.summary().tokenSnapshot().daily[0]
        let restored = try JSONDecoder().decode(CostUsageDailyReport.Entry.self, from: JSONEncoder().encode(aggregate))
        #expect(restored.incompleteRequestCount == 2)
        #expect(restored.modelBreakdowns == nil)
    }

    @Test(arguments: [
        "valid", "noDaily", "oldSummary", "remote", "group", "breakdown", "noNative", "text", "provider",
        "noZone", "twoZones", "badZone", "periodAll", "periodMonth",
    ])
    func `CLI accepts only explicitly opted in native daily transport`(mode: String) throws {
        let parser = CommandParser(signature: CodexBarCLI._costSignatureForTesting())
        var arguments = [
            "--daily-summary", "--provider", "codex", "--format", "json", "--provider-native-only",
            "--bucket-time-zone", "America/Los_Angeles",
        ]
        switch mode {
        case "noDaily": arguments.removeAll { $0 == "--daily-summary" }
        case "oldSummary": arguments.append("--summary-only")
        case "remote": arguments += ["--remote", "qa-linux"]
        case "group": arguments += ["--group-by", "project"]
        case "breakdown": arguments.append("--breakdown")
        case "noNative": arguments.removeAll { $0 == "--provider-native-only" }
        case "text": arguments[4] = "text"
        case "provider": arguments[2] = "claude"
        case "noZone": arguments.removeLast(2)
        case "twoZones": arguments += ["--bucket-time-zone", "GMT"]
        case "badZone": arguments[7] = "invalid/fixture"
        case "periodAll": arguments += ["--period", "all"]
        case "periodMonth": arguments += ["--period", "month-to-date"]
        default: break
        }
        let values = try parser.parse(arguments: arguments)
        let format = CLIOutputPreferences.from(values: values).format
        if mode == "valid" {
            let calendar = try CodexBarCLI.codexDailySummaryCalendar(values, format: format)
            #expect(calendar.timeZone.identifier == "America/Los_Angeles")
        } else {
            #expect(throws: RemoteCodexCostError.self) {
                try CodexBarCLI.codexDailySummaryCalendar(values, format: format)
            }
        }
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostWindowTests {
    @Test(arguments: [false, true])
    func `long history JSON uses the latest thirty local dates and preserves full totals`(openCodex: Bool) throws {
        let rows = [
            Self.entry("2024-01-01", tokens: 100, cost: 1),
            Self.entry("2024-05-31", tokens: 200, cost: 2),
            Self.entry("2024-06-01", tokens: 300, cost: 3),
            Self.entry("2024-06-30", tokens: 400, cost: 4),
            Self.entry("2024-07-01", tokens: 500, cost: 5),
        ]
        let project = CostUsageProjectBreakdown(
            name: "synthetic-project",
            path: "/synthetic/project",
            totalTokens: 1500,
            totalCostUSD: 15,
            daily: rows,
            modelBreakdowns: nil)
        let snapshot = Self.snapshot(rows: rows, tokens: 1500, cost: 15, projects: [project])
        let object = try Self.json(snapshot, openCodex: openCodex)
        #expect(object["last30DaysTokens"] as? Int == 700)
        #expect(object["last30DaysCostUSD"] as? Double == 7)
        #expect(object["historyDays"] as? Int == 365)
        #expect((object["daily"] as? [[String: Any]])?.count == 5)
        let totals = try #require(object["totals"] as? [String: Any])
        #expect(totals["totalTokens"] as? Int == 1500)
        #expect(totals["totalCost"] as? Double == 15)
        let projects = try #require(object["projects"] as? [[String: Any]])
        #expect(projects.count == (openCodex ? 0 : 1))
        if !openCodex {
            #expect(projects.first?["totalTokens"] as? Int == 1500)
            #expect(projects.first?["totalCost"] as? Double == 15)
            #expect((projects.first?["daily"] as? [[String: Any]])?.count == 5)
        }
        #expect(snapshot.last30DaysTokens == 1500)
        #expect(snapshot.last30DaysCostUSD == 15)
    }

    @Test(arguments: [false, true])
    func `short history JSON retains legacy aggregates`(openCodex: Bool) throws {
        for days in [1, 7, 30] {
            let snapshot = Self.snapshot(rows: [], tokens: 123, cost: 4, days: days)
            let object = try Self.json(snapshot, openCodex: openCodex)
            #expect(object["last30DaysTokens"] as? Int == 123)
            #expect(object["last30DaysCostUSD"] as? Double == 4)
        }
    }

    @Test(arguments: [false, true])
    func `empty long windows require complete coverage and known amounts for zero`(openCodex: Bool) throws {
        for established in [false, true] {
            for partial in [false, true] {
                for priced in [false, true] {
                    for rows in [[], [Self.entry("2024-01-01", tokens: 100, cost: priced ? 1 : nil)]] {
                        let snapshot = Self.snapshot(
                            rows: rows,
                            tokens: 100,
                            cost: priced ? 1 : nil,
                            established: established,
                            partial: partial)
                        let object = try Self.json(snapshot, openCodex: openCodex)
                        let complete = established && !partial
                        #expect(object["last30DaysTokens"] as? Int == (complete ? 0 : nil))
                        #expect(object["last30DaysCostUSD"] as? Double == (complete && priced ? 0 : nil))
                    }
                }
            }
        }
        let unknown = try Self.json(Self.snapshot(rows: [], tokens: nil, cost: nil), openCodex: openCodex)
        #expect(unknown["last30DaysTokens"] == nil)
        #expect(unknown["last30DaysCostUSD"] == nil)
    }

    @Test(arguments: [false, true])
    func `long window JSON preserves missing values known zero and checked token sums`(openCodex: Bool) throws {
        let cases: [(rows: [CostUsageDailyReport.Entry], tokens: Int?, cost: Double?)] = [
            ([Self.entry("2024-06-30", tokens: nil, cost: nil)], nil, nil),
            ([Self.entry("2024-06-30", tokens: 0, cost: 0)], 0, 0),
            ([Self.entry("2024-06-30", tokens: Int.max, cost: nil)], Int.max, nil),
            ([
                Self.entry("2024-06-01", tokens: Int.max, cost: 1),
                Self.entry("2024-06-30", tokens: 1, cost: 2),
            ], nil, 3),
            ([
                Self.entry("2024-06-01", tokens: nil, cost: nil),
                Self.entry("2024-06-30", tokens: 10, cost: 2),
            ], 10, 2),
        ]
        for testCase in cases {
            // Full-history aggregates must not be used as a fallback for absent or overflowing window totals.
            let snapshot = Self.snapshot(rows: testCase.rows, tokens: 999, cost: 99)
            let object = try Self.json(snapshot, openCodex: openCodex)
            #expect(object["last30DaysTokens"] as? Int == testCase.tokens)
            #expect(object["last30DaysCostUSD"] as? Double == testCase.cost)
        }
    }

    private static func json(_ snapshot: CostUsageTokenSnapshot, openCodex: Bool) throws -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let payload = openCodex
            ? CodexBarCLI.makeOpenCodexCostPayload(snapshot: snapshot, calendar: calendar)
            : CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil, calendar: calendar)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    }

    private static func snapshot(
        rows: [CostUsageDailyReport.Entry],
        tokens: Int?,
        cost: Double?,
        days: Int = 365,
        established: Bool = true,
        partial: Bool = false,
        projects: [CostUsageProjectBreakdown] = []) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: days,
            historyCoverageIsEstablished: established,
            historyScanIsPartial: partial,
            daily: rows,
            projects: projects,
            updatedAt: Date(timeIntervalSince1970: 1_719_793_800)) // 2024-07-01 00:30 UTC, June 30 locally.
    }

    private static func entry(_ day: String, tokens: Int?, cost: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}

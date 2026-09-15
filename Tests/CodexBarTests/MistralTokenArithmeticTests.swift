import Foundation
import Testing
@testable import CodexBarCore

struct MistralTokenArithmeticTests {
    @Test
    func `representable signed final totals do not depend on lane order`() throws {
        let cases: [([Int], Int)] = [
            ([Int.max, 1, -1], Int.max),
            ([Int.min, -1, 1], Int.min),
            ([Int.max, Int.min, 1], 0),
            ([Int.max, Int.max, Int.min], Int.max - 1),
        ]
        for (values, expected) in cases {
            for lanes in Self.permutations(values) {
                let snapshot = try Self.parse(Self.completion(lanes))
                let decoded = try JSONDecoder().decode(
                    MistralUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
                for candidate in [snapshot, decoded] {
                    #expect(candidate.checkedTotalTokens == expected)
                    #expect(candidate.daily.first?.checkedTotalTokens == expected)
                    #expect(candidate.daily.first?.totalTokens == expected)
                    #expect(candidate.daily.first?.models.first?.checkedTotalTokens == expected)
                    #expect(candidate.daily.first?.models.first?.totalTokens == expected)
                }
            }
        }
    }

    @Test
    func `unrepresentable final totals fail in every lane order`() throws {
        for values in [[Int.max, 1, 0], [Int.min, -1, 0], [Int.max, Int.max, 1], [Int.min, Int.min, -1]] {
            for lanes in Self.permutations(values) {
                try Self.expectOverflow(Self.completion(lanes))
            }
        }
    }

    @Test(arguments: [[Int.max, 1], [Int.min, -1], [Int.max, 1, -1]])
    func `actual lane additions reject overflow before publishing counts`(values: [Int]) throws {
        try Self.expectOverflow(["completion": ["models": ["fixture": ["input": values.map { Self.entry($0) }]]]])
    }

    @Test
    func `monthly lane additions remain checked across models`() throws {
        try Self.expectOverflow(["completion": ["models": [
            "alpha": ["input": [Self.entry(Int.max, day: "2026-09-01")]],
            "beta": ["input": [Self.entry(1, day: "2026-09-02")]],
        ]]])
    }

    @Test
    func `a single daily model requires a representable final total`() throws {
        try Self.expectOverflow(["completion": ["models": ["fixture": [
            "input": [Self.entry(Int.max, day: "2026-09-01")],
            "cached": [Self.entry(1, day: "2026-09-01"), Self.entry(-1, day: "2026-09-02")],
        ]]]])
    }

    @Test
    func `daily bucket totals remain checked when each model total fits`() throws {
        try Self.expectOverflow(["completion": ["models": [
            "alpha": ["input": [Self.entry(Int.max, day: "2026-09-01", name: "alpha")]],
            "beta": ["output": [Self.entry(1, day: "2026-09-01", name: "beta")]],
            "gamma": ["cached": [Self.entry(-1, day: "2026-09-02", name: "gamma")]],
        ]]])
    }

    @Test
    func `monthly combined totals remain checked when all daily totals fit`() throws {
        try Self.expectOverflow(["completion": ["models": [
            "alpha": ["input": [Self.entry(Int.max, day: "2026-09-01")]],
            "beta": ["output": [Self.entry(1, day: "2026-09-02")]],
        ]]])
    }

    @Test
    func `library entries still participate in checked daily lanes`() throws {
        try Self.expectOverflow([
            "completion": ["models": ["completion": ["input": [Self.entry(Int.max)]]]],
            "libraries_api": ["tokens": ["models": ["library": ["input": [Self.entry(1)]]]]],
        ])
    }

    @Test
    func `signed lanes are combined only after all entries are accumulated`() throws {
        let snapshot = try Self.parse(["completion": ["models": ["fixture": [
            "input": [Self.entry(Int.max)],
            "output": [Self.entry(1)],
            "cached": [Self.entry(-1)],
        ]]]])
        #expect(snapshot.totalInputTokens == Int.max)
        #expect(snapshot.totalOutputTokens == 1)
        #expect(snapshot.totalCachedTokens == -1)
        #expect(snapshot.daily.first?.totalTokens == Int.max)
        #expect(snapshot.daily.first?.models.first?.totalTokens == Int.max)
    }

    @Test
    func `unused raw model month totals do not reject valid final aggregates`() throws {
        let snapshot = try Self.parse(["completion": ["models": [
            "raw-alpha": [
                "input": [Self.entry(Int.max, day: "2026-09-01", name: "alpha")],
                "output": [Self.entry(1, day: "2026-09-02", name: "beta")],
            ],
            "raw-beta": ["cached": [Self.entry(-1, day: "2026-09-02", name: "beta")]],
        ]]])
        #expect(snapshot.daily.map(\.totalTokens) == [Int.max, 0])
        #expect(snapshot.daily.last?.models.map(\.totalTokens) == [0])
        #expect(snapshot.modelCount == 2)
    }

    @Test
    func `library month lanes are not invented for signed daily adjustments`() throws {
        let snapshot = try Self.parse(["libraries_api": ["tokens": ["models": ["library": [
            "input": [Self.entry(Int.max, day: "2026-09-01"), Self.entry(1, day: "2026-09-02")],
            "output": [Self.entry(-1, day: "2026-09-02")],
        ]]]]])
        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.totalOutputTokens == 0)
        #expect(snapshot.totalCachedTokens == 0)
        #expect(snapshot.daily.map(\.totalTokens) == [Int.max, 0])
        #expect(snapshot.toCostUsageTokenSnapshot().last30DaysTokens == nil)
    }

    @Test
    func `optional named rankings do not gate otherwise valid parsed billing`() throws {
        let snapshot = try Self.parse(["libraries_api": ["tokens": ["models": ["library": [
            "input": [Self.entry(Int.max, day: "2026-09-01"), Self.entry(1, day: "2026-09-02")],
        ]]]]])
        #expect(snapshot.daily.map(\.totalTokens) == [Int.max, 1])
        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.totalCost.isFinite)
        #expect(snapshot.totalCost > 0)
    }

    @Test(arguments: ["ocr", "connectors", "audio", "pages", "training", "storage"])
    func `cost only categories do not sum unused token lanes`(category: String) throws {
        let models = ["fixture": ["input": [Self.entry(Int.max), Self.entry(1)]]]
        let payload: [String: Any] = switch category {
        case "pages": ["libraries_api": ["pages": ["models": models]]]
        case "training", "storage": ["fine_tuning": [category: models]]
        default: [category: ["models": models]]
        }
        let snapshot = try Self.parse(payload)
        #expect(snapshot.totalCost == Double(Int.max) * 0.25 + 0.25)
        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.modelCount == 0)
        #expect(snapshot.daily.first?.totalTokens == 0)
        #expect(snapshot.daily.first?.models.first?.cost == snapshot.totalCost)
    }

    @Test
    func `paid zero retains precedence over a large raw value`() throws {
        var entry = Self.entry(Int.max)
        entry["value_paid"] = 0
        let snapshot = try Self.parse(["completion": ["models": ["fixture": ["input": [entry, entry]]]]])
        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.totalCost == 0)
        #expect(snapshot.daily.first?.totalTokens == 0)
    }

    private static func entry(
        _ value: Int,
        day: String = "2026-09-02",
        name: String = "fixture") -> [String: Any]
    {
        [
            "value": value,
            "timestamp": day,
            "billing_display_name": name,
            "billing_metric": "fixture",
            "billing_group": "unit",
        ]
    }

    private static func permutations(_ values: [Int]) -> [[Int]] {
        [(0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)].map {
            [values[$0.0], values[$0.1], values[$0.2]]
        }
    }

    private static func completion(_ lanes: [Int]) -> [String: Any] {
        ["completion": ["models": ["fixture": [
            "input": [self.entry(lanes[0])],
            "cached": [self.entry(lanes[1])],
            "output": [self.entry(lanes[2])],
        ]]]]
    }

    private static func parse(_ categories: [String: Any]) throws -> MistralUsageSnapshot {
        var payload = categories
        payload["currency"] = "USD"
        payload["currency_symbol"] = "$"
        payload["start_date"] = "2026-09-01T00:00:00Z"
        payload["end_date"] = "2026-09-30T23:59:59Z"
        payload["prices"] = [["billing_metric": "fixture", "billing_group": "unit", "price": "0.25"]]
        return try MistralUsageFetcher.parseResponse(
            data: JSONSerialization.data(withJSONObject: payload),
            updatedAt: Date(timeIntervalSince1970: 1_789_200_000))
    }

    private static func expectOverflow(_ categories: [String: Any]) throws {
        do {
            _ = try self.parse(categories)
            Issue.record("Expected unrepresentable token aggregation to fail")
        } catch let error as MistralUsageError {
            guard case .parseFailed = error else {
                Issue.record("Expected a parse failure, got \(error)")
                return
            }
        }
    }
}

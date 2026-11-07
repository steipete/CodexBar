import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct WidgetTopModelsTests {
    private static func input(_ name: String, tokens: Int?, cost: Double?) -> WidgetSnapshot.ModelShareInput {
        WidgetSnapshot.ModelShareInput(modelName: name, totalTokens: tokens, costUSD: cost)
    }

    private static func day(_ date: String, _ models: [(String, Int?, Double?)]) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: models.map(\.0),
            modelBreakdowns: models.map {
                CostUsageDailyReport.ModelBreakdown(modelName: $0.0, costUSD: $0.2, totalTokens: $0.1)
            })
    }

    @Test
    func `fully priced models keep the leading three by spend share of all models`() throws {
        let leading = try #require(WidgetSnapshot.ModelShare.leading([
            Self.input("haiku", tokens: 9000, cost: 5),
            Self.input("opus", tokens: 100, cost: 60),
            Self.input("sonnet", tokens: 500, cost: 30),
            Self.input("legacy", tokens: 10, cost: 5),
        ]))

        #expect(leading.map(\.modelName) == ["opus", "sonnet", "haiku"])
        #expect(leading.map(\.share) == [0.6, 0.3, 0.05])
    }

    @Test
    func `an unpriced model switches the share to tokens`() throws {
        let leading = try #require(WidgetSnapshot.ModelShare.leading([
            Self.input("priced", tokens: 100, cost: 50),
            Self.input("unpriced", tokens: 300, cost: nil),
        ]))

        #expect(leading.map(\.modelName) == ["unpriced", "priced"])
        #expect(leading.map(\.share) == [0.75, 0.25])
    }

    @Test
    func `no comparable metric yields no top models`() {
        #expect(WidgetSnapshot.ModelShare.leading([]) == nil)
        #expect(WidgetSnapshot.ModelShare.leading([
            Self.input("a", tokens: nil, cost: 1),
            Self.input("b", tokens: 1, cost: nil),
        ]) == nil)
        #expect(WidgetSnapshot.ModelShare.leading([Self.input("idle", tokens: 0, cost: 0)]) == nil)
    }

    @Test
    func `history aggregation sums each model across days and stays with its provider`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [
                Self.day("2026-10-01", [("opus", 100, 6), ("sonnet", 300, 3)]),
                Self.day("2026-10-02", [("opus", 100, 6), ("haiku", 600, 1)]),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        let leading = try #require(UsageStore.widgetTopModels(from: snapshot))

        #expect(leading.map(\.modelName) == ["opus", "sonnet", "haiku"])
        #expect(leading.first?.totalTokens == 200)
        #expect(leading.first?.costUSD == 12)
        #expect(abs((leading.first?.share ?? 0) - 0.75) < 1e-9)
    }

    @Test
    func `a day without a token count makes that model's token total unknown`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [
                Self.day("2026-10-01", [("opus", 100, 6)]),
                Self.day("2026-10-02", [("opus", nil, 6)]),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        let leading = try #require(UsageStore.widgetTopModels(from: snapshot))
        #expect(leading.first?.totalTokens == nil)
        #expect(leading.first?.costUSD == 12)
    }

    @Test
    func `a usage day without a model split withholds top models`() {
        let unsplit = CostUsageDailyReport.Entry(
            date: "2026-10-02",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 5000,
            costUSD: 4,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [Self.day("2026-10-01", [("opus", 100, 6)]), unsplit],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        #expect(UsageStore.widgetTopModels(from: snapshot) == nil)
    }

    @Test
    func `a day with unpriced requests ranks by complete tokens instead of partial spend`() throws {
        // Both models carry a $1 known subtotal, but the day reports an unpriced request, so spend is
        // incomplete and the shares must come from the complete token counts.
        let partial = CostUsageDailyReport.Entry(
            date: "2026-10-01",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 1100,
            costUSD: 2,
            modelsUsed: ["big", "small"],
            modelBreakdowns: [
                .init(modelName: "big", costUSD: 1, totalTokens: 1000),
                .init(modelName: "small", costUSD: 1, totalTokens: 100),
            ],
            unpricedRequestCount: 1)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [partial],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        let leading = try #require(UsageStore.widgetTopModels(from: snapshot))

        #expect(leading.map(\.modelName) == ["big", "small"])
        #expect(abs((leading.first?.share ?? 0) - 1000.0 / 1100.0) < 1e-9)
    }

    @Test
    func `an unmetered day without a model split withholds top models`() {
        // Unresolved fork activity: requests happened, but no tokens, cost, or model split exist.
        let unmetered = CostUsageDailyReport.Entry(
            date: "2026-10-02",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unmeteredRequestCount: 3)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [Self.day("2026-10-01", [("opus", 100, 6)]), unmetered],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        #expect(UsageStore.widgetTopModels(from: snapshot) == nil)
    }

    @Test(arguments: [nil, 0, 1, 3])
    func `incomplete requests withhold shares even when model totals match`(incompleteRequests: Int?) {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-10-01",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 10,
            modelsUsed: ["opus"],
            modelBreakdowns: [
                .init(modelName: "opus", costUSD: 10, totalTokens: 100, incompleteRequestCount: incompleteRequests),
            ])

        // Incomplete requests contribute to neither the model breakdown nor the daily totals.
        // Matching sums therefore cannot establish coverage when any such request exists.
        let shares = UsageStore.widgetTopModels(from: Self.snapshot([entry]))
        #expect((shares == nil) == ((incompleteRequests ?? 0) > 0))
    }

    @Test(arguments: [(false, false), (true, true), (false, true)])
    func `incomplete history withholds model shares`(coverage: Bool, partial: Bool) {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: coverage,
            historyScanIsPartial: partial,
            daily: [Self.day("2026-10-01", [("opus", 100, 6)])],
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))

        #expect(UsageStore.widgetTopModels(from: snapshot) == nil)
    }

    @Test(arguments: [
        (40, 4.0), (40, 10.0), (100, 4.0), (100, 10.0), (140, 14.0),
    ])
    func `daily coverage selects only a complete basis`(modelTokens: Int, modelCost: Double) throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-10-01",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 10,
            modelsUsed: ["opus", "sonnet"],
            modelBreakdowns: [
                .init(modelName: "opus", costUSD: modelCost * 0.8, totalTokens: modelTokens / 2),
                .init(modelName: "sonnet", costUSD: modelCost * 0.2, totalTokens: modelTokens / 2),
            ])
        let shares = UsageStore.widgetTopModels(from: Self.snapshot([entry]))
        if modelCost == 10 {
            #expect(try abs(#require(shares?.first?.share) - 0.8) < 1e-9)
        } else if modelTokens == 100 {
            #expect(shares?.first?.share == 0.5)
            #expect(shares?.first?.costUSD == nil)
        } else {
            #expect(shares == nil)
        }
    }

    @Test
    func `partial sole model and unnamed usage do not become one hundred percent`() {
        for models in [[("opus", 40, 4.0)], [("opus", 40, 4.0), ("  ", 60, 6.0)]] {
            let entry = Self.coverageDay("2026-10-01", models)
            #expect(UsageStore.widgetTopModels(from: Self.snapshot([entry])) == nil)
        }
    }

    @Test
    func `coverage must hold each day rather than cancelling across days`() {
        let days = [
            Self.coverageDay("2026-10-01", [("opus", 40, 4)]),
            Self.coverageDay("2026-10-02", [("opus", 160, 16)]),
        ]
        #expect(UsageStore.widgetTopModels(from: Self.snapshot(days)) == nil)
    }

    @Test
    func `one basis must cover the entire history`() {
        let days = [
            Self.coverageDay("2026-10-01", [("opus", 40, 10)]),
            Self.coverageDay("2026-10-02", [("sonnet", 100, 4)]),
        ]
        #expect(UsageStore.widgetTopModels(from: Self.snapshot(days)) == nil)
    }

    @Test
    func `floating point spend summation preserves complete coverage`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-10-01",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: 0.3,
            modelsUsed: ["opus", "sonnet"],
            modelBreakdowns: [
                .init(modelName: "opus", costUSD: 0.1),
                .init(modelName: "sonnet", costUSD: 0.2),
            ])
        let shares = try #require(UsageStore.widgetTopModels(from: Self.snapshot([entry])))
        #expect(abs((shares.first?.share ?? 0) - 2.0 / 3.0) < 1e-9)
    }

    private static func coverageDay(
        _ date: String,
        _ models: [(String, Int, Double)]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 10,
            modelsUsed: models.map(\.0),
            modelBreakdowns: models.map {
                .init(modelName: $0.0, costUSD: $0.2, totalTokens: $0.1)
            })
    }

    private static func snapshot(_ days: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: days,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    @Test
    func `snapshots written before top models still decode`() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000),
            primary: nil,
            secondary: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "topModels")
        let decoded = try JSONDecoder().decode(
            WidgetSnapshot.ProviderEntry.self,
            from: JSONSerialization.data(withJSONObject: json))

        #expect(decoded.topModels == nil)
    }
}

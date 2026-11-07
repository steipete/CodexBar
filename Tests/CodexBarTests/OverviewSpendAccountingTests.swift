import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OverviewSpendAccountingTests {
    private static let now = Date(timeIntervalSince1970: 1_793_534_400) // November 1, 2026, UTC.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func model(
        provider: UsageProvider = .codex,
        models: [CostUsageDailyReport.ModelBreakdown],
        unpriced: Int? = nil,
        incomplete: Int? = nil) -> SpendDashboardModel
    {
        SpendDashboardModel.build(
            inputs: [.init(
                provider: provider,
                displayName: provider == .codex ? "Codex" : "Claude",
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: nil,
                    last30DaysCostUSD: nil,
                    historyDays: 7,
                    daily: [.init(
                        date: "2026-11-01",
                        inputTokens: 5,
                        outputTokens: 5,
                        totalTokens: 10,
                        costUSD: 2,
                        modelsUsed: nil,
                        modelBreakdowns: models + (incomplete.map { count in
                            [.init(modelName: "fixture-excluded", costUSD: nil, incompleteRequestCount: count)]
                        } ?? []),
                        unpricedRequestCount: unpriced)],
                    updatedAt: self.now))],
            requestedDays: 7,
            reportingPeriod: .rolling(days: 7),
            now: self.now,
            calendar: self.calendar,
            preferredCurrencyCode: "USD")
    }

    @Test(arguments: [1.0, 4.0, -1.0, Double.nan])
    @MainActor
    func `dashboard rejects inconsistent and malformed daily attribution`(modelCost: Double) throws {
        let model = Self.model(models: [
            .init(modelName: "fixture-max", costUSD: modelCost, totalTokens: 10),
        ])
        let daily = try #require(OverviewDailySpend.make(model: model))
        let row = try #require(model.groups.first?.dailySummaries.last?.providers.first)
        #expect(row.modelCosts.isEmpty)
        let point = try #require(daily.points.last)
        #expect(daily.stacks[point.id] == [.init(provider: .codex, tier: .standard, cost: 2)])
    }

    @Test
    @MainActor
    func `reconciled priced Codex rows survive an unpriced routing row`() throws {
        let model = Self.model(models: [
            .init(modelName: "fixture-max", costUSD: 2, totalTokens: 8),
            .init(modelName: "fixture-routing", costUSD: nil, totalTokens: 2),
        ], unpriced: 1)
        let row = try #require(model.groups.first?.dailySummaries.last?.providers.first)
        #expect(row.modelCosts == [.init(modelName: "fixture-max", cost: 2)])
        #expect(row.costIsLowerBound)
        let daily = try #require(OverviewDailySpend.make(model: model))
        let point = try #require(daily.points.last)
        #expect(daily.stacks[point.id] == [.init(provider: .codex, tier: .high, cost: 2)])
    }

    @Test(arguments: [false, true])
    @MainActor
    func `provider accessibility preserves lower bounds and excluded requests`(excluded: Bool) throws {
        let model = Self.model(
            provider: .claude,
            models: [],
            unpriced: excluded ? nil : 1,
            incomplete: excluded ? 2 : nil)
        let daily = try #require(OverviewDailySpend.make(model: model))
        let point = try #require(daily.points.last)
        let qualified = spendDashboardBreakdownMetricText(
            cost: 2,
            tokens: nil,
            currencyCode: "USD",
            incompleteRequestCount: excluded ? 2 : 0,
            costIsLowerBound: !excluded)
        #expect(point.accessibilityValue.contains("Claude \(qualified)") == true)
        #expect(qualified != UsageFormatter.currencyString(2, currencyCode: "USD"))
    }

    @Test
    @MainActor
    func `chart dates follow French app language rather than the system locale`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            let daily = try #require(OverviewDailySpend.make(model: Self.model(models: [])))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr")
            formatter.timeZone = Self.calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            let date = formatter.string(from: Self.now)
            #expect(date.contains("nov."))
            #expect(daily.points.last?.hoverSummary?.hasPrefix("\(date):") == true)
            #expect(daily.points.last?.accessibilityValue.hasPrefix("\(date):") == true)
        }
    }
}

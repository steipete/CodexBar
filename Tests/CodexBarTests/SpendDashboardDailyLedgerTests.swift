import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardDailyLedgerTests {
    @Test
    func `daily summaries include every covered day and aggregate each provider`() throws {
        let claude = Self.input(
            id: "claude",
            provider: .claude,
            displayName: "Claude",
            entries: [
                Self.entry(day: "2026-07-14", cost: 1, tokens: 100, requests: 2),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 300, requests: 4),
            ],
            totals: .init(cost: 4, tokens: 400, requests: 6))
        let openAI = Self.input(
            id: "openai",
            provider: .openai,
            displayName: "OpenAI",
            entries: [
                Self.entry(day: "2026-07-15", cost: 2, tokens: 200, requests: 3),
                Self.entry(day: "2026-07-16", cost: 4, tokens: 400, requests: 5),
            ],
            totals: .init(cost: 6, tokens: 600, requests: 8))
        let group = try #require(SpendDashboardModel.build(
            inputs: [claude, openAI],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailySummaries.count == 3)
        #expect(group.dailySummaries.map(\.totalCost) == [1, 2, 7])
        #expect(group.dailySummaries.map(\.totalTokens) == [100, 200, 700])
        #expect(group.dailySummaries.map(\.requestCount) == [2, 3, 9])

        let firstDay = try #require(group.dailySummaries.first)
        #expect(firstDay.providers.map(\.displayName) == ["Claude", "OpenAI"])
        #expect(firstDay.providers.map(\.totalCost) == [1, 0])
        #expect(firstDay.providers.map(\.totalTokens) == [100, 0])
        #expect(firstDay.providers.map(\.requestCount) == [2, 0])

        let lastDay = try #require(group.dailySummaries.last)
        #expect(lastDay.providers.map(\.displayName) == ["OpenAI", "Claude"])
        #expect(lastDay.providers.map(\.totalCost) == [4, 3])
        #expect(group.dailyPoints.count == 4)
    }

    @Test
    func `daily summaries fail closed when any provider cost history is invalid`() throws {
        let healthy = Self.input(
            id: "healthy",
            provider: .codex,
            displayName: "Codex",
            entries: [Self.entry(day: "2026-07-16", cost: 2, tokens: 20, requests: 1)],
            totals: .init(cost: 2, tokens: 20, requests: 1))
        let invalid = Self.input(
            id: "invalid",
            provider: .claude,
            displayName: "Claude",
            entries: [
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30, requests: 2),
                Self.entry(day: "not-a-day", cost: 4, tokens: 40, requests: 3),
            ],
            totals: .init(cost: 7, tokens: 70, requests: 5))
        let group = try #require(SpendDashboardModel.build(
            inputs: [healthy, invalid],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailySummaries.isEmpty)
        #expect(group.dailyPoints.map(\.sourceID) == ["healthy"])
    }

    @Test
    func `daily requests stay unavailable without a complete request aggregate`() throws {
        let input = Self.input(
            id: "claude",
            provider: .claude,
            displayName: "Claude",
            entries: [Self.entry(day: "2026-07-16", cost: 3, tokens: 30, requests: 2)],
            totals: .init(cost: 3, tokens: 30, requests: nil))
        let group = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailySummaries.last?.totalCost == 3)
        #expect(group.dailySummaries.last?.totalTokens == 30)
        #expect(group.dailySummaries.last?.requestCount == nil)
        #expect(group.dailySummaries.last?.providers.first?.requestCount == nil)
    }

    @Test
    func `daily selection defaults to latest and resolves the closest covered day`() throws {
        let summaries = [
            Self.summary(day: 14, cost: 1),
            Self.summary(day: 15, cost: 2),
            Self.summary(day: 16, cost: 3),
        ]
        let latest = spendDashboardSelectedDailySummary(
            selectedDay: nil,
            summaries: summaries,
            calendar: Self.calendar)
        let morningAfterFirstDay = try #require(Self.calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 14, hour: 8)))
        let exact = spendDashboardSelectedDailySummary(
            selectedDay: morningAfterFirstDay,
            summaries: summaries,
            calendar: Self.calendar)

        #expect(latest?.totalCost == 3)
        #expect(exact?.totalCost == 1)
    }

    @Test
    func `currency conversion scales every displayed cost while preserving usage`() throws {
        let group = try #require(SpendDashboardModel.build(
            inputs: [
                Self.input(
                    id: "codex",
                    provider: .codex,
                    displayName: "Codex",
                    entries: [Self.entry(day: "2026-07-16", cost: 4, tokens: 40, requests: 2)],
                    totals: .init(cost: 4, tokens: 40, requests: 2, currencyCode: "USD")),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        let converted = group.converted(to: "GBP", rate: 0.75)

        #expect(converted.currencyCode == "GBP")
        #expect(converted.totalCost == 3)
        #expect(converted.providers.first?.totalCost == 3)
        #expect(converted.models.first?.totalCost == 3)
        #expect(converted.dailyPoints.first?.cost == 3)
        #expect(converted.dailySummaries.last?.totalCost == 3)
        #expect(converted.dailySummaries.last?.providers.first?.totalCost == 3)
        #expect(converted.totalTokens == 40)
        #expect(converted.dailySummaries.last?.requestCount == 2)
    }

    @Test
    func `GBP preference defaults on and sanitizes the manual rate`() {
        #expect(spendDashboardDefaultsToGBP(storedPreference: nil))
        #expect(spendDashboardDefaultsToGBP(storedPreference: true))
        #expect(!spendDashboardDefaultsToGBP(storedPreference: false))
        #expect(spendDashboardUSDToGBPRate(.nan) == spendDashboardDefaultUSDToGBPRate)
        #expect(spendDashboardUSDToGBPRate(0) == 0.01)
        #expect(spendDashboardUSDToGBPRate(100) == 10)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        displayName: String,
        entries: [CostUsageDailyReport.Entry],
        totals: InputTotals) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: displayName,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: totals.tokens,
                last30DaysCostUSD: totals.cost,
                last30DaysRequests: totals.requests,
                currencyCode: totals.currencyCode,
                historyDays: 3,
                daily: entries,
                updatedAt: self.now))
    }

    private static func entry(
        day: String,
        cost: Double,
        tokens: Int,
        requests: Int) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [
                .init(
                    modelName: "test-model",
                    costUSD: cost,
                    totalTokens: tokens,
                    requestCount: requests),
            ])
    }

    private static func summary(day: Int, cost: Double) -> SpendDashboardModel.DailySummary {
        let date = self.calendar.date(from: DateComponents(year: 2026, month: 7, day: day))!
        return SpendDashboardModel.DailySummary(
            day: date,
            providers: [],
            totalTokens: nil,
            requestCount: nil,
            totalCost: cost)
    }

    private struct InputTotals {
        let cost: Double
        let tokens: Int
        let requests: Int?
        let currencyCode: String

        init(cost: Double, tokens: Int, requests: Int?, currencyCode: String = "GBP") {
            self.cost = cost
            self.tokens = tokens
            self.requests = requests
            self.currencyCode = currencyCode
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
